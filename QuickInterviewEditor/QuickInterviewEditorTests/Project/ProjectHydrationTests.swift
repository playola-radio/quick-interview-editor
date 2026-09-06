import CustomDump
import Dependencies
import Foundation
import Testing

@testable import PlayolaInterviewEditor

/// Opening a `.pie` package: the bundled `audio/canonical.aiff` is cloned into a session dir
/// (the one sanctioned by-URL read of the package, spec A5) and the editor is built against the
/// copy. Hydration never marks the document dirty.
@MainActor
struct ProjectHydrationTests {
  private let audioBytes = 4096

  /// Builds a minimal on-disk `.pie` package (only the audio child matters here) plus an
  /// isolated session-store base dir; both are removed on `cleanUp`.
  private struct Package {
    let url: URL
    let storeBase: URL
    var canonical: URL { url.appendingPathComponent("audio/canonical.aiff") }
    func cleanUp() {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: storeBase)
    }
  }

  private func makePackage() throws -> Package {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-hydration-\(UUID().uuidString)")
    let package = Package(
      url: root.appendingPathComponent("project.pie"),
      storeBase: root.appendingPathComponent("store"))
    try FileManager.default.createDirectory(
      at: package.url.appendingPathComponent("audio"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: package.storeBase, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: audioBytes).write(to: package.canonical)
    return package
  }

  private func decodedModel(
    package: Package?, audio: CanonicalAudioSource, sink: ProjectDocumentSink
  ) -> ProjectModel {
    ProjectModel(
      file: Fixtures.projectFile(
        source: Fixtures.projectSource(canonicalByteCount: audioBytes),
        content: Fixtures.editorDocumentState(speakerCountOverride: 4)),
      plan: Fixtures.editPlan(), audio: audio, packageURL: package?.url, sink: sink)
  }

  @Test func openClonesThePackageAudioIntoTheSessionStoreAndBuildsTheEditor() async throws {
    let package = try makePackage()
    defer { package.cleanUp() }
    let cloned = LockIsolated<[URL]>([])
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = decodedModel(
      package: package, audio: .packageChild(sessionCopy: nil), sink: sink)

    try await withDependencies {
      $0.canonicalAudioStore.clone = { source in
        cloned.withValue { $0.append(source) }
        return try CanonicalAudioStore.store(planAIFF: source, in: package.storeBase)
      }
    } operation: {
      await model.viewAppeared()

      expectNoDifference(model.phase, .loaded)
      expectNoDifference(cloned.value, [package.canonical])
      let editor = try #require(model.editor)
      // The editor reads the session copy, never the package itself.
      #expect(editor.canonicalAudioURL.path.hasPrefix(package.storeBase.path))
      #expect(FileManager.default.fileExists(atPath: editor.canonicalAudioURL.path))
      expectNoDifference(editor.speakerCountOverride, 4)

      // The clone is committed (so Save As can bundle it) without dirtying the document.
      expectNoDifference(record.commits.count, 1)
      let commit = try #require(record.commits.first)
      expectNoDifference(commit.audio, .packageChild(sessionCopy: editor.canonicalAudioURL))
      #expect(commit.plan == nil)
      expectNoDifference(commit.file.content.speakerCountOverride, 4)
      expectNoDifference(record.registerChangeCount, 0)
    }
  }

  @Test func cloneFailureLeavesTheProjectFailedWithTheReason() async {
    let package = try? makePackage()
    defer { package?.cleanUp() }
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = decodedModel(
      package: package, audio: .packageChild(sessionCopy: nil), sink: sink)

    await withDependencies {
      $0.canonicalAudioStore.clone = { _ in throw EngineClientError.engineFailed("disk full") }
    } operation: {
      await model.viewAppeared()
    }

    expectNoDifference(
      model.phase, .failed("Couldn't load the project's audio: Transcription failed: disk full"))
    #expect(model.showsError)
    #expect(model.editor == nil)
    expectNoDifference(record.commits, [])
  }

  @Test func retryAfterAFailedOpenHydratesAgain() async throws {
    let package = try makePackage()
    defer { package.cleanUp() }
    let attempts = LockIsolated(0)
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = decodedModel(
      package: package, audio: .packageChild(sessionCopy: nil), sink: sink)

    await withDependencies {
      $0.canonicalAudioStore.clone = { source in
        let attempt = attempts.withValue {
          $0 += 1
          return $0
        }
        guard attempt > 1 else { throw EngineClientError.engineFailed("flaky") }
        return try CanonicalAudioStore.store(planAIFF: source, in: package.storeBase)
      }
    } operation: {
      await model.viewAppeared()
      #expect(model.showsError)
      await model.retryTapped()
    }

    expectNoDifference(model.phase, .loaded)
    expectNoDifference(attempts.value, 2)
    #expect(model.editor != nil)
  }

  @Test func aPackageWithNoSavedLocationCannotHydrate() async {
    // Only an untitled window has no package URL; a decoded package without one is a
    // restore/duplicate edge the app can't serve until the audio has a session copy.
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = decodedModel(package: nil, audio: .packageChild(sessionCopy: nil), sink: sink)
    await model.viewAppeared()
    expectNoDifference(model.phase, .failed(model.missingPackageMessage))
    expectNoDifference(record.commits, [])
  }

  @Test func anExistingSessionCopyIsReusedWithoutCloning() async throws {
    let package = try makePackage()
    defer { package.cleanUp() }
    let copy = try CanonicalAudioStore.store(planAIFF: package.canonical, in: package.storeBase)
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = decodedModel(
      package: package, audio: .packageChild(sessionCopy: copy), sink: sink)

    // The test `clone` throws, so any clone attempt would fail the open.
    await model.viewAppeared()

    expectNoDifference(model.phase, .loaded)
    expectNoDifference(model.editor?.canonicalAudioURL, copy)
    expectNoDifference(record.commits, [])
  }

  @Test func viewAppearedIsANoOpOnceLoaded() async throws {
    let package = try makePackage()
    defer { package.cleanUp() }
    let copy = try CanonicalAudioStore.store(planAIFF: package.canonical, in: package.storeBase)
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = decodedModel(
      package: package, audio: .packageChild(sessionCopy: copy), sink: sink)
    await model.viewAppeared()
    let editor = try #require(model.editor)
    await model.viewAppeared()
    #expect(model.editor === editor)
  }
}
