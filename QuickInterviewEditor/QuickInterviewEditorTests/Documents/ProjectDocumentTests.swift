import CustomDump
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import PlayolaInterviewEditor

/// The codec through the document type: reading a package, reusing its audio on save, and the
/// session-file fallbacks. `FileDocumentReadConfiguration`/`WriteConfiguration` have no public
/// initializers, so these exercise the `init(reading:)` / `makeFileWrapper(snapshot:existingFile:)`
/// seams the system hooks delegate to.
@MainActor
struct ProjectDocumentTests {
  @Test
  func openingStagesReferencedMediaSoAFreshTreeSaveNeverNeedsTheExistingPackage() throws {
    let name = Fixtures.uuid(86).uuidString.lowercased() + ".wav"
    let bytes = Data("wav".utf8)
    let audio = Data("canonical".utf8)
    let (root, file) = try packageRootWithFinishedRunMedia(
      name: name, bytes: bytes, audio: audio, seed: 86)
    // Opening stages this intact media into an owned session copy (a cheap APFS clone via
    // `FileManager.copyItem`, the same mechanism `CanonicalAudioStore` already relies on to avoid
    // real disk duplication) so a later fresh-tree save always has a source, even with no
    // `existingFile` to self-heal from (Greptile PR #105: "fresh-tree saves lack mastering media").
    let document = try ProjectDocument(reading: root)
    var content = try #require(document.content)
    expectNoDifference(content.file.masteringRun, file.masteringRun)
    let stagedURL = try #require(content.masteringStaged[name]?.url)
    expectNoDifference(try Data(contentsOf: stagedURL), bytes)
    let audioURL = try tempAudioFile(audio)
    defer { try? FileManager.default.removeItem(at: audioURL) }
    content.audio = .packageChild(sessionCopy: audioURL)
    // Save As / Duplicate onto a brand-new file — no existing package to consult at all — still
    // writes the complete manifest using the staged copy taken at open.
    let freshTree = try ProjectDocument.makeFileWrapper(snapshot: content, existingFile: nil)
    expectNoDifference(try ProjectPackage.decode(freshTree).file.masteringRun, file.masteringRun)
    expectNoDifference(
      try #require(freshTree.fileWrappers?["mastering"]?.fileWrappers?[name]?.regularFileContents),
      bytes)
    // An ordinary in-place save reuses `root`'s own `mastering/` child directly.
    let ordinary = try ProjectDocument.makeFileWrapper(snapshot: content, existingFile: root)
    expectNoDifference(try ProjectPackage.decode(ordinary).file.masteringRun, file.masteringRun)
    // A re-transcribe still builds a fresh tree, but self-heals the untouched mastering media
    // from `existingFile` (`root`) on demand rather than requiring it to have been staged already.
    let replacementAudio = Data("new canonical".utf8)
    let replacementURL = try tempAudioFile(replacementAudio)
    defer { try? FileManager.default.removeItem(at: replacementURL) }
    content.file.source.canonicalByteCount = replacementAudio.count
    content.audio = .sessionFile(replacementURL)
    let retranscribed = try ProjectDocument.makeFileWrapper(snapshot: content, existingFile: root)
    expectNoDifference(
      try ProjectPackage.decode(retranscribed).file.masteringRun, file.masteringRun)
    expectNoDifference(try writtenAudio(of: retranscribed), replacementAudio)
  }

  // swiftlint:disable:next inclusive_language
  @Test func freshTreeSaveAfterCorruptManifestOpenPreservesIntactMasteringMedia() throws {
    let name = Fixtures.uuid(90).uuidString.lowercased() + ".wav"
    let bytes = Data("wav".utf8)
    let audio = Data("canonical".utf8)
    let (root, _) = try packageRootWithFinishedRunMedia(
      name: name, bytes: bytes, audio: audio, seed: 90)
    // Corrupt the manifest the same way `malformedMasteringManifestIsNotSilentlyDropped` does:
    // `masteringRun` fails to decode, so `ProjectPackage.decode` reports `masteringManifestCorrupt`
    // with a `nil` run even though `mastering/` on disk is still intact.
    guard let projectJSON = root.fileWrappers?["project.json"]?.regularFileContents,
      let text = String(bytes: projectJSON, encoding: .utf8)
    else { throw TestFailure() }
    let corruptedText = text.replacingOccurrences(
      of: "\"artist\":\"Artist\"", with: "\"artist\":42")
    #expect(corruptedText != text)
    let corrupted = FileWrapper(regularFileWithContents: Data(corruptedText.utf8))
    corrupted.preferredFilename = "project.json"
    root.removeFileWrapper(root.fileWrappers!["project.json"]!)
    root.addFileWrapper(corrupted)

    let document = try ProjectDocument(reading: root)
    var content = try #require(document.content)
    expectNoDifference(content.masteringManifestCorrupt, true)
    expectNoDifference(content.file.masteringRun, nil)
    let audioURL = try tempAudioFile(audio)
    defer { try? FileManager.default.removeItem(at: audioURL) }
    content.audio = .packageChild(sessionCopy: audioURL)

    // Save As / Duplicate onto a brand-new file — no existing package to consult at all, matching
    // `openingStagesReferencedMediaSoAFreshTreeSaveNeverNeedsTheExistingPackage`. `encode` builds a
    // fresh tree with no `existing` children to reuse, so the still-intact `mastering/` media has
    // to have been staged at open — there is no decoded `run` to stage referenced artifacts from,
    // so a corrupt manifest must still get its on-disk `mastering/` children staged wholesale.
    let freshTree = try ProjectDocument.makeFileWrapper(snapshot: content, existingFile: nil)
    let decoded = try ProjectPackage.decode(freshTree)
    expectNoDifference(decoded.masteringManifestCorrupt, true)
    expectNoDifference(
      try #require(freshTree.fileWrappers?["mastering"]?.fileWrappers?[name]?.regularFileContents),
      bytes)
  }

