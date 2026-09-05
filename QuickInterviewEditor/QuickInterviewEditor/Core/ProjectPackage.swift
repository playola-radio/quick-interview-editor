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
  static func decode(_ root: FileWrapper) throws -> DecodedPackage {
    guard let projectData = root.fileWrappers?["project.json"]?.regularFileContents else {
      throw ProjectPackageError.missingProjectJSON
    }
    let file = try JSONDecoder().decode(ProjectFile.self, from: projectData)
    guard file.schemaVersion <= ProjectFile.currentSchemaVersion else {
      throw ProjectPackageError.unsupportedSchema(file.schemaVersion)
    }

    guard let planData = root.fileWrappers?["plan.json"]?.regularFileContents else {
      throw ProjectPackageError.missingPlanJSON
    }
    let plan = try JSONDecoder().decode(EditPlan.self, from: planData)

    guard let audioWrapper = root.fileWrappers?["audio"]?.fileWrappers?["canonical.aiff"] else {
      throw ProjectPackageError.missingAudio
    }

    return DecodedPackage(file: file, plan: plan, audioWrapper: audioWrapper)
  }

  static func encode(file: ProjectFile, plan: EditPlan, audio: FileWrapper) throws -> FileWrapper {
    let projectWrapper = FileWrapper(regularFileWithContents: try JSONEncoder().encode(file))
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
