import ConcurrencyExtras
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
  @Test func hydrationInstallsRecoveryBeforeLoadedAndRestoresMissingLocalStore() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let plan = Fixtures.editPlan()
    let file = Fixtures.projectFile()
    let fixture = try RecoveryFixture.matching(file: file, plan: plan)
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    _ = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    let capture = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: nil)
    var saved = file
    saved.content.suggestionRecoveryOwnerID = fixture.owner.id
    saved.content.unfinishedSuggestionRun = capture.checkpoint
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery = .store(
        SuggestionRecoveryStore(root: root.appending(component: "reopened"), uuid: { UUID() }))
    } operation: {
      ProjectModel(
        file: saved, plan: plan, audio: .sessionFile(root.appending(component: "audio.aiff")),
        sink: sink, recoveryArchive: capture.archive)
    }
    await model.viewAppeared()
    expectNoDifference(model.phase, .loaded)
    expectNoDifference(model.editor?.unfinishedSuggestionRun, capture.checkpoint)
    expectNoDifference(model.editor?.cutSuggestions.automaticSuggestionsEnabled, false)
    expectNoDifference(record.registerChangeCount, 0)
    #expect(record.recoveries.last?.archive != nil)
  }

  @Test func staleTranscriptHydratesWithExplicitDiscardRoute() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var file = Fixtures.projectFile()
    let fixture = try RecoveryFixture()
    file.content.suggestionRecoveryOwnerID = fixture.owner.id
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    _ = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery = .store(store)
    } operation: {
      ProjectModel(
        file: file, plan: Fixtures.editPlan(),
        audio: .sessionFile(root.appending(component: "audio.aiff")), sink: sink)
    }
    await model.viewAppeared()
    expectNoDifference(model.phase, .loaded)
    #expect(model.staleRecovery != nil)
    expectNoDifference(model.editor?.unfinishedSuggestionRun, nil)
    expectNoDifference(model.editor?.cutSuggestions.recoveryBlocksSuggestions, true)
    #expect(model.editor?.cutSuggestions.run.canDiscard == true)
    await model.editor?.cutSuggestions.run.discardSearchTapped()
    expectNoDifference(model.staleRecovery, nil)
    expectNoDifference(model.recoveryActionsBlocked, false)
    expectNoDifference(record.recoveries.last?.archive, nil)
    let removed = try await store.load(fixture.owner)
    expectNoDifference(removed, nil)
  }

  @Test func locationRecoveryPreservesAnEditWhileOwnershipIsSuspended() async throws {
    let gate = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    let shouldSuspend = LockIsolated(false)
    let file = Fixtures.projectFile()
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery.resolveOwner = { request in
        if shouldSuspend.value {
          await withCheckedContinuation { continuation in gate.setValue(continuation) }
        }
        return SuggestionRecoveryOwner(
          id: shouldSuspend.value ? Fixtures.uuid(91) : Fixtures.uuid(90),
          documentURL: request.documentURL,
          sourceFingerprint: request.sourceFingerprint, transcriptHash: request.transcriptHash)
      }
    } operation: {
      ProjectModel(
        file: file, plan: Fixtures.editPlan(),
        audio: .sessionFile(URL(fileURLWithPath: "/session/audio.aiff")), sink: sink)
    }
    await model.viewAppeared()
    let editor = try #require(model.editor)
    await withMainSerialExecutor {
      shouldSuspend.setValue(true)
      model.documentURLChanged(URL(fileURLWithPath: "/copy.pie"))
      let transition = Task { await model.documentLocationObserved() }
      while gate.value == nil { await Task.yield() }
      editor.transcript.transcriptDragBegan(
        atUTF16Offset: editor.transcript.document.wordRanges[0].range.location)
      editor.transcript.transcriptDragged(
        toUTF16Offset: editor.transcript.document.wordRanges[1].range.location)
      editor.addSliceTapped()
      editor.cutSuggestions.onSpeakerOverridesChanged?(3, ["SPEAKER_00": "Edited while copying"])
      gate.withValue { $0?.resume() }
      await transition.value
    }
    expectNoDifference(editor.slices.count, 2)
    expectNoDifference(record.commits.last?.file.content.slices.count, 2)
    expectNoDifference(editor.speakerCountOverride, 3)
    expectNoDifference(record.commits.last?.file.content.speakerCountOverride, 3)
    expectNoDifference(model.recoveryActionsBlocked, false)
    await editor.undoTapped()
    await editor.undoTapped()
    expectNoDifference(editor.suggestionRecoveryOwnerID, Fixtures.uuid(91))
    expectNoDifference(
      record.commits.last?.file.content.suggestionRecoveryOwnerID, Fixtures.uuid(91))
    expectNoDifference(editor.slices.count, 1)
  }

  @Test func preparedCaptureCannotLaunchAfterLocationChanges() async throws {
    let gate = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    let file = Fixtures.projectFile()
    let plan = Fixtures.editPlan()
    let fixture = try RecoveryFixture.matching(file: file, plan: plan)
    let capture = SuggestionRecoveryCapture(
      checkpoint: .init(
        pythonRevision: 0, controlRevision: 0,
        snapshot: fixture.snapshot, phase: .discovering, candidates: [], completedRequestKeys: [],
        failedRequestKeys: [], proposedStarts: .init()), archive: Data(),
      journalDirectory: URL(fileURLWithPath: "/journal/run"))
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery.prepare = { _, _ in URL(fileURLWithPath: "/journal/run") }
      $0.suggestionRecovery.capture = { _, _, _ in
        await withCheckedContinuation { continuation in gate.setValue(continuation) }
        return capture
      }
    } operation: {
      ProjectModel(
        file: file, plan: plan, audio: .sessionFile(URL(fileURLWithPath: "/audio.aiff")), sink: sink
      )
    }
    await withMainSerialExecutor {
      let task = Task { try await model.prepareSuggestionRecovery(fixture.preparation) }
      while gate.value == nil { await Task.yield() }
      model.documentURLChanged(URL(fileURLWithPath: "/copy.pie"))
      gate.withValue { $0?.resume() }
      await #expect(throws: CancellationError.self) { try await task.value }
    }
    expectNoDifference(record.recoveries.count, 0)
  }

  @Test func staleCopiedWindowCannotDiscardTheFirstWindowsRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var file = Fixtures.projectFile()
    let plan = Fixtures.editPlan()
    let fixture = try RecoveryFixture.matching(file: file, plan: plan)
    file.content.suggestionRecoveryOwnerID = fixture.owner.id
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    _ = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    var changedPlan = plan
    changedPlan.words[0].text += " changed"
    let first = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery = .store(store)
    } operation: {
      ProjectModel(
        file: file, plan: plan, audio: .sessionFile(root.appending(component: "audio.aiff")),
        sink: ProjectDocumentSink.recorder().sink)
    }
    let second = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery = .store(store)
    } operation: {
      ProjectModel(
        file: file, plan: changedPlan, audio: .sessionFile(root.appending(component: "audio.aiff")),
        sink: ProjectDocumentSink.recorder().sink)
    }
    await first.viewAppeared()
    await second.viewAppeared()
    guard case .staleIdentity(let staleOwner, _) = second.staleRecovery else {
      Issue.record("Expected a stale copied-window recovery")
      return
    }
    #expect(staleOwner.id != first.recoveryOwner?.id)
    try await second.discardSuggestionRecovery()
    let preserved = try await store.load(fixture.owner)
    expectNoDifference(preserved?.snapshot, fixture.snapshot)
  }

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

  @Test func aCloneWhoseSizeDriftedFromTheProjectFailsTheOpenAndIsRemoved() async throws {
    // The package passed the byte-count gate at open but was rewritten before hydration read
    // it again by path: the copy must not be trusted, and must not be left behind.
    let package = try makePackage()
    defer { package.cleanUp() }
    try Data(repeating: 0x41, count: audioBytes / 2).write(to: package.canonical)
    let cloneURL = LockIsolated<URL?>(nil)
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = decodedModel(
      package: package, audio: .packageChild(sessionCopy: nil), sink: sink)

    await withDependencies {
      $0.canonicalAudioStore.clone = { source in
        let url = try CanonicalAudioStore.store(planAIFF: source, in: package.storeBase)
        cloneURL.withValue { $0 = url }
        return url
      }
      $0.canonicalAudioStore.remove = { CanonicalAudioStore.remove($0, in: package.storeBase) }
    } operation: {
      await model.viewAppeared()
    }

    expectNoDifference(
      model.phase,
      .failed(
        "Couldn't load the project's audio: The project's bundled audio does not match the project."
      ))
    #expect(model.editor == nil)
    expectNoDifference(record.commits, [])
    let clone = try #require(cloneURL.value)
    #expect(!FileManager.default.fileExists(atPath: clone.path))
  }

  @Test func aCloneThatFinishesAfterTheWindowClosedIsRemoved() async throws {
    let package = try makePackage()
    defer { package.cleanUp() }
    let gate = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    let cloneURL = LockIsolated<URL?>(nil)
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = decodedModel(
      package: package, audio: .packageChild(sessionCopy: nil), sink: sink)

    await withMainSerialExecutor {
      let hydration = withDependencies {
        $0.canonicalAudioStore.clone = { source in
          // A real copy ignores cancellation and finishes anyway.
          await withCheckedContinuation { continuation in
            gate.withValue { $0 = continuation }
          }
          let url = try CanonicalAudioStore.store(planAIFF: source, in: package.storeBase)
          cloneURL.withValue { $0 = url }
          return url
        }
        $0.canonicalAudioStore.remove = { CanonicalAudioStore.remove($0, in: package.storeBase) }
      } operation: {
        Task { await model.viewAppeared() }
      }
      while gate.value == nil { await Task.yield() }
      hydration.cancel()
      gate.withValue { $0?.resume() }
      await hydration.value
    }

    #expect(model.editor == nil)
    expectNoDifference(record.commits, [])
    let clone = try #require(cloneURL.value)
    #expect(!FileManager.default.fileExists(atPath: clone.path))
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

extension ProjectHydrationTests {
  @Test func appliedRunIsNotOfferedAgainAndArchiveSurvivesUntilDiskConfirmation() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appending(component: "project.pie")
    var file = Fixtures.projectFile()
    let plan = Fixtures.editPlan()
    var fixture = try RecoveryFixture.matching(file: file, plan: plan)
    fixture.owner.documentURL = package
    let store = SuggestionRecoveryStore(
      root: root.appending(component: "recovery"), uuid: { UUID() })
    _ = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    let capture = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: nil)
    file.content.suggestionRecoveryOwnerID = fixture.owner.id
    file.content.lastAppliedSuggestionRunID = fixture.snapshot.runID
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery = .store(store)
    } operation: {
      ProjectModel(
        file: file, plan: plan, audio: .sessionFile(root.appending(component: "audio.aiff")),
        packageURL: package, sink: sink, recoveryArchive: capture.archive)
    }
    await model.viewAppeared()
    expectNoDifference(model.editor?.unfinishedSuggestionRun, nil)
    #expect(record.recoveries.last?.archive != nil)
    let beforeSave = try await store.load(fixture.owner)
    #expect(beforeSave != nil)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try ProjectPackage.projectEncoder().encode(file).write(
      to: package.appending(component: "project.json"))
    await model.savedProjectObserved()
    expectNoDifference(record.recoveries.last?.archive, nil)
    let afterSave = try await store.load(fixture.owner)
    expectNoDifference(afterSave, nil)
  }
}