  @Test func freshTreeSaveRefusesWhenCorruptManifestStagingDroppedAFile() throws {
    let keptName = Fixtures.uuid(91).uuidString.lowercased() + ".wav"
    let droppedName = Fixtures.uuid(92).uuidString.lowercased() + ".wav"
    let bytes = Data("wav".utf8)
    let audio = Data("canonical".utf8)
    let (root, _) = try packageRootWithFinishedRunMedia(
      name: keptName, bytes: bytes, audio: audio, seed: 91)
    // swiftlint:disable:next inclusive_language
    let mastering = try #require(root.fileWrappers?["mastering"])
    let secondFile = FileWrapper(regularFileWithContents: bytes)
    secondFile.preferredFilename = droppedName
    mastering.addFileWrapper(secondFile)
    guard let projectJSON = root.fileWrappers?["project.json"]?.regularFileContents,
      let text = String(bytes: projectJSON, encoding: .utf8)
    else { throw TestFailure() }
    let corruptedText = text.replacingOccurrences(
      of: "\"artist\":\"Artist\"", with: "\"artist\":42")
    #expect(corruptedText != text)
    let corrupted = FileWrapper(regularFileWithContents: Data(corruptedText.utf8))
    corrupted.preferredFilename = "project.json"
    root.removeFileWrapper(root.fileWrappers!["project.json"]!)
    root.addFileWrapper(corrupted)

    let document = try ProjectDocument(reading: root)
    var content = try #require(document.content)
    expectNoDifference(content.masteringManifestCorrupt, true)
    expectNoDifference(content.masteringCorruptExpectedNames, [keptName, droppedName])
    // Simulate a dropped open-time staging attempt (or a staged file damaged/deleted afterward)
    // by removing one entry `masteringCorruptExpectedNames` still expects — this is exactly the
    // gap Codex flagged (PR #105 follow-up): with no `MasteringArtifactRef` to validate against,
    // a corrupt-manifest save had no way to notice fewer files landed than existed on disk.
    content.masteringStaged.removeValue(forKey: droppedName)
    let audioURL = try tempAudioFile(audio)
    defer { try? FileManager.default.removeItem(at: audioURL) }
    content.audio = .packageChild(sessionCopy: audioURL)

    #expect(throws: ProjectPackage.MasteringReconcileError.missingArtifact(droppedName)) {
      try ProjectDocument.makeFileWrapper(snapshot: content, existingFile: nil)
    }
  }

  private struct TestFailure: Error {}

  @Test func replacingRunKeepsStagedMediaAliveUntilTheWrapperItselfIsReleased() throws {
    let audio = Data("canonical".utf8)
    let file = Fixtures.projectFile(source: Fixtures.projectSource(canonicalByteCount: audio.count))
    let root = try ProjectPackage.encode(
      file: file, plan: Fixtures.editPlan(),
      audio: FileWrapper(regularFileWithContents: audio))
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let name = Fixtures.uuid(111).uuidString.lowercased() + ".wav"
    let source = base.appendingPathComponent("source.wav")
    try Data("file".utf8).write(to: source)
    var stagedURL: URL?
    do {
      let owner = try MasteringStagingStore.adopt(source, as: name, in: base)
      stagedURL = owner.url
      var withRun = file
      withRun.masteringRun = MasteringRun(
        id: Fixtures.uuid(112), artist: "Artist",
        inputsDigest: "v1:x",
        parts: [
          MasteringPart(
            id: Fixtures.uuid(113), frameCount: 10,
            prepared: MasteringArtifactRef(fileName: name, byteCount: 4),
            pieces: [
              MasteringPiece(
                id: Fixtures.uuid(114), sliceID: Fixtures.uuid(115), title: "Intro",
                startFrame: 0, frameCount: 10, lrc: "", finished: nil)
            ])
        ])
      let snapshot = ProjectDocument.Content(
        file: withRun, plan: Fixtures.editPlan(),
        audio: .packageChild(sessionCopy: nil), recoveryArchive: nil,
        masteringStaged: [name: owner])
      _ = try ProjectDocument.makeFileWrapper(snapshot: snapshot, existingFile: root)
    }
    let url = try #require(stagedURL)
    expectNoDifference(FileManager.default.fileExists(atPath: url.path), true)
    // A later save on the SAME wrapper (`root`) that no longer references this artifact must NOT
    // delete it out from under a still in-flight NSDocument disk write for the earlier save — see
    // `overlappingSavesOnTheSameWrapperRetainBothLeases` below. The source is only released once the
    // wrapper itself is (nothing holds `root` past this scope).
    let cleared = ProjectDocument.Content(
      file: file, plan: Fixtures.editPlan(),
      audio: .packageChild(sessionCopy: nil), recoveryArchive: nil)
    _ = try ProjectDocument.makeFileWrapper(snapshot: cleared, existingFile: root)
    expectNoDifference(FileManager.default.fileExists(atPath: url.path), true)
    withExtendedLifetime(root) {}
  }

  @Test
  // swiftlint:disable:next function_body_length
  func overlappingSavesOnTheSameWrapperRetainBothLeases() throws {
    let audio = Data("canonical".utf8)
    let file = Fixtures.projectFile(source: Fixtures.projectSource(canonicalByteCount: audio.count))
    let root = try ProjectPackage.encode(
      file: file, plan: Fixtures.editPlan(),
      audio: FileWrapper(regularFileWithContents: audio))
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    func stagedRun(nameSeed: Int, contents: Data) throws -> (String, StagedMasteringArtifact) {
      let name = Fixtures.uuid(nameSeed).uuidString.lowercased() + ".wav"
      let source = base.appendingPathComponent("source-\(nameSeed).wav")
      try contents.write(to: source)
      let owner = try MasteringStagingStore.adopt(source, as: name, in: base)
      return (name, owner)
    }

    // Save A stages media and writes it into `root`, mimicking an autosave whose returned
    // wrapper has not finished its (asynchronous, NSDocument-driven) disk write yet. Only
    // `wrapperA`'s lease may keep the staged source alive past this scope — every other strong
    // reference to it (the local `owner`, the snapshot's `masteringStaged`) must drop here so the
    // later check can't pass merely because the test itself is still holding the source.
    let bytesA = Data("file-a".utf8)
    var stagedURLA: URL?
    let wrapperA: FileWrapper = try {
      let (nameA, ownerA) = try stagedRun(nameSeed: 120, contents: bytesA)
      stagedURLA = ownerA.url
      var fileA = file
      fileA.masteringRun = MasteringRun(
        id: Fixtures.uuid(122), artist: "Artist", inputsDigest: "v1:a",
        parts: [
          MasteringPart(
            id: Fixtures.uuid(123), frameCount: 10,
            prepared: MasteringArtifactRef(fileName: nameA, byteCount: bytesA.count),
            pieces: [
              MasteringPiece(
                id: Fixtures.uuid(124), sliceID: Fixtures.uuid(125), title: "Intro",
                startFrame: 0, frameCount: 10, lrc: "", finished: nil)
            ])
        ])
      let snapshotA = ProjectDocument.Content(
        file: fileA, plan: Fixtures.editPlan(),
        audio: .packageChild(sessionCopy: nil), recoveryArchive: nil,
        masteringStaged: [nameA: ownerA])
      return try ProjectDocument.makeFileWrapper(snapshot: snapshotA, existingFile: root)
    }()

    // Save B lands on the SAME `root` object before A's write has consumed its sources — the
    // scenario Greptile flagged (PR #105, ProjectDocument.swift:25): a second save's lease must
    // not silently replace the first save's, or A's staged source can be deleted while A's disk
    // write still needs to read it.
    let bytesB = Data("file-b".utf8)
    let (nameB, ownerB) = try stagedRun(nameSeed: 126, contents: bytesB)
    var fileB = file
    fileB.masteringRun = MasteringRun(
      id: Fixtures.uuid(128), artist: "Artist", inputsDigest: "v1:b",
      parts: [
        MasteringPart(
          id: Fixtures.uuid(129), frameCount: 10,
          prepared: MasteringArtifactRef(fileName: nameB, byteCount: bytesB.count),
          pieces: [
            MasteringPiece(
              id: Fixtures.uuid(130), sliceID: Fixtures.uuid(131), title: "Intro",
              startFrame: 0, frameCount: 10, lrc: "", finished: nil)
          ])
      ])
    let snapshotB = ProjectDocument.Content(
      file: fileB, plan: Fixtures.editPlan(),
      audio: .packageChild(sessionCopy: nil), recoveryArchive: nil,
      masteringStaged: [nameB: ownerB])
    _ = try ProjectDocument.makeFileWrapper(snapshot: snapshotB, existingFile: root)

    // A's staged source must still be on disk — its lease must have survived B overwriting the
    // association on the shared wrapper — so A's still-in-flight write can complete.
    expectNoDifference(FileManager.default.fileExists(atPath: try #require(stagedURLA).path), true)
    withExtendedLifetime(wrapperA) {}
  }

  // swiftlint:disable:next inclusive_language
  @Test func saveAsRetainsLoadedMasteringAfterSnapshotAndDocumentRelease() throws {
    let rootDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("mastering-document-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootDir) }
    let fixture = try savedMediaFixture(in: rootDir)
    var document: ProjectDocument? = try ProjectDocument(
      reading: FileWrapper(url: fixture.original, options: []))
    // Opening already stages this project's intact `mastering/` media into its own owned copy
    // (see `openingStagesReferencedMediaSoAFreshTreeSaveNeverNeedsTheExistingPackage`).
    // `commitMastering` — the real "Prepare for Mastering" flow — replaces that copy wholesale
    // with its own freshly rendered output, which is what this test actually exercises.
    let owner = try MasteringStagingStore.copy(fixture.source, as: fixture.name, in: rootDir)
    document?.sink.commitMastering(fixture.file, [fixture.name: owner])
    var content = try #require(document?.content)
    expectNoDifference(content.file.masteringRun, fixture.file.masteringRun)
    let staged = try #require(content.masteringStaged[fixture.name]?.url)
    content.audio = .packageChild(sessionCopy: fixture.audioCopy)
    var snapshot: ProjectDocument.Content? = content
    var replaced = fixture.file
    replaced.masteringRun = nil
    document?.sink.commitMastering(replaced, [:])
    let current = try #require(document?.content)
    let currentWrapper = try ProjectDocument.makeFileWrapper(
      snapshot: current,
      existingFile: FileWrapper(url: fixture.original, options: []))
    let currentURL = rootDir.appendingPathComponent("current.pie")
    try currentWrapper.write(to: currentURL, options: [], originalContentsURL: nil)
    expectNoDifference(currentWrapper.fileWrappers?["mastering"], nil)
    try FileManager.default.removeItem(at: fixture.original)
    let wrapper = try ProjectDocument.makeFileWrapper(
      snapshot: try #require(snapshot),
      existingFile: nil)
    snapshot = nil
    content.masteringStaged = [:]
    document = nil
    expectNoDifference(FileManager.default.fileExists(atPath: staged.path), true)
    let copied = rootDir.appendingPathComponent("copy.pie")
    try wrapper.write(to: copied, options: [], originalContentsURL: nil)
    expectNoDifference(
      try Data(contentsOf: copied.appendingPathComponent("mastering/\(fixture.name)")),
      fixture.bytes)
    expectNoDifference(
      try ProjectPackage.decode(FileWrapper(url: copied, options: [])).file.masteringRun,
      fixture.file.masteringRun)
  }

  @Test func recoveryPublicationIsAtomicAndOrdinaryEditsRetainArchive() throws {
    let root = try fixturePackage()
    let document = try ProjectDocument(reading: root)
    var file = try #require(document.content?.file)
    let oldSnapshot = try document.snapshot(contentType: .pieProject)
    file.content.suggestionRecoveryOwnerID = Fixtures.uuid(90)
    let archive = Data("portable paid responses".utf8)
    document.sink.commitRecovery(file, archive)
    let accepted = try document.snapshot(contentType: .pieProject)
    expectNoDifference(oldSnapshot.content.recoveryArchive, nil)
    expectNoDifference(oldSnapshot.content.file.content.suggestionRecoveryOwnerID, nil)
    expectNoDifference(accepted.content.recoveryArchive, archive)
    expectNoDifference(accepted.content.file.content.suggestionRecoveryOwnerID, Fixtures.uuid(90))
    file.content.speakerCountOverride = 2
    document.sink.commit(file, nil, nil)
    expectNoDifference(document.content?.recoveryArchive, archive)
    let audio = try #require(root.fileWrappers?["audio"]?.fileWrappers?["canonical.aiff"])
    let saved = try ProjectDocument.makeFileWrapper(
      snapshot: try document.snapshot(contentType: .pieProject).content, existingFile: root)
    let decoded = try ProjectPackage.decode(saved)
    expectNoDifference(decoded.recoveryArchive, archive)
    #expect(decoded.audioWrapper === audio)
    let reopened = try ProjectDocument(reading: saved)
    expectNoDifference(reopened.content?.recoveryArchive, archive)
    document.sink.commitRecovery(file, nil)
    let removed = try ProjectDocument.makeFileWrapper(
      snapshot: try document.snapshot(contentType: .pieProject).content, existingFile: root)
    expectNoDifference(removed.fileWrappers?["suggestion-recovery.json"], nil)
  }

  // MARK: - Helpers

  private struct SavedMediaFixture {
    var file: ProjectFile
    var original: URL
    var name: String
    var bytes: Data
    var audioCopy: URL
    var source: URL
  }

  private func savedMediaFixture(in rootDir: URL) throws -> SavedMediaFixture {
    let name = Fixtures.uuid(81).uuidString.lowercased() + ".wav"
    let bytes = Data("prepared WAV".utf8)
    let audio = Data("canonical".utf8)
    var file = Fixtures.projectFile(source: Fixtures.projectSource(canonicalByteCount: audio.count))
    file.schemaVersion = 3
    file.masteringRun = MasteringRun(
      id: Fixtures.uuid(82), artist: "Artist", inputsDigest: "v1:x",
      parts: [
        MasteringPart(
          id: Fixtures.uuid(83), frameCount: 10,
          prepared: MasteringArtifactRef(fileName: name, byteCount: bytes.count),
          pieces: [
            MasteringPiece(
              id: Fixtures.uuid(84), sliceID: Fixtures.uuid(85), title: "Intro",
              startFrame: 0, frameCount: 10, lrc: "", finished: nil)
          ])
      ])
    let source = rootDir.appendingPathComponent("source.wav")
    try bytes.write(to: source)
    let staging = rootDir.appendingPathComponent("staging-source.wav")
    try bytes.write(to: staging)
    let owner = try MasteringStagingStore.adopt(staging, as: name, in: rootDir)
    let root = try ProjectPackage.encode(
      file: file, plan: Fixtures.editPlan(),
      audio: FileWrapper(regularFileWithContents: audio), masteringStaged: [name: owner])
    let original = rootDir.appendingPathComponent("original.pie")
    try root.write(to: original, options: [], originalContentsURL: nil)
    let audioCopy = rootDir.appendingPathComponent("session.aiff")
    try audio.write(to: audioCopy)
    return SavedMediaFixture(
      file: file, original: original, name: name, bytes: bytes, audioCopy: audioCopy, source: source
    )
  }

  private func fixturePackage() throws -> FileWrapper {
    let url = try #require(
      Bundle(for: BundleToken.self).url(forResource: "project-v1", withExtension: "pie"))
    return try FileWrapper(url: url, options: [.immediate])
  }

  private func packageTree(file: ProjectFile, audio: Data) throws -> FileWrapper {
    try ProjectPackage.encode(
      file: file, plan: Fixtures.editPlan(), audio: FileWrapper(regularFileWithContents: audio))
  }

  /// Builds a schema-3 package whose one run part references `name`/`bytes` and whose
  /// `mastering/` directory holds that same intact media, plus the `ProjectFile` (with the same
  /// run) that decoding it should produce.
  private func packageRootWithFinishedRunMedia(name: String, bytes: Data, audio: Data, seed: Int)
    throws -> (root: FileWrapper, file: ProjectFile)
  {
    var file = Fixtures.projectFile(source: Fixtures.projectSource(canonicalByteCount: audio.count))
    file.schemaVersion = 3
    file.masteringRun = MasteringRun(
      id: Fixtures.uuid(seed + 1), artist: "Artist", inputsDigest: "v1:x",
      parts: [
        MasteringPart(
          id: Fixtures.uuid(seed + 2), frameCount: 10,
          prepared: MasteringArtifactRef(fileName: name, byteCount: bytes.count),
          pieces: [
            MasteringPiece(
              id: Fixtures.uuid(seed + 3), sliceID: Fixtures.uuid(seed + 4), title: "Intro",
              startFrame: 0, frameCount: 10, lrc: "", finished: nil)
          ])
      ])
    let root = try ProjectPackage.encode(
      file: Fixtures.projectFile(source: file.source),
      plan: Fixtures.editPlan(), audio: FileWrapper(regularFileWithContents: audio))
    let project = FileWrapper(
      regularFileWithContents: try ProjectPackage.projectEncoder().encode(file))
    project.preferredFilename = "project.json"
    if let old = root.fileWrappers?["project.json"] { root.removeFileWrapper(old) }
    root.addFileWrapper(project)
    let media = FileWrapper(regularFileWithContents: bytes)
    media.preferredFilename = name
    let dir = FileWrapper(directoryWithFileWrappers: [name: media])
    dir.preferredFilename = "mastering"
    root.addFileWrapper(dir)
    return (root, file)
  }

  private func tempAudioFile(_ bytes: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-doc-\(UUID().uuidString).aiff")
    try bytes.write(to: url)
    return url
  }

  private func writtenAudio(of root: FileWrapper) throws -> Data {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-doc-\(UUID().uuidString).pie")
    try root.write(to: dir, options: [], originalContentsURL: nil)
    return try Data(contentsOf: dir.appendingPathComponent("audio/canonical.aiff"))
  }

  private func requireSendable<T: Sendable>(_: T.Type) {}

  // MARK: - Reading

  @Test func untouchedV1ReadKeepsBytesAndExplicitSaveUpgradesWithSameAudio() throws {
    let root = try fixturePackage()
    let bytes = try #require(root.fileWrappers?["project.json"]?.regularFileContents)
    let audio = try #require(root.fileWrappers?["audio"]?.fileWrappers?["canonical.aiff"])
    let document = try ProjectDocument(reading: root)
    let snapshot = try document.snapshot(contentType: .pieProject)
    expectNoDifference(snapshot.content.file.schemaVersion, 1)
    expectNoDifference(snapshot.content.file.content.suggestionRecoveryOwnerID, nil)
    expectNoDifference(snapshot.editGeneration, 0)
    expectNoDifference(root.fileWrappers?["project.json"]?.regularFileContents, bytes)

    let saved = try ProjectDocument.makeFileWrapper(snapshot: snapshot.content, existingFile: root)
    let reopened = try ProjectPackage.decode(saved)
    expectNoDifference(reopened.file.schemaVersion, 2)
    #expect(reopened.audioWrapper === audio)
    expectNoDifference(reopened.file.content, snapshot.content.file.content)
  }

  @Test func rereadingSavedPackageRestoresItsLedgerAndSchema() throws {
    let root = try fixturePackage()
    let document = try ProjectDocument(reading: root)
    let saved = try #require(document.content)
    var edited = saved.file
    edited.schemaVersion = 2
    edited.content.issuedSuggestionNumbers = [
      SequenceReservation(
        candidateID: Fixtures.uuid(7),
        key: .init(typeID: "spotlight", fields: [], provisionalCandidateID: nil),
        number: 3, canonicalValues: [:])
    ]
    document.sink.commit(edited, nil, nil)
    let reverted = try ProjectDocument(reading: root)
    expectNoDifference(reverted.content, saved)
    expectNoDifference(reverted.content?.file.schemaVersion, 1)
    expectNoDifference(reverted.content?.file.content.issuedSuggestionNumbers, [])
  }

  @Test func readableContentTypesIsThePieProjectType() {
    expectNoDifference(ProjectDocument.readableContentTypes, [.pieProject])
    expectNoDifference(UTType.pieProject.identifier, "fm.playola.interview-editor.project")
  }

  @Test func snapshotIsSendable() {
    requireSendable(ProjectDocument.Snapshot.self)
  }

  @Test func readingTheFixturePackageDecodesItsContent() throws {
    let root = try fixturePackage()
    let document = try ProjectDocument(reading: root)
    let content = try #require(document.content)
    let decoded = try ProjectPackage.decode(root)
    expectNoDifference(content.file, decoded.file)
    expectNoDifference(content.plan, decoded.plan)
    expectNoDifference(content.audio, .packageChild(sessionCopy: nil))
    expectNoDifference(content.file.source.canonicalByteCount, 936)
  }

  @Test func readingRefusesAPackageWhoseAudioSizeDisagreesWithProjectJSON() throws {
    let root = try packageTree(
      file: Fixtures.projectFile(source: Fixtures.projectSource(canonicalByteCount: 10)),
      audio: Data("short".utf8))
    #expect(throws: ProjectPackageError.audioMismatch) {
      try ProjectDocument(reading: root)
    }
  }

  @Test func emptyDocumentHasNoContent() {
    let document = ProjectDocument()
    #expect(document.content == nil)
  }

  @Test func snapshotOfAnEmptyDocumentThrows() {
    let document = ProjectDocument()
    #expect(throws: ProjectDocumentError.nothingToSave) {
      try document.snapshot(contentType: .pieProject)
    }
  }

  @Test func snapshotReturnsTheCurrentContent() throws {
    let document = try ProjectDocument(reading: try fixturePackage())
    let snapshot = try document.snapshot(contentType: .pieProject)
    expectNoDifference(snapshot.content, document.content)
  }

  @Test func snapshotCarriesTheCurrentEditGeneration() throws {
    let document = try ProjectDocument(reading: try fixturePackage())
    expectNoDifference(try document.snapshot(contentType: .pieProject).editGeneration, 0)

    document.sink.registerChange()
    document.sink.registerChange()

    expectNoDifference(try document.snapshot(contentType: .pieProject).editGeneration, 2)
  }

  @Test func snapshotIsTakenOffTheMainActorAfterAMainActorCommit() async throws {
    // NSDocument saves asynchronously and asks for the snapshot on a background thread.
    let document = ProjectDocument()
    let file = Fixtures.projectFile()
    let plan = Fixtures.editPlan()
    document.sink.commit(file, plan, .sessionFile(URL(fileURLWithPath: "/tmp/session.aiff")))

    let snapshot = try await Task.detached { try document.snapshot(contentType: .pieProject) }
      .value

    expectNoDifference(
      snapshot.content,
      ProjectDocument.Content(
        file: file, plan: plan, audio: .sessionFile(URL(fileURLWithPath: "/tmp/session.aiff"))))
  }

  // MARK: - Writing

  @Test func saveReusesTheExistingPackageAudioWrapperWhenAudioIsUnchanged() throws {
    let bytes = Data("package-audio".utf8)
    let existing = try packageTree(
      file: Fixtures.projectFile(source: Fixtures.projectSource(canonicalByteCount: bytes.count)),
      audio: bytes)
    let existingAudio = try #require(
      existing.fileWrappers?["audio"]?.fileWrappers?["canonical.aiff"])
    let edited = Fixtures.projectFile(
      source: Fixtures.projectSource(canonicalByteCount: bytes.count),
      content: Fixtures.editorDocumentState(
        slices: [], timelineRemovals: [], cutSuggestions: [],
        speakerCountOverride: 3, speakerDisplayNames: [:]))
    let snapshot = ProjectDocument.Content(
      file: edited, plan: Fixtures.editPlan(), audio: .packageChild(sessionCopy: nil))

    let written = try ProjectDocument.makeFileWrapper(snapshot: snapshot, existingFile: existing)

    // The on-disk root is rewritten in place: same root, same audio child, fresh metadata.
    #expect(written === existing)
    let writtenAudio = try #require(written.fileWrappers?["audio"]?.fileWrappers?["canonical.aiff"])
    #expect(writtenAudio === existingAudio)
    let reread = try ProjectPackage.decode(written)
    expectNoDifference(reread.file, edited)
    expectNoDifference(reread.file.content.speakerCountOverride, 3)
  }

  @Test func saveRefusesToReuseExistingPackageAudioWhoseSizeDriftedFromTheProject() throws {
    // The on-disk AIFF was truncated or swapped behind our back: the reuse path must apply
    // the same integrity gate as open and session-file saves rather than rewriting metadata
    // over mismatched audio.
    let bytes = Data("package-audio".utf8)
    let existing = try packageTree(
      file: Fixtures.projectFile(source: Fixtures.projectSource(canonicalByteCount: bytes.count)),
      audio: bytes)
    let snapshot = ProjectDocument.Content(
      file: Fixtures.projectFile(
        source: Fixtures.projectSource(canonicalByteCount: bytes.count + 1)),
      plan: Fixtures.editPlan(), audio: .packageChild(sessionCopy: nil))

    #expect(throws: ProjectPackageError.audioMismatch) {
      try ProjectDocument.makeFileWrapper(snapshot: snapshot, existingFile: existing)
    }
  }

  @Test func saveWithoutAnExistingFileFallsBackToTheSessionCopy() throws {
    // Save As / Duplicate: the write configuration carries no existing file, so the audio comes
    // from the clone hydration made for the editor.
    let bytes = Data("cloned-audio".utf8)
    let sessionCopy = try tempAudioFile(bytes)
    let snapshot = ProjectDocument.Content(
      file: Fixtures.projectFile(source: Fixtures.projectSource(canonicalByteCount: bytes.count)),
      plan: Fixtures.editPlan(), audio: .packageChild(sessionCopy: sessionCopy),
      recoveryArchive: Data("portable recovery".utf8))

    let written = try ProjectDocument.makeFileWrapper(snapshot: snapshot, existingFile: nil)

    expectNoDifference(try writtenAudio(of: written), bytes)
    expectNoDifference(try ProjectPackage.decode(written).recoveryArchive, snapshot.recoveryArchive)
  }

  @Test func saveWithNeitherExistingFileNorSessionCopyThrows() {
    let snapshot = ProjectDocument.Content(
      file: Fixtures.projectFile(), plan: Fixtures.editPlan(),
      audio: .packageChild(sessionCopy: nil))
    #expect(throws: ProjectDocumentError.missingPackageAudio) {
      try ProjectDocument.makeFileWrapper(snapshot: snapshot, existingFile: nil)
    }
  }

  @Test func saveWritesTheSessionFileBytesAndProjectJSON() throws {
    let bytes = Data("fresh-session-audio".utf8)
    let sessionFile = try tempAudioFile(bytes)
    let file = Fixtures.projectFile(
      source: Fixtures.projectSource(canonicalByteCount: bytes.count))
    let snapshot = ProjectDocument.Content(
      file: file, plan: Fixtures.editPlan(), audio: .sessionFile(sessionFile))

    let written = try ProjectDocument.makeFileWrapper(snapshot: snapshot, existingFile: nil)

    expectNoDifference(try writtenAudio(of: written), bytes)
    let decoded = try ProjectPackage.decode(written)
    expectNoDifference(decoded.file, file)
    try ProjectPackage.verifyAudio(decoded.audioWrapper, against: decoded.file.source)
  }

  @Test func saveRefusesASessionFileWhoseSizeDisagreesWithTheRecordedByteCount() throws {
    let sessionFile = try tempAudioFile(Data("twelve bytes".utf8))
    let snapshot = ProjectDocument.Content(
      file: Fixtures.projectFile(source: Fixtures.projectSource(canonicalByteCount: 999)),
      plan: Fixtures.editPlan(), audio: .sessionFile(sessionFile))
    #expect(throws: ProjectPackageError.audioMismatch) {
      try ProjectDocument.makeFileWrapper(snapshot: snapshot, existingFile: nil)
    }
  }

  @Test func saveRefusesAMissingSessionFile() {
    let missing = URL(fileURLWithPath: "/nonexistent/qie-missing.aiff")
    let snapshot = ProjectDocument.Content(
      file: Fixtures.projectFile(), plan: Fixtures.editPlan(), audio: .sessionFile(missing))
    #expect(throws: ProjectPackageError.audioMismatch) {
      try ProjectDocument.makeFileWrapper(snapshot: snapshot, existingFile: nil)
    }
  }

  // MARK: - Model seam

  @Test func firstCommitFillsAnEmptyDocument() throws {
    let document = ProjectDocument()
    let file = Fixtures.projectFile()
    let plan = Fixtures.editPlan()
    let audio = CanonicalAudioSource.sessionFile(Fixtures.canonicalAudioURL)

    document.sink.commit(file, plan, audio)

    expectNoDifference(
      document.content, ProjectDocument.Content(file: file, plan: plan, audio: audio))
  }

  @Test func contentCommitRewritesOnlyTheFile() throws {
    let document = try ProjectDocument(reading: try fixturePackage())
    let before = try #require(document.content)
    var edited = before.file
    edited.content.speakerCountOverride = 3

    document.sink.commit(edited, nil, nil)

    let after = try #require(document.content)
    expectNoDifference(after.file, edited)
    expectNoDifference(after.plan, before.plan)
    expectNoDifference(after.audio, before.audio)
  }

  @Test func hydrationCommitRecordsTheSessionCopy() throws {
    let document = try ProjectDocument(reading: try fixturePackage())
    let before = try #require(document.content)
    let clone = URL(fileURLWithPath: "/tmp/clone.aiff")

    document.sink.commit(before.file, nil, .packageChild(sessionCopy: clone))

    expectNoDifference(document.content?.audio, .packageChild(sessionCopy: clone))
  }

  @Test func registerChangeRegistersOneUndoActionOnTheWindowsUndoManager() {
    let document = ProjectDocument()
    let undoManager = UndoManager()
    document.undoManager = undoManager
    #expect(!undoManager.canUndo)

    document.sink.registerChange()

    #expect(undoManager.canUndo)
    expectNoDifference(undoManager.levelsOfUndo, 1)
  }

  @Test func registerChangeWithoutAnUndoManagerIsANoOp() {
    let document = ProjectDocument()
    document.sink.registerChange()
    #expect(document.undoManager == nil)
  }

  @Test func registerChangeMarksTheSaveStatusSaving() {
    let document = ProjectDocument()
    let status = SaveStatus()
    document.saveStatus = status
    #expect(!status.isSaving)

    document.sink.registerChange()

    #expect(status.isSaving)
    expectNoDifference(status.label, "Saving…")
  }
}

private final class BundleToken {}
