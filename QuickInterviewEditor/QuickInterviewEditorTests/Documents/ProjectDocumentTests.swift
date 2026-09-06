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

  // MARK: - Helpers

  private func fixturePackage() throws -> FileWrapper {
    let url = try #require(
      Bundle(for: BundleToken.self).url(forResource: "project-v1", withExtension: "pie"))
    return try FileWrapper(url: url, options: [.immediate])
  }

  private func packageTree(file: ProjectFile, audio: Data) throws -> FileWrapper {
    try ProjectPackage.encode(
      file: file, plan: Fixtures.editPlan(), audio: FileWrapper(regularFileWithContents: audio))
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
    expectNoDifference(snapshot, document.content)
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

  @Test func saveWithoutAnExistingFileFallsBackToTheSessionCopy() throws {
    // Save As / Duplicate: the write configuration carries no existing file, so the audio comes
    // from the clone hydration made for the editor.
    let bytes = Data("cloned-audio".utf8)
    let sessionCopy = try tempAudioFile(bytes)
    let snapshot = ProjectDocument.Content(
      file: Fixtures.projectFile(source: Fixtures.projectSource(canonicalByteCount: bytes.count)),
      plan: Fixtures.editPlan(), audio: .packageChild(sessionCopy: sessionCopy))

    let written = try ProjectDocument.makeFileWrapper(snapshot: snapshot, existingFile: nil)

    expectNoDifference(try writtenAudio(of: written), bytes)
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
}

private final class BundleToken {}