extension ProjectHydrationTests {
  @Test(arguments: [false, true])
  func appliedArchiveRemainsCoherentWhenSuccessorIsDiscardedOrPredecessorIsConfirmed(
    confirmPredecessor: Bool
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appending(component: "project.pie")
    var file = Fixtures.projectFile()
    let plan = Fixtures.editPlan()
    var first = try RecoveryFixture.matching(file: file, plan: plan)
    first.owner.documentURL = package
    let store = SuggestionRecoveryStore(root: root.appending(component: "store"), uuid: { UUID() })
    let firstDirectory = try await store.prepare(first.owner, preparation: first.preparation)
    try first.writePython(RecoveryFixture.python(matching: first), directory: firstDirectory)
    let firstCapture = try await store.capture(
      first.owner, runID: first.snapshot.runID, minimumPythonRevision: 1)
    file.content.suggestionRecoveryOwnerID = first.owner.id
    file.content.lastAppliedSuggestionRunID = first.snapshot.runID
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery = .store(store)
    } operation: {
      ProjectModel(
        file: file, plan: plan, audio: .sessionFile(root.appending(component: "audio.aiff")),
        packageURL: package,
        sink: sink, recoveryArchive: firstCapture.archive)
    }
    await model.viewAppeared()
    var second = first.preparation
    second.snapshot.runID = Fixtures.uuid(88)
    var request = try #require(
      JSONSerialization.jsonObject(with: second.originalRequest) as? [String: Any])
    request["run_id"] = second.snapshot.runID.uuidString
    second.originalRequest = try JSONSerialization.data(
      withJSONObject: request, options: [.sortedKeys, .withoutEscapingSlashes])
    _ = try await model.prepareSuggestionRecovery(second)
    if confirmPredecessor {
      file.content.unfinishedSuggestionRun = model.editor?.unfinishedSuggestionRun
      try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
      try ProjectPackage.projectEncoder().encode(file).write(
        to: package.appending(component: "project.json"))
      await model.savedProjectObserved()
    } else {
      try await model.discardSuggestionRecovery()
    }
    let published = try #require(record.recoveries.last)
    let archive = try SuggestionRecoveryArchive.decode(#require(published.archive))
    let expectedRunID = confirmPredecessor ? second.snapshot.runID : first.snapshot.runID
    expectNoDifference(archive.manifest.snapshot.runID, expectedRunID)
    expectNoDifference(
      published.file.content.unfinishedSuggestionRun?.snapshot.runID,
      confirmPredecessor ? second.snapshot.runID : nil)
    expectNoDifference(archive.retainedAppliedRuns, [])
  }
}

