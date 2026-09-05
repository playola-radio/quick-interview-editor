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
    try! JSONEncoder().encode(file)
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
      try ProjectPackage.verifyAudio(FileWrapper(regularFileWithContents: audioData), against: source)
    }
  }
}
