import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct ProjectPackageTests {
  @Test func decodeKeepsAvailablePiecesWhenOneFinishedFileIsMissing() throws {
    let names = (100...102).map { Fixtures.uuid($0).uuidString.lowercased() }
    let prepared = MasteringArtifactRef(fileName: names[0] + ".wav", byteCount: 4)
    let first = MasteringArtifactRef(fileName: names[1] + ".m4a", byteCount: 4)
    let second = MasteringArtifactRef(fileName: names[2] + ".m4a", byteCount: 4)
    var file = Fixtures.projectFile()
    file.masteringRun = MasteringRun(
      id: Fixtures.uuid(103), artist: "Artist", inputsDigest: "v1:x",
      parts: [
        MasteringPart(
          id: Fixtures.uuid(104), frameCount: 20, prepared: prepared,
          pieces: [
            MasteringPiece(
              id: Fixtures.uuid(105), sliceID: Fixtures.uuid(106), title: "One",
              startFrame: 0, frameCount: 10, lrc: "", finished: first),
            MasteringPiece(
              id: Fixtures.uuid(107), sliceID: Fixtures.uuid(108), title: "Two",
              startFrame: 10, frameCount: 10, lrc: "", finished: second),
          ])
      ])
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    var staged: [String: StagedMasteringArtifact] = [:]
    for ref in [prepared, first, second] {
      let source = base.appendingPathComponent(UUID().uuidString)
      try Data("file".utf8).write(to: source)
      staged[ref.fileName] = try MasteringStagingStore.adopt(source, as: ref.fileName, in: base)
    }
    let root = try ProjectPackage.encode(
      file: file, plan: Fixtures.editPlan(),
      audio: FileWrapper(regularFileWithContents: Data("audio".utf8)),
      masteringStaged: staged, strictMissing: true)
    let missing = try #require(root.fileWrappers?["mastering"]?.fileWrappers?[second.fileName])
    root.fileWrappers?["mastering"]?.removeFileWrapper(missing)
    let reopened = try ProjectPackage.decode(root)
    expectNoDifference(reopened.file.masteringRun?.parts[0].prepared, prepared)
    expectNoDifference(reopened.file.masteringRun?.parts[0].pieces[0].finished, first)
    expectNoDifference(reopened.file.masteringRun?.parts[0].pieces[1].finished, nil)
    expectNoDifference(reopened.file.masteringRun?.parts[0].isReturned, false)
  }

  // swiftlint:disable:next inclusive_language
  @Test func reconciliationRemovesMalformedMasteringDirectoryChild() throws {
    let root = try ProjectPackage.encode(
      file: Fixtures.projectFile(), plan: Fixtures.editPlan(),
      audio: FileWrapper(regularFileWithContents: Data("audio".utf8)))
    let malformed = FileWrapper(regularFileWithContents: Data("junk".utf8))
    malformed.preferredFilename = "mastering"
    root.addFileWrapper(malformed)
    expectNoDifference(try ProjectPackage.decode(root).file.masteringRun, nil)
    expectNoDifference(try ProjectPackage.reconcileMastering(in: root, run: nil, staged: [:]), nil)
    expectNoDifference(root.fileWrappers?["mastering"], nil)
  }
  // swiftlint:disable:next inclusive_language
  @Test func masteringReconciliationReusesUnchangedWrapperAndReplacesOldIdentity() throws {
    let firstName = Fixtures.uuid(60).uuidString.lowercased() + ".wav"
    let secondName = Fixtures.uuid(61).uuidString.lowercased() + ".wav"
    let root = try ProjectPackage.encode(
      file: Fixtures.projectFile(), plan: Fixtures.editPlan(),
      audio: FileWrapper(regularFileWithContents: Data("audio".utf8)))
    let old = FileWrapper(regularFileWithContents: Data("old".utf8))
    old.preferredFilename = firstName
    let dir = FileWrapper(directoryWithFileWrappers: [firstName: old])
    dir.preferredFilename = "mastering"
    root.addFileWrapper(dir)
    let run = masteringRun(preparedName: firstName, byteCount: 3)
    let healed = try ProjectPackage.reconcileMastering(in: root, run: run, staged: [:])
    expectNoDifference(healed, run)
    #expect(root.fileWrappers?["mastering"]?.fileWrappers?[firstName] === old)

    let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stagingRoot) }
    let source = stagingRoot.appendingPathComponent("source.wav")
    try Data("new".utf8).write(to: source)
    let staged = try MasteringStagingStore.adopt(source, as: secondName, in: stagingRoot)
    let replaced = masteringRun(preparedName: secondName, byteCount: 3)
    expectNoDifference(
      try ProjectPackage.reconcileMastering(
        in: root, run: replaced,
        staged: [secondName: staged]), replaced)
    expectNoDifference(root.fileWrappers?["mastering"]?.fileWrappers?[firstName], nil)
    expectNoDifference(root.fileWrappers?["mastering"]?.fileWrappers?[secondName] != nil, true)
    expectNoDifference(try ProjectPackage.reconcileMastering(in: root, run: nil, staged: [:]), nil)
    expectNoDifference(root.fileWrappers?["mastering"], nil)
  }

  // swiftlint:disable:next inclusive_language
  @Test func decodeHealsMissingMasteringMediaWithoutBlockingInterview() throws {
    var file = Fixtures.projectFile()
    file.masteringRun = masteringRun(
      preparedName: Fixtures.uuid(70).uuidString.lowercased() + ".wav",
      byteCount: 5)
    file.schemaVersion = 3
    let root = try ProjectPackage.encode(
      file: file, plan: Fixtures.editPlan(),
      audio: FileWrapper(regularFileWithContents: Data("audio".utf8)))
    let decoded = try ProjectPackage.decode(root)
    expectNoDifference(decoded.file.masteringRun?.parts[0].prepared, nil)
    expectNoDifference(decoded.file.masteringRun?.parts.count, 1)
  }

  // swiftlint:disable:next inclusive_language
  private func masteringRun(preparedName: String, byteCount: Int) -> MasteringRun {
    MasteringRun(
      id: Fixtures.uuid(72), artist: "Artist", inputsDigest: "v1:abc",
      parts: [
        MasteringPart(
          id: Fixtures.uuid(73), frameCount: 10,
          prepared: MasteringArtifactRef(fileName: preparedName, byteCount: byteCount),
          pieces: [
            MasteringPiece(
              id: Fixtures.uuid(74), sliceID: Fixtures.uuid(75), title: "Intro",
              startFrame: 0, frameCount: 10, lrc: "", finished: nil)
          ])
      ])
  }

  @Test func unsupportedFormatExposesReasonInDocumentOpenAlert() {
    let version = ProjectFile.maximumReadableSchemaVersion + 1
    let error = ProjectPackageError.unsupportedSchema(version) as NSError
    expectNoDifference(
      error.localizedFailureReason,
      "This project (format \(version)) was saved by a newer version of the app.")
    expectNoDifference(
      error.localizedRecoverySuggestion,
      "Open this project with the version of the app that last saved it, or a newer version.")
  }

  @Test func malformedRecoveryChildIsNotSilentlyDropped() throws {
    let root = try ProjectPackage.encode(
      file: Fixtures.projectFile(), plan: Fixtures.editPlan(),
      audio: FileWrapper(regularFileWithContents: Data()))
    let invalid = FileWrapper(directoryWithFileWrappers: [:])
    invalid.preferredFilename = "suggestion-recovery.json"
    root.addFileWrapper(invalid)
    #expect(throws: ProjectPackageError.malformedRecoveryArchive) {
      try ProjectPackage.decode(root)
    }
  }

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

  @Test func wholeSecondImportedAtRoundTripsExactly() throws {
    let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let file = Fixtures.projectFile(source: Fixtures.projectSource(importedAt: importedAt))
    let audioWrapper = FileWrapper(regularFileWithContents: Data("audio".utf8))

    let root = try ProjectPackage.encode(file: file, plan: Fixtures.editPlan(), audio: audioWrapper)
    let decoded = try ProjectPackage.decode(root)

    expectNoDifference(decoded.file.source.importedAt, importedAt)
  }

  @Test func fractionalImportedAtNormalizesToWholeSeconds() throws {
    // The format carries whole seconds only: a sub-second component is dropped on
    // encode and must not survive the round trip (ProjectPackage precision contract).
    let file = Fixtures.projectFile(
      source: Fixtures.projectSource(importedAt: Date(timeIntervalSince1970: 1_700_000_000.75)))
    let audioWrapper = FileWrapper(regularFileWithContents: Data("audio".utf8))

    let root = try ProjectPackage.encode(file: file, plan: Fixtures.editPlan(), audio: audioWrapper)
    let decoded = try ProjectPackage.decode(root)

    expectNoDifference(
      decoded.file.source.importedAt, Date(timeIntervalSince1970: 1_700_000_000))
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

  @Test func decodeSupportsBothHistoricalAndCurrentSchema() throws {
    for version in 1...ProjectFile.currentSchemaVersion {
      var file = Fixtures.projectFile()
      file.schemaVersion = version
      let projectJSON = encodedProjectFile(file)
      let root = tree(
        projectJSON: projectJSON, planJSON: encodedPlan(Fixtures.editPlan()),
        audio: Data("audio".utf8))
      let decoded = try ProjectPackage.decode(root)
      expectNoDifference(decoded.file, file)
      expectNoDifference(root.fileWrappers?["project.json"]?.regularFileContents, projectJSON)
    }
  }

  @Test func decodeUnsupportedSchemaThrows() {
    var file = Fixtures.projectFile()
    file.schemaVersion = ProjectFile.maximumReadableSchemaVersion + 1
    let root = tree(
      projectJSON: encodedProjectFile(file), planJSON: encodedPlan(Fixtures.editPlan()),
      audio: Data("audio".utf8))
    #expect(
      throws: ProjectPackageError.unsupportedSchema(ProjectFile.maximumReadableSchemaVersion + 1)
    ) {
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

  @Test func verifyAudioUsesTheWrapperSizeAttributeWhenPresent() throws {
    // A wrapper read from disk carries the file-system size; the check must not need to load
    // (and must trust) the contents.
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-verify-\(UUID().uuidString).aiff")
    try Data("on-disk-audio".utf8).write(to: url)
    let wrapper = try FileWrapper(url: url, options: [])
    #expect((wrapper.fileAttributes[FileAttributeKey.size.rawValue] as? NSNumber)?.intValue == 13)
    try ProjectPackage.verifyAudio(wrapper, against: Fixtures.projectSource(canonicalByteCount: 13))
    #expect(throws: ProjectPackageError.audioMismatch) {
      try ProjectPackage.verifyAudio(
        wrapper, against: Fixtures.projectSource(canonicalByteCount: 12))
    }
  }

  @Test func errorsCarryUserFacingDescriptions() {
    expectNoDifference(
      ProjectPackageError.unsupportedSchema(7).errorDescription,
      "This project (format 7) was saved by a newer version of the app.")
    // Schema 0 (or below) is malformed, not from the future; don't blame a newer app.
    expectNoDifference(
      ProjectPackageError.unsupportedSchema(0).errorDescription,
      "This project uses an unsupported format version (0).")
    expectNoDifference(
      ProjectPackageError.audioMismatch.errorDescription,
      "The project's bundled audio does not match the project.")
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