extension ProjectHydrationTests {
  @Test(arguments: [false, true])
  func appliedRunRejectsLateCaptureAndPreservesArchive(suspendedSaveRefresh: Bool) async throws {
    let gate = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    var file = Fixtures.projectFile()
    let plan = Fixtures.editPlan()
    let fixture = try RecoveryFixture.matching(file: file, plan: plan)
    file.content.suggestionRecoveryOwnerID = fixture.owner.id
    file.content.lastAppliedSuggestionRunID = Fixtures.uuid(87)
    let capture = SuggestionRecoveryCapture(
      checkpoint: .init(
        pythonRevision: 1, controlRevision: 0, snapshot: fixture.snapshot, phase: .ready,
        candidates: [], completedRequestKeys: [], failedRequestKeys: [], proposedStarts: .init()),
      archive: Data("accepted ready archive".utf8),
      journalDirectory: URL(fileURLWithPath: "/journal/run"))
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery.confirmSaved = { _, _ in }
      $0.suggestionRecovery.capture = { _, _, _ in
        await withCheckedContinuation { continuation in gate.setValue(continuation) }
        return capture
      }
    } operation: {
      ProjectModel(
        file: file, plan: plan, audio: .sessionFile(URL(fileURLWithPath: "/audio.aiff")),
        sink: sink)
    }
    await model.viewAppeared()
    try model.acceptSuggestionRecovery(capture, owner: fixture.owner)
    let editor = try #require(model.editor)
    let recoveryCount = record.recoveries.count
    await withMainSerialExecutor {
      let save = suspendedSaveRefresh ? Task { await model.savedProjectObserved() } : nil
      while suspendedSaveRefresh && gate.value == nil { await Task.yield() }
      editor.mutateDocument(recordUndo: false) {
        $0.unfinishedSuggestionRun = nil
        $0.lastAppliedSuggestionRunID = fixture.snapshot.runID
      }
      if suspendedSaveRefresh {
        gate.withValue { $0?.resume() }
        await save?.value
      } else {
        #expect(throws: CancellationError.self) {
          try model.acceptSuggestionRecovery(capture, owner: fixture.owner)
        }
      }
    }
    expectNoDifference(editor.unfinishedSuggestionRun, nil)
    expectNoDifference(editor.lastAppliedSuggestionRunID, fixture.snapshot.runID)
    expectNoDifference(record.recoveries.count, recoveryCount)
    expectNoDifference(record.recoveries.last?.archive, capture.archive)
    expectNoDifference(record.commits.last?.file.content.unfinishedSuggestionRun, nil)
  }
  @Test(arguments: [1, 2])
  func matchingOrphansRequireExplicitChoiceAndCancelPreservesDocument(count: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = Fixtures.projectFile()
    let plan = Fixtures.editPlan()
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    for index in 0..<count {
      var fixture = try RecoveryFixture.matching(file: file, plan: plan)
      fixture.owner.id = Fixtures.uuid(700 + index)
      fixture.preparation.control.isPaused = true
      _ = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    }
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery = .store(store)
    } operation: {
      ProjectModel(
        file: file, plan: plan, audio: .sessionFile(root.appending(component: "audio.aiff")),
        sink: sink)
    }
    await model.viewAppeared()
    expectNoDifference(model.recoverableSuggestionOwners.count, count)
    expectNoDifference(model.editor?.cutSuggestions.orphanRows.count, count)
    expectNoDifference(model.editor?.unfinishedSuggestionRun, nil)
    expectNoDifference(model.recoveryOwner, nil)
    let before = model.editor?.documentState
    let changes = record.registerChangeCount
    model.cancelOrphanRecoveryTapped()
    expectNoDifference(model.editor?.documentState, before)
    expectNoDifference(model.recoverableSuggestionOwners, [])
    expectNoDifference(record.registerChangeCount, changes)
  }

  @Test(arguments: ["duplicate", "claim", "capture"], [false, true])
  func cancellingPendingOrphanSelectionCannotPublishOrClobberNewSelection(
    suspendedOperation: String, selectsAgain: Bool
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let pending = try await PendingOrphanSelection.make(root: root, operation: suspendedOperation)
    defer { pending.gate.release.continuation.finish() }
    let model = pending.model
    let record = pending.record
    await model.viewAppeared()
    let editor = try #require(model.editor)
    let before = editor.documentState
    let changes = record.registerChangeCount
    let recoveries = record.recoveries.count
    let selection = Task { await model.selectOrphanRecoveryTapped(pending.owner) }
    await pending.gate.waitUntilSuspended()
    model.cancelOrphanRecoveryTapped()
    expectNoDifference(model.recoveryActionsBlocked, false)
    expectNoDifference(editor.cutSuggestions.recoveryBlocksSuggestions, false)
    expectNoDifference(editor.documentState, before)
    expectNoDifference(model.recoveryOwner, nil)
    if selectsAgain {
      await model.documentLocationObserved()
      await model.selectOrphanRecoveryTapped(pending.owner)
      #expect(model.recoveryOwner != nil)
      #expect(editor.cutSuggestions.run.canResume)
    }
    let expected = editor.documentState
    let expectedOwner = model.recoveryOwner
    let expectedPhase = editor.cutSuggestions.run.phase
    let expectedChanges = record.registerChangeCount
    let expectedRecoveries = record.recoveries.count
    pending.gate.release.continuation.yield(())
    await selection.value
    expectNoDifference(editor.documentState, expected)
    expectNoDifference(model.recoveryOwner, expectedOwner)
    expectNoDifference(editor.cutSuggestions.run.phase, expectedPhase)
    expectNoDifference(model.recoveryActionsBlocked, false)
    expectNoDifference(record.registerChangeCount, expectedChanges)
    expectNoDifference(record.recoveries.count, expectedRecoveries)
    expectNoDifference(pending.calls.value, 0)
    if !selectsAgain {
      expectNoDifference(editor.documentState, before)
      expectNoDifference(record.registerChangeCount, changes)
      expectNoDifference(record.recoveries.count, recoveries)
    }
    try await pending.expectSourceUnchanged()
  }

  @Test(arguments: [false, true])
  func orphanSelectionWaitsForExplicitResumeBeforeRequestingOrApplying(isReady: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = Fixtures.projectFile()
    let plan = Fixtures.editPlan()
    var fixture = try RecoveryFixture.matching(file: file, plan: plan)
    fixture.preparation.control.originalBatchFingerprint = try suggestionBatchFingerprint(
      file.content)
    fixture.preparation.control.isPaused = !isReady
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    let directory = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    if isReady {
      try fixture.writePython(RecoveryFixture.python(matching: fixture), directory: directory)
    }
    let original = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: nil)
    let calls = LockIsolated(0)
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery = .store(store)
      $0.keychain = .inMemory("ephemeral-test-key")
      $0.environment = .constant([:])
      $0.cutSuggest.suggestCuts = { _, _ in
        calls.withValue { $0 += 1 }
        return AsyncThrowingStream { $0.finish() }
      }
    } operation: {
      ProjectModel(
        file: file, plan: plan, audio: .sessionFile(root.appending(component: "audio.aiff")),
        sink: sink)
    }
    await model.viewAppeared()
    let editor = try #require(model.editor)
    let before = editor.documentState
    await editor.cutSuggestions.orphanSelected(fixture.owner.id)
    let isolated = try #require(model.recoveryOwner)
    #expect(isolated.id != fixture.owner.id)
    var expected = before
    expected.suggestionRecoveryOwnerID = isolated.id
    expected.unfinishedSuggestionRun = original.checkpoint
    expectNoDifference(editor.documentState, expected)
    expectNoDifference(calls.value, 0)
    #expect(editor.cutSuggestions.run.canResume)
    #expect(editor.cutSuggestions.run.canDiscard)
    expectNoDifference(record.recoveries.last?.file.content, expected)
    #expect(record.recoveries.last?.archive != nil)
    expectNoDifference(model.recoverableSuggestionOwners, [])
  }

  @Test func orphanChoiceCopiesAStillOpenOriginalOwnerBeforeResume() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = Fixtures.projectFile()
    let plan = Fixtures.editPlan()
    var fixture = try RecoveryFixture.matching(file: file, plan: plan)
    fixture.preparation.control.isPaused = true
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    _ = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    _ = try await store.claimOwner(fixture.owner, instanceID: Fixtures.uuid(800))
    let original = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: nil)
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery = .store(store)
      $0.keychain = .inMemory(nil)
      $0.environment = .constant([:])
    } operation: {
      ProjectModel(
        file: file, plan: plan, audio: .sessionFile(root.appending(component: "audio.aiff")),
        sink: sink)
    }
    await model.viewAppeared()
    expectNoDifference(model.recoverableSuggestionOwners.count, 1)
    await model.editor?.cutSuggestions.orphanSelected(fixture.owner.id)
    let isolated = try #require(model.recoveryOwner)
    #expect(isolated.id != fixture.owner.id)
    expectNoDifference(
      model.editor?.unfinishedSuggestionRun?.snapshot.runID, fixture.snapshot.runID)
    expectNoDifference(model.recoverableSuggestionOwners, [])
    let retained = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: nil)
    expectNoDifference(retained.checkpoint, original.checkpoint)
    expectNoDifference(
      try SuggestionRecoveryArchive.decode(retained.archive),
      try SuggestionRecoveryArchive.decode(original.archive))
    #expect(model.editor?.cutSuggestions.run.canResume == true)
  }

  @Test func locationChangePausesActiveSearchBeforeForkingItsOwner() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let oldURL = root.appending(component: "Original.pie")
    let newURL = root.appending(component: "Copy.pie")
    try FileManager.default.createDirectory(at: oldURL, withIntermediateDirectories: true)
    let store = SuggestionRecoveryStore(
      root: root.appending(component: "recovery"), uuid: { UUID() })
    let stream = SuggestionRunFixture()
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery = .store(store)
      $0.suggestionConfiguration = .inMemory()
      $0.keychain = .inMemory("ephemeral-key")
      $0.cutSuggest = stream.client
    } operation: {
      ProjectModel(
        file: Fixtures.projectFile(content: .init()), plan: Fixtures.editPlan(),
        audio: .sessionFile(root.appending(component: "audio.aiff")), packageURL: oldURL,
        sink: ProjectDocumentSink.recorder().sink)
    }
    await model.viewAppeared()
    let editor = try #require(model.editor)
    let task = Task { await editor.cutSuggestions.suggestCutsTapped() }
    await stream.waitForRequests()
    let originalOwner = try #require(model.recoveryOwner)
    model.documentURLChanged(newURL)
    expectNoDifference(editor.cutSuggestions.run.activeAttemptID, nil)
    stream.state.value.continuations[0].yield(.completed([]))
    await model.documentLocationObserved()
    await task.value
    let copiedOwner = try #require(model.recoveryOwner)
    #expect(copiedOwner.id != originalOwner.id)
    expectNoDifference(copiedOwner.documentURL, newURL)
    let originalCheckpoint = try await store.load(originalOwner)
    let copiedCheckpoint = try await store.load(copiedOwner)
    expectNoDifference(originalCheckpoint?.phase, .paused)
    expectNoDifference(copiedCheckpoint?.phase, .paused)
    expectNoDifference(editor.unfinishedSuggestionRun?.phase, .paused)
    expectNoDifference(editor.lastAppliedSuggestionRunID, nil)
    #expect(editor.cutSuggestions.run.canResume)
  }

}

