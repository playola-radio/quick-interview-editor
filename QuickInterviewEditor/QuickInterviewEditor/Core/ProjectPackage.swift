import Foundation

/// Errors decoding or validating a `.pie` package's `FileWrapper` tree (spec A2). The
/// descriptions are what the document system's open/save alert shows (spec A9).
enum ProjectPackageError: Error, Equatable, LocalizedError {
  case missingProjectJSON
  case missingPlanJSON
  case missingAudio
  case unsupportedSchema(Int)
  case audioMismatch
  case malformedRecoveryArchive

  var errorDescription: String? {
    switch self {
    case .missingProjectJSON: return "The project is missing its project.json."
    case .missingPlanJSON: return "The project is missing its plan.json."
    case .missingAudio: return "The project is missing its bundled audio (audio/canonical.aiff)."
    case .unsupportedSchema(let version):
      if version > ProjectFile.maximumReadableSchemaVersion {
        return "This project (format \(version)) was saved by a newer version of the app."
      }
      return "This project uses an unsupported format version (\(version))."
    case .audioMismatch: return "The project's bundled audio does not match the project."
    case .malformedRecoveryArchive:
      return "The project's suggestion recovery archive is not a regular file."
    }
  }

  /// NSDocument supplies its own “could not be opened” headline. Put the actual
  /// package error in the failure reason so AppKit preserves it in the alert body.
  var failureReason: String? { errorDescription }

  var recoverySuggestion: String? {
    guard case .unsupportedSchema(let version) = self,
      version > ProjectFile.maximumReadableSchemaVersion
    else { return nil }
    return "Open this project with the version of the app that last saved it, or a newer version."
  }

}

/// The three pieces decoded from a `.pie` package: the small project file, the
/// engine's plan verbatim, and the still-wrapped canonical audio (never re-serialized).
struct DecodedPackage {
  var file: ProjectFile
  var plan: EditPlan
  var audioWrapper: FileWrapper
  var recoveryArchive: Data?
  // swiftlint:disable inclusive_language
  /// True when schema 3 recorded a mastering run but its JSON failed to decode — distinct
  /// from a project that never had a run. Any `mastering/` media on disk may still be
  /// intact; a save must leave it alone rather than reconciling against a `nil` run and
  /// deleting it (spec: never silently drop the manifest while orphaning media).
  var masteringManifestCorrupt = false
  // swiftlint:enable inclusive_language
}

/// Encodes and decodes a `.pie` package's directory `FileWrapper` tree
/// (`project.json`, `plan.json`, `audio/canonical.aiff`) without touching real
/// disk, so both the document type and its tests can operate on the same codec
/// (spec A2).
enum ProjectPackage {
  /// The coder for `project.json`. An explicit ISO-8601 `Date` strategy keeps
  /// `importedAt` unambiguous and human-legible on disk — Foundation's default
  /// `Date` coding is seconds-since-2001, which silently misreads a Unix-looking
  /// timestamp by decades. `plan.json` keeps its own engine-defined coding and is
  /// never routed through here (spec A2/A4).
  ///
  /// Precision contract: this format carries **whole seconds only** (no fractional
  /// seconds). `importedAt` is import-provenance metadata where sub-second precision
  /// is meaningless, so an in-memory `Date()`'s fractional part is dropped on encode
  /// and does not survive a round trip. `verifyAudio`'s test suite pins this
  /// normalization. Whoever constructs `ProjectSource` at import time should floor
  /// `importedAt` to whole seconds so the in-memory value matches what reopening the
  /// package yields.
  static func projectEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static func projectDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  /// Just enough of `project.json` to gate on the schema version before decoding the
  /// full, version-specific payload.
  private struct SchemaProbe: Decodable {
    let schemaVersion: Int
  }

  static func decode(_ root: FileWrapper) throws -> DecodedPackage {
    guard let projectData = root.fileWrappers?["project.json"]?.regularFileContents else {
      throw ProjectPackageError.missingProjectJSON
    }
    // Gate on the schema version first, so a newer or malformed file whose fields no
    // longer match the v1 shape fails with a clear `unsupportedSchema` instead of an
    // opaque `DecodingError`. Only versions in `1...current` are accepted; 0, negative,
    // and future versions are all refused (spec A8).
    let probe = try JSONDecoder().decode(SchemaProbe.self, from: projectData)
    guard (1...ProjectFile.maximumReadableSchemaVersion).contains(probe.schemaVersion) else {
      throw ProjectPackageError.unsupportedSchema(probe.schemaVersion)
    }
    var file = try projectDecoder().decode(ProjectFile.self, from: projectData)
    var manifestCorrupt = false
    if probe.schemaVersion < 3 {
      file.masteringRun = nil
    } else if let run = file.masteringRun {
      let children = root.fileWrappers?["mastering"]?.fileWrappers ?? [:]
      file.masteringRun = run.healed(available: children.compactMapValues(masteringSize))
    } else {
      // Schema 3 always writes a run (`writtenSchemaVersion`), so a nil run here means the
      // manifest JSON failed to decode, not that the project never had one.
      manifestCorrupt = true
    }

    guard let planData = root.fileWrappers?["plan.json"]?.regularFileContents else {
      throw ProjectPackageError.missingPlanJSON
    }
    let plan = try JSONDecoder().decode(EditPlan.self, from: planData)

    guard let audioWrapper = root.fileWrappers?["audio"]?.fileWrappers?["canonical.aiff"],
      audioWrapper.isRegularFile
    else {
      throw ProjectPackageError.missingAudio
    }

    if let archive = root.fileWrappers?["suggestion-recovery.json"], !archive.isRegularFile {
      throw ProjectPackageError.malformedRecoveryArchive
    }
    return DecodedPackage(
      file: file, plan: plan, audioWrapper: audioWrapper,
      recoveryArchive: root.fileWrappers?["suggestion-recovery.json"]?.regularFileContents,
      masteringManifestCorrupt: manifestCorrupt)
  }

