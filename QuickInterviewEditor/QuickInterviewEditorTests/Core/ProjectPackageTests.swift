import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct ProjectPackageTests {

  // MARK: - Helpers

  private func tree(projectJSON: Data, planJSON: Data, audio: Data?) -> FileWrapper {
    var children: [String: FileWrapper] = [
      "project.json": FileWrapper(regularFileWithContents: projectJSON),
      "plan.json": FileWrapper(regularFileWithContents: planJSON),
    ]
    if let audio {
      children["audio"] = FileWrapper(directoryWithFileWrappers: [
        "canonical.aiff": FileWrapper(regularFileWithContents: audio)
      ])
    }
    return FileWrapper(directoryWithFileWrappers: children)
  }

  private func encodedProjectFile(_ file: ProjectFile) -> Data {
    // swiftlint:disable:next force_try
    try! ProjectPackage.projectEncoder().encode(file)
  }

  private func encodedPlan(_ plan: EditPlan) -> Data {
    // swiftlint:disable:next force_try
    try! JSONEncoder().encode(plan)
  }

  // MARK: - Round trip

  @Test func encodeThenDecodeRoundTripsFileAndPlan() throws {
    let file = Fixtures.projectFile()
    let plan = Fixtures.editPlan()
    let audioData = Data("canonical-audio-bytes".utf8)
    let audioWrapper = FileWrapper(regularFileWithContents: audioData)

    let root = try ProjectPackage.encode(file: file, plan: plan, audio: audioWrapper)
    let decoded = try ProjectPackage.decode(root)

    expectNoDifference(decoded.file, file)
    expectNoDifference(decoded.plan, plan)
    expectNoDifference(decoded.audioWrapper.regularFileContents, audioData)
  }

  @Test func importedAtRoundTripsExactly() throws {
    let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let file = Fixtures.projectFile(source: Fixtures.projectSource(importedAt: importedAt))
    let audioWrapper = FileWrapper(regularFileWithContents: Data("audio".utf8))

    let root = try ProjectPackage.encode(file: file, plan: Fixtures.editPlan(), audio: audioWrapper)
    let decoded = try ProjectPackage.decode(root)

    expectNoDifference(decoded.file.source.importedAt, importedAt)
  }

  // MARK: - Missing pieces

  @Test func decodeMissingProjectJSONThrows() {
    let root = FileWrapper(directoryWithFileWrappers: [
      "plan.json": FileWrapper(regularFileWithContents: encodedPlan(Fixtures.editPlan()))
    ])
    #expect(throws: ProjectPackageError.missingProjectJSON) {
      try ProjectPackage.decode(root)
    }
  }

  @Test func decodeMissingPlanJSONThrows() {
    let root = tree(
      projectJSON: encodedProjectFile(Fixtures.projectFile()), planJSON: Data(), audio: nil)
    // Remove plan.json to simulate it being absent (tree always adds it above).
    let projectOnly = FileWrapper(directoryWithFileWrappers: [
      "project.json": root.fileWrappers!["project.json"]!
    ])
    #expect(throws: ProjectPackageError.missingPlanJSON) {
      try ProjectPackage.decode(projectOnly)
    }
  }

  @Test func decodeMissingAudioThrows() {
    let root = tree(
      projectJSON: encodedProjectFile(Fixtures.projectFile()),
      planJSON: encodedPlan(Fixtures.editPlan()), audio: nil)
    #expect(throws: ProjectPackageError.missingAudio) {
      try ProjectPackage.decode(root)
    }
  }

  // MARK: - Schema

  @Test func decodeUnsupportedSchemaThrows() {
    var file = Fixtures.projectFile()
    file.schemaVersion = 2
    let root = tree(
      projectJSON: encodedProjectFile(file), planJSON: encodedPlan(Fixtures.editPlan()),
      audio: Data("audio".utf8))
    #expect(throws: ProjectPackageError.unsupportedSchema(2)) {
      try ProjectPackage.decode(root)
    }
  }

  @Test(arguments: [0, -1]) func decodeSchemaVersionBelowOneThrows(_ version: Int) {
    var file = Fixtures.projectFile()
    file.schemaVersion = version
    let root = tree(
      projectJSON: encodedProjectFile(file), planJSON: encodedPlan(Fixtures.editPlan()),
      audio: Data("audio".utf8))
    #expect(throws: ProjectPackageError.unsupportedSchema(version)) {
      try ProjectPackage.decode(root)
    }
  }

  @Test func decodeAudioAsDirectoryThrowsMissingAudio() {
    let children: [String: FileWrapper] = [
      "project.json": FileWrapper(
        regularFileWithContents: encodedProjectFile(Fixtures.projectFile())),
      "plan.json": FileWrapper(regularFileWithContents: encodedPlan(Fixtures.editPlan())),
      "audio": FileWrapper(directoryWithFileWrappers: [
        // A directory where the canonical AIFF file should be must not read as present audio.
        "canonical.aiff": FileWrapper(directoryWithFileWrappers: [:])
      ]),
    ]
    #expect(throws: ProjectPackageError.missingAudio) {
      try ProjectPackage.decode(FileWrapper(directoryWithFileWrappers: children))
    }
  }

  // MARK: - Audio integrity

  @Test func verifyAudioPassesWhenByteCountMatches() throws {
    let audioData = Data("canonical-audio-bytes".utf8)
    let source = Fixtures.projectSource(canonicalByteCount: audioData.count)
    try ProjectPackage.verifyAudio(FileWrapper(regularFileWithContents: audioData), against: source)
  }

  @Test func verifyAudioThrowsWhenByteCountMismatches() {
    let audioData = Data("canonical-audio-bytes".utf8)
    let source = Fixtures.projectSource(canonicalByteCount: audioData.count + 1)
    #expect(throws: ProjectPackageError.audioMismatch) {
      try ProjectPackage.verifyAudio(
        FileWrapper(regularFileWithContents: audioData), against: source)
    }
  }

  // MARK: - Bundled fixture

  @Test func decodesBundledProjectV1Fixture() throws {
    let url = Bundle(for: BundleToken.self)
      .url(forResource: "project-v1", withExtension: "pie")!
    let root = try FileWrapper(url: url, options: [.immediate])

    let decoded = try ProjectPackage.decode(root)
    try ProjectPackage.verifyAudio(decoded.audioWrapper, against: decoded.file.source)

    expectNoDifference(decoded.file.schemaVersion, 1)
    expectNoDifference(
      decoded.file.source.importedAt, Date(timeIntervalSince1970: 1_700_000_000))
  }
}

private final class BundleToken {}