private struct OrphanSelectionGate: Sendable {
  let operation: String
  let entered = AsyncStream.makeStream(of: Void.self)
  let release = AsyncStream.makeStream(of: Void.self)
  let didSuspend = LockIsolated(false)

  func suspend(_ operation: String) async {
    guard operation == self.operation,
      didSuspend.withValue({ value in
        if value { return false }
        value = true
        return true
      })
    else { return }
    entered.continuation.yield(())
    var iterator = release.stream.makeAsyncIterator()
    _ = await iterator.next()
  }

  func waitUntilSuspended() async {
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
  }

  func client(store: SuggestionRecoveryStore) -> SuggestionRecoveryClient {
    var client = SuggestionRecoveryClient.store(store)
    client.duplicate = { source, target in
      try await store.duplicate(source, newOwner: target)
      await suspend("duplicate")
    }
    client.claimOwner = { owner, instance in
      let claimed = try await store.claimOwner(owner, instanceID: instance)
      await suspend("claim")
      return claimed
    }
    client.capture = { owner, runID, revision in
      let capture = try await store.capture(owner, runID: runID, minimumPythonRevision: revision)
      await suspend("capture")
      return capture
    }
    return client
  }
}

@MainActor
private struct PendingOrphanSelection {
  let model: ProjectModel
  let record: ProjectDocumentSinkRecorder
  let store: SuggestionRecoveryStore
  let owner: SuggestionRecoveryOwner
  let original: SuggestionRecoveryCapture
  let gate: OrphanSelectionGate
  let calls: LockIsolated<Int>