  static func encode(
    file: ProjectFile, plan: EditPlan, audio: FileWrapper, recoveryArchive: Data? = nil,
    // swiftlint:disable:next inclusive_language
    masteringStaged: [String: StagedMasteringArtifact] = [:], strictMissing: Bool = false
  ) throws -> FileWrapper {
    audio.preferredFilename = "canonical.aiff"
    let audioDirWrapper = FileWrapper(directoryWithFileWrappers: ["canonical.aiff": audio])
    audioDirWrapper.preferredFilename = "audio"

    var children: [String: FileWrapper] = [
      "plan.json": try metadataWrapper(plan),
      "audio": audioDirWrapper,
    ]
    if let recoveryArchive {
      children["suggestion-recovery.json"] = FileWrapper(regularFileWithContents: recoveryArchive)
    }
    let root = FileWrapper(directoryWithFileWrappers: children)
    var file = file
    file.masteringRun = try reconcileMastering(
      in: root, run: file.masteringRun,
      staged: masteringStaged, strictMissing: strictMissing)
    file.schemaVersion = ProjectFile.writtenSchemaVersion(for: file)
    let metadata = try metadataWrapper(file)
    metadata.preferredFilename = "project.json"
    root.addFileWrapper(metadata)
    return root
  }

  static func replaceAudio(in root: FileWrapper, with audio: FileWrapper) {
    audio.preferredFilename = "canonical.aiff"
    if let directory = root.fileWrappers?["audio"], directory.isDirectory {
      if let old = directory.fileWrappers?["canonical.aiff"] { directory.removeFileWrapper(old) }
      directory.addFileWrapper(audio)
    } else {
      if let old = root.fileWrappers?["audio"] { root.removeFileWrapper(old) }
      let directory = FileWrapper(directoryWithFileWrappers: ["canonical.aiff": audio])
      directory.preferredFilename = "audio"
      root.addFileWrapper(directory)
    }
  }

  /// Rewrites `project.json` and `plan.json` inside an on-disk package's root wrapper and
  /// returns that same root. The `audio` child is left untouched — it stays parented to the
  /// existing tree (moving a read-from-disk child into a new tree trips `FileWrapper`'s
  /// parent bookkeeping), and NSDocument sees it as unchanged so a save never re-copies the
  /// AIFF.
  static func rewriteMetadata(
    in root: FileWrapper, file: ProjectFile, plan: EditPlan, recoveryArchive: Data? = nil,
    // swiftlint:disable:next inclusive_language
    masteringStaged: [String: StagedMasteringArtifact] = [:], strictMissing: Bool = false,
    // swiftlint:disable:next inclusive_language
    preserveMasteringWhenAbsent: Bool = false
  ) throws
    -> FileWrapper
  {
    var file = file
    let hadCorruptManifest = preserveMasteringWhenAbsent && file.masteringRun == nil
    file.masteringRun = try reconcileMastering(
      in: root, run: file.masteringRun,
      staged: masteringStaged, strictMissing: strictMissing,
      preserveExistingWhenAbsent: preserveMasteringWhenAbsent)
    // A preserved-but-still-undecodable run keeps schema 3, so a later open still knows to
    // treat the untouched `mastering/` directory as belonging to a corrupt manifest rather
    // than as orphaned schema-2 leftovers to discard.
    file.schemaVersion =
      hadCorruptManifest
      ? ProjectFile.maximumReadableSchemaVersion : ProjectFile.writtenSchemaVersion(for: file)
    let project = try metadataWrapper(file)
    let planWrapper = try metadataWrapper(plan)
    for name in ["project.json", "plan.json", "suggestion-recovery.json"] {
      if let stale = root.fileWrappers?[name] { root.removeFileWrapper(stale) }
    }
    project.preferredFilename = "project.json"
    planWrapper.preferredFilename = "plan.json"
    root.addFileWrapper(project)
    root.addFileWrapper(planWrapper)
    if let recoveryArchive {
      let archive = FileWrapper(regularFileWithContents: recoveryArchive)
      archive.preferredFilename = "suggestion-recovery.json"
      root.addFileWrapper(archive)
    }
    return root
  }

