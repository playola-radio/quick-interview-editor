import Foundation

/// Errors decoding or validating a `.pie` package's `FileWrapper` tree (spec A2).
enum ProjectPackageError: Error, Equatable {
  case missingProjectJSON
  case missingPlanJSON
  case missingAudio
  case unsupportedSchema(Int)
  case audioMismatch
}

/// The three pieces decoded from a `.pie` package: the small project file, the
/// engine's plan verbatim, and the still-wrapped canonical audio (never re-serialized).
struct DecodedPackage {
  var file: ProjectFile
  var plan: EditPlan
  var audioWrapper: FileWrapper
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
    guard (1...ProjectFile.currentSchemaVersion).contains(probe.schemaVersion) else {
      throw ProjectPackageError.unsupportedSchema(probe.schemaVersion)
    }
    let file = try projectDecoder().decode(ProjectFile.self, from: projectData)

    guard let planData = root.fileWrappers?["plan.json"]?.regularFileContents else {
      throw ProjectPackageError.missingPlanJSON
    }
    let plan = try JSONDecoder().decode(EditPlan.self, from: planData)

    guard let audioWrapper = root.fileWrappers?["audio"]?.fileWrappers?["canonical.aiff"],
      audioWrapper.isRegularFile
    else {
      throw ProjectPackageError.missingAudio
    }

    return DecodedPackage(file: file, plan: plan, audioWrapper: audioWrapper)
  }

  static func encode(file: ProjectFile, plan: EditPlan, audio: FileWrapper) throws -> FileWrapper {
    let projectWrapper = FileWrapper(regularFileWithContents: try projectEncoder().encode(file))
    projectWrapper.preferredFilename = "project.json"

    let planWrapper = FileWrapper(regularFileWithContents: try JSONEncoder().encode(plan))
    planWrapper.preferredFilename = "plan.json"

    audio.preferredFilename = "canonical.aiff"
    let audioDirWrapper = FileWrapper(directoryWithFileWrappers: ["canonical.aiff": audio])
    audioDirWrapper.preferredFilename = "audio"

    return FileWrapper(directoryWithFileWrappers: [
      "project.json": projectWrapper,
      "plan.json": planWrapper,
      "audio": audioDirWrapper,
    ])
  }

  /// Confirms the bundled canonical AIFF hasn't been truncated or swapped since
  /// `project.json` was written. Only checks byte count — header sample-rate/channel
  /// checks are deferred to the hydration step in PR 5, where an `AVAudioFile` is
  /// opened anyway (spec A5/A8).
  static func verifyAudio(_ wrapper: FileWrapper, against source: ProjectSource) throws {
    guard let contents = wrapper.regularFileContents,
      contents.count == source.canonicalByteCount
    else {
      throw ProjectPackageError.audioMismatch
    }
  }
}