  static func make(root: URL, operation: String) async throws -> Self {
    let file = Fixtures.projectFile()
    let plan = Fixtures.editPlan()
    let fixture = try RecoveryFixture.matching(file: file, plan: plan)
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    let directory = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    try fixture.writePython(RecoveryFixture.python(matching: fixture), directory: directory)
    let original = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: nil)
    let gate = OrphanSelectionGate(operation: operation)
    let calls = LockIsolated(0)
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.suggestionRecovery = gate.client(store: store)
      $0.keychain = .inMemory("ephemeral-test-key")
      $0.environment = .constant([:])
      $0.cutSuggest.suggestCuts = { _, _ in
        calls.withValue { $0 += 1 }
        return AsyncThrowingStream { $0.finish() }
      }
    } operation: {
      ProjectModel(
        file: file, plan: plan, audio: .sessionFile(root.appending(component: "audio.aiff")),
        sink: sink)
    }
    return Self(
      model: model, record: record, store: store, owner: fixture.owner, original: original,
      gate: gate, calls: calls)
  }

  func expectSourceUnchanged() async throws {
    let retained = try await store.capture(
      owner, runID: original.checkpoint.snapshot.runID, minimumPythonRevision: nil)
    expectNoDifference(retained.checkpoint, original.checkpoint)
    expectNoDifference(
      try SuggestionRecoveryArchive.decode(retained.archive),
      try SuggestionRecoveryArchive.decode(original.archive))
  }
}