  // swiftlint:disable:next inclusive_language
  enum MasteringReconcileError: Error, Equatable, LocalizedError {
    case missingArtifact(String)

    var errorDescription: String? {
      switch self {
      case .missingArtifact(let name):
        return
          "Couldn't copy the mastering file \(name) into this project. The original project is unchanged."
      }
    }
  }

  // swiftlint:disable:next inclusive_language
  static func reconcileMastering(
    in root: FileWrapper, run: MasteringRun?, staged: [String: StagedMasteringArtifact],
    strictMissing: Bool = false,
    preserveExistingWhenAbsent: Bool = false
  ) throws -> MasteringRun? {
    // A corrupt manifest decodes as `run == nil` indistinguishably from "never had a run."
    // When the caller knows this save follows a corrupt-manifest open, leave any on-disk
    // `mastering/` directory untouched rather than reconciling it away as orphaned.
    if run == nil, preserveExistingWhenAbsent {
      return nil
    }
    let existingDirectory = root.fileWrappers?["mastering"]
    let existing =
      existingDirectory?.isDirectory == true ? existingDirectory?.fileWrappers ?? [:] : [:]
    let available = try availableMasteringArtifacts(
      for: run, existing: existing, staged: staged, strictMissing: strictMissing)
    let healed = run?.healed(available: available.compactMapValues(masteringSize))
    let retainedNames = Set(healed?.referencedArtifacts.map(\.fileName) ?? [])
    if retainedNames.isEmpty {
      if let existingDirectory { root.removeFileWrapper(existingDirectory) }
    } else if let existingDirectory, existingDirectory.isDirectory {
      for (name, child) in existing
      where !retainedNames.contains(name)
        || available[name] !== child
      {
        existingDirectory.removeFileWrapper(child)
      }
      for (name, child) in available
      where retainedNames.contains(name)
        && existingDirectory.fileWrappers?[name] == nil
      {
        child.preferredFilename = name
        existingDirectory.addFileWrapper(child)
      }
    } else {
      if let existingDirectory { root.removeFileWrapper(existingDirectory) }
      let wrappers = available.filter { retainedNames.contains($0.key) }
      let directory = FileWrapper(directoryWithFileWrappers: wrappers)
      directory.preferredFilename = "mastering"
      root.addFileWrapper(directory)
    }
    return healed
  }

  // swiftlint:disable:next inclusive_language
  private static func availableMasteringArtifacts(
    for run: MasteringRun?, existing: [String: FileWrapper],
    staged: [String: StagedMasteringArtifact], strictMissing: Bool
  ) throws -> [String: FileWrapper] {
    var available: [String: FileWrapper] = [:]
    for ref in run?.referencedArtifacts ?? [] where ref.isWellFormed {
      if let child = existing[ref.fileName], masteringSize(child) == ref.byteCount {
        available[ref.fileName] = child
      } else if let owner = staged[ref.fileName],
        (try? owner.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == ref.byteCount
      {
        let wrapper = try FileWrapper(url: owner.url, options: [])
        wrapper.preferredFilename = ref.fileName
        available[ref.fileName] = wrapper
      } else if strictMissing {
        throw MasteringReconcileError.missingArtifact(ref.fileName)
      }
    }
    return available
  }

  // swiftlint:disable:next inclusive_language
  static func masteringSize(_ wrapper: FileWrapper) -> Int? {
    guard wrapper.isRegularFile, !wrapper.isSymbolicLink else { return nil }
    return (wrapper.fileAttributes[FileAttributeKey.size.rawValue] as? NSNumber)?.intValue
      ?? wrapper.regularFileContents?.count
  }

  private static func metadataWrapper(_ file: ProjectFile) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: try projectEncoder().encode(file))
  }

  private static func metadataWrapper(_ plan: EditPlan) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: try JSONEncoder().encode(plan))
  }

  /// Confirms the bundled canonical AIFF hasn't been truncated or swapped since
  /// `project.json` was written. Only checks byte count — header sample-rate/channel
  /// checks are deferred to the hydration step in PR 5, where an `AVAudioFile` is
  /// opened anyway (spec A5/A8).
  ///
  /// Prefers the wrapper's file-system size attribute (present on a wrapper read from disk)
  /// so a multi-GB AIFF is never pulled into memory just to count it; an in-memory wrapper
  /// has no such attribute and falls back to its contents.
  static func verifyAudio(_ wrapper: FileWrapper, against source: ProjectSource) throws {
    let byteCount =
      (wrapper.fileAttributes[FileAttributeKey.size.rawValue] as? NSNumber)?.intValue
      ?? wrapper.regularFileContents?.count
    guard byteCount == source.canonicalByteCount else {
      throw ProjectPackageError.audioMismatch
    }
  }
}
