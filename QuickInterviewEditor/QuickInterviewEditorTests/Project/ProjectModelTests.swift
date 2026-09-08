import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
// `FileStorage.inMemory(fileSystem:)` is `@_spi(Internals)`, mirroring the sidecar-migration
// seeding tests on the tab it replaces.
@_spi(Internals) import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct ProjectModelTests {

  // `/clip.m4a` is unreadable, so `SourceFingerprint` falls back to the standardized path —
  // the same key the legacy sidecar was written under.
  private let fingerprint = "path:/clip.m4a"
  private let importedAt = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func untouchedV1DoesNotAutoSuggestOrDirtyAndNextEditUpgrades() async throws {
    var file = Fixtures.projectFile(content: EditorDocumentState())
    file.schemaVersion = 1
    let (sink, record) = ProjectDocumentSink.recorder()
    let requests = LockIsolated(0)
    try await withDependencies {
      $0.keychain = .inMemory("fixture-key")
      $0.cutSuggest = CutSuggestClient { _, _ in
        requests.withValue { $0 += 1 }
        return AsyncThrowingStream {
          $0.yield(.completed([]))
          $0.finish()
        }
      }
    } operation: {
      let model = ProjectModel(
        file: file, plan: Fixtures.editPlan(),
        audio: .packageChild(sessionCopy: Fixtures.canonicalAudioURL),
        sink: sink)
      await model.viewAppeared()
      let editor = try #require(model.editor)
      await editor.cutSuggestions.autoSuggestCutsIfNeeded()
      expectNoDifference(requests.value, 0)
      expectNoDifference(editor.documentState, file.content)
      expectNoDifference(record.registerChangeCount, 0)
      expectNoDifference(record.commits.count, 0)

      editor.mutateDocument { $0.speakerCountOverride = 3 }
      expectNoDifference(record.commits.last?.file.schemaVersion, 2)
      expectNoDifference(record.registerChangeCount, 1)
      expectNoDifference(editor.documentState.suggestionRecoveryOwnerID, nil)
    }
  }

  @Test func explicitSuggestUpgradesAnOpenedV1() async throws {
    var file = Fixtures.projectFile(content: EditorDocumentState())
    file.schemaVersion = 1
    let (sink, record) = ProjectDocumentSink.recorder()
    let fixture = SuggestionRunFixture()
    try await withDependencies {
      fixture.install(&$0)
    } operation: {
      let model = ProjectModel(
        file: file, plan: Fixtures.editPlan(),
        audio: .packageChild(sessionCopy: Fixtures.canonicalAudioURL), sink: sink)
      await model.viewAppeared()
      let editor = try #require(model.editor)
      let task = Task { await editor.cutSuggestions.suggestCutsTapped() }
      await fixture.waitForRequests()
      expectNoDifference(record.commits.last?.file.schemaVersion, 2)
      #expect(editor.unfinishedSuggestionRun != nil)
      fixture.finish()
      await task.value
      expectNoDifference(editor.cutSuggestions.run.phase, .idle)
      #expect(editor.lastAppliedSuggestionRunID != nil)
      expectNoDifference(editor.unfinishedSuggestionRun, nil)
    }
  }

  @Test func cancellingReplacementLeavesOpenedV1UntouchedAndDoesNotPrepareRecovery() async throws {
    var file = Fixtures.projectFile()
    file.schemaVersion = 1
    let (sink, record) = ProjectDocumentSink.recorder()
    let fixture = SuggestionRunFixture()
    try await withDependencies {
      fixture.install(&$0)
    } operation: {
      let model = ProjectModel(
        file: file, plan: Fixtures.editPlan(),
        audio: .packageChild(sessionCopy: Fixtures.canonicalAudioURL), sink: sink)
      await model.viewAppeared()
      let editor = try #require(model.editor)
      let before = editor.documentState
      await editor.cutSuggestions.suggestCutsTapped()
      expectNoDifference(editor.cutSuggestions.run.phase, .confirmingReplacement)
      editor.cutSuggestions.run.cancelReplacementTapped()
      expectNoDifference(editor.documentState, before)
      expectNoDifference(record.registerChangeCount, 0)
      expectNoDifference(record.commits.count, 0)
      expectNoDifference(fixture.state.value.requests.count, 0)
      expectNoDifference(fixture.state.value.prepared.count, 0)
      expectNoDifference(editor.cutSuggestions.automaticSuggestionsEnabled, false)
    }
  }

  @Test func freshModelIsEmpty() {
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    expectNoDifference(model.phase, .empty)
    #expect(model.showsEmptyState)
    #expect(model.acceptsImport)
    #expect(!model.canReimport)
    #expect(model.editor == nil)
    expectNoDifference(record.commits, [])
    expectNoDifference(record.registerChangeCount, 0)
  }

  @Test func saveStatusIsHiddenUntilLoadedAndForwardsTheIndicator() {
    let (sink, _) = ProjectDocumentSink.recorder()
    let status = SaveStatus()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink, saveStatus: status)
    #expect(!model.showsSaveStatus)
    expectNoDifference(model.saveStatusLabel, "Saved")

    status.markEdited(generation: 1)
    #expect(model.isSaving)
    expectNoDifference(model.saveStatusLabel, "Saving…")
  }

  @Test func importReachesLoadedAndCommitsSessionFileOnce() async throws {
    let plan = Fixtures.editPlan()
    let canonical = try temporaryCanonicalAudio(bytes: 1234)
    defer { try? FileManager.default.removeItem(at: canonical) }
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([
          .progress(.init(phase: "transcribing", message: "Transcribing")),
          .completed(Fixtures.transcriptionResult(plan, canonicalAudioURL: canonical)),
        ])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }

    expectNoDifference(model.phase, .loaded)
    #expect(model.showsEditor)
    #expect(model.canReimport)
    let editor = try #require(model.editor)
    expectNoDifference(editor.canonicalAudioURL, canonical)
    expectNoDifference(editor.transcript.document.wordRanges.count, 122)
    // Exactly one commit — the transcription completion — and it dirties the document (spec A7).
    expectNoDifference(record.registerChangeCount, 1)
    expectNoDifference(record.commits.count, 1)
    let commit = try #require(record.commits.first)
    expectNoDifference(commit.plan, plan)
    expectNoDifference(commit.audio, .sessionFile(canonical))
    expectNoDifference(commit.file.content, editor.documentState)
    expectNoDifference(commit.file.source.originalFileName, "clip.m4a")
    expectNoDifference(commit.file.source.originalFingerprint, fingerprint)
    expectNoDifference(commit.file.source.importedAt, importedAt)
    expectNoDifference(commit.file.engine.engineFingerprint, "engine:test")
    expectNoDifference(commit.file.source.sampleRate, plan.source.sampleRate)
    expectNoDifference(commit.file.source.durationSamples, plan.source.durationSamples)
  }

  @Test func suggestedDocumentNameIsNilBeforeImport() {
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    expectNoDifference(model.suggestedDocumentName, nil)
  }

  @Test func suggestedDocumentNameStripsAudioExtensionAfterImport() async throws {
    let plan = Fixtures.editPlan()
    let canonical = try temporaryCanonicalAudio(bytes: 1234)
    defer { try? FileManager.default.removeItem(at: canonical) }
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(plan, canonicalAudioURL: canonical))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/my interview.m4a"))
    }

    expectNoDifference(model.phase, .loaded)
    expectNoDifference(model.suggestedDocumentName, "my interview")
  }

  @Test func importRecordsTheCanonicalAudioByteCountSoASavedPackageVerifies() async throws {
    let canonical = try temporaryCanonicalAudio(bytes: 1234)
    defer { try? FileManager.default.removeItem(at: canonical) }
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(canonicalAudioURL: canonical))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }

    let commit = try #require(record.commits.first)
    expectNoDifference(commit.file.source.canonicalByteCount, 1234)
    // Import records a content fingerprint of the canonical AIFF bytes (spec A8, PR 5).
    expectNoDifference(
      commit.file.source.canonicalFingerprint, SourceFingerprint.compute(for: canonical))
    // The recorded count is what a later open checks the bundled AIFF against.
    try ProjectPackage.verifyAudio(
      FileWrapper(url: canonical, options: []), against: commit.file.source)
  }

  @Test func importFailsWhenTheCanonicalAudioIsMissing() async {
    let missing = URL(fileURLWithPath: "/tmp/qie-project-missing-\(UUID().uuidString).aiff")
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(canonicalAudioURL: missing))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }

    expectNoDifference(model.phase, .failed(model.missingCanonicalAudioMessage))
    #expect(model.editor == nil)
    expectNoDifference(record.commits, [])
  }

  @Test func importedAtIsFlooredToWholeSecondsForRoundTrip() async throws {
    // The `.pie` package stores whole seconds; a fractional clock reading must be
    // floored so the committed file equals what reopening the saved package yields.
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000.75))
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }
    let commit = try #require(record.commits.first)
    expectNoDifference(commit.file.source.importedAt, Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test func progressUpdatesTranscribingFraction() async {
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.transcription.transcribe = { _, _, _ in
        engineEvents(
          [.progress(.init(phase: "aligning", message: "Aligning", fraction: 0.42))],
          throwing: CancellationError())
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }
    // The cancelled stream leaves the last observed progress visible.
    expectNoDifference(model.progressFraction, 0.42)
    #expect(model.showsProgress)
  }

  @Test func failureSetsFailedPhaseWithMessage() async {
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([], throwing: EngineClientError.engineFailed("no models"))
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }
    expectNoDifference(model.phase, .failed("Transcription failed: no models"))
    expectNoDifference(model.errorMessage, "Transcription failed: no models")
    #expect(model.showsError)
    #expect(model.acceptsImport)
    #expect(model.editor == nil)
    expectNoDifference(record.commits, [])
  }

  @Test func importPassesUseCachePolicy() async {
    let captured = LockIsolated<CachePolicy?>(nil)
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.transcription.transcribe = { _, _, policy in
        captured.setValue(policy)
        return engineEvents([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }
    expectNoDifference(captured.value, .useCache)
  }

  @Test func reimportIgnoringCacheReusesTheSessionSourceWithForceFresh() async throws {
    let captured = LockIsolated<[(URL, CachePolicy)]>([])
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.transcription.transcribe = { url, _, policy in
        captured.withValue { $0.append((url, policy)) }
        return engineEvents([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      let firstEditor = try #require(model.editor)
      await model.reimportIgnoringCacheTapped()
      #expect(model.editor !== firstEditor)
    }
    expectNoDifference(captured.value.map(\.1), [.useCache, .forceFresh])
    expectNoDifference(captured.value.map(\.0.path), ["/clip.m4a", "/clip.m4a"])
    expectNoDifference(model.phase, .loaded)
    expectNoDifference(record.commits.count, 2)
  }

  @Test func canReimportOnceLoadedForBothImportedAndOpenedProjects() async {
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    #expect(!model.canReimport)
    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }
    #expect(model.canReimport)

    // A project opened from disk can re-transcribe its bundled canonical AIFF once hydrated
    // (spec A8, PR 5) — but not before it has a session copy to read.
    let opened = ProjectModel(
      file: Fixtures.projectFile(), plan: Fixtures.editPlan(),
      audio: .sessionFile(Fixtures.canonicalAudioURL), sink: sink)
    #expect(!opened.canReimport)
    await opened.viewAppeared()
    #expect(opened.isLoaded)
    #expect(opened.canReimport)
  }

  @Test func oneDocumentMutationCommitsOnceAndRegistersOneChange() async throws {
    let plan = Fixtures.editPlan()
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(plan))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      let editor = try #require(model.editor)

      editor.mutateDocument { $0.speakerCountOverride = 3 }

      // One from the transcription commit, one from the edit.
      expectNoDifference(record.registerChangeCount, 2)
      expectNoDifference(record.commits.count, 2)
      let latest = try #require(record.commits.last)
      // A content edit rewrites only the file — plan/audio stay unchanged.
      #expect(latest.plan == nil)
      #expect(latest.audio == nil)
      expectNoDifference(latest.file.content.speakerCountOverride, 3)
      expectNoDifference(latest.file.content, editor.documentState)
    }
  }

  @Test func importSeedsEditorFromLegacySidecar() async throws {
    let seeded = ProjectState(
      cutSuggestions: [Fixtures.cutSuggestion(id: Fixtures.uuid(1))],
      speakerCountOverride: 2,
      speakerDisplayNames: ["0": "Host"],
      timelineRemovals: [
        TimelineRemoval(
          id: Fixtures.uuid(7), removedRange: 1000..<2000,
          crossfade: Crossfade(lengthSamples: 480, curve: .equalPower))
      ])
    let seededData = try JSONEncoder().encode(seeded)
    let fileSystem = LockIsolated<[URL: Data]>([
      ProjectState.sidecarURL(fingerprint: fingerprint): seededData
    ])
    let plan = Fixtures.editPlan()
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(plan))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }

    let editor = try #require(model.editor)
    expectNoDifference(editor.documentCutSuggestions, seeded.cutSuggestions)
    expectNoDifference(editor.speakerCountOverride, 2)
    expectNoDifference(editor.speakerDisplayNames, ["0": "Host"])
    expectNoDifference(editor.timelineRemovals, seeded.timelineRemovals)
  }

  @Test func documentMutationsNoLongerWriteTheLegacySidecar() async throws {
    // The sidecar is read once as a migration seed; the document is now the only store
    // (PR 5 removes the legacy write path's remaining plumbing).
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    let fileSystem = LockIsolated<[URL: Data]>([:])
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      let editor = try #require(model.editor)
      editor.mutateDocument { $0.speakerCountOverride = 3 }
    }

    // Sharing touches the seed's entry on first read; the edit itself must never be written.
    #expect((fileSystem.value[url] ?? Data()).isEmpty)
  }

  @Test func viewAppearedBuildsEditorForADecodedPackage() async throws {
    let file = Fixtures.projectFile(
      source: Fixtures.projectSource(originalFingerprint: fingerprint),
      content: Fixtures.editorDocumentState(
        slices: [], timelineRemovals: [], cutSuggestions: [],
        speakerCountOverride: 4, speakerDisplayNames: ["0": "Host", "1": "Guest"]))
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(
      file: file, plan: Fixtures.editPlan(),
      audio: .sessionFile(Fixtures.canonicalAudioURL), sink: sink)
    expectNoDifference(model.phase, .queued)
    #expect(model.showsProgress)
    expectNoDifference(model.progressHeadline, model.queuedMessage)

    await model.viewAppeared()

    expectNoDifference(model.phase, .loaded)
    let editor = try #require(model.editor)
    expectNoDifference(editor.speakerCountOverride, 4)
    expectNoDifference(editor.speakerDisplayNames, ["0": "Host", "1": "Guest"])
    expectNoDifference(editor.canonicalAudioURL, Fixtures.canonicalAudioURL)
    // Building from a decoded package neither transcribes nor commits on its own.
    expectNoDifference(record.commits, [])
    expectNoDifference(record.registerChangeCount, 0)
  }

  @Test func reimportTearsDownPriorEditorAndBuildsFresh() async throws {
    let plan = Fixtures.editPlan()
    let first = try temporaryCanonicalAudio(bytes: 10, name: "qie-project-first")
    let second = try temporaryCanonicalAudio(bytes: 20, name: "qie-project-second")
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let canonicals = LockIsolated<[URL]>([first, second])
    let removed = LockIsolated<[URL]>([])
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.canonicalAudioStore.remove = { url in removed.withValue { $0.append(url) } }
      $0.transcription.transcribe = { _, _, _ in
        let url = canonicals.withValue { $0.removeFirst() }
        return engineEvents([.completed(Fixtures.transcriptionResult(plan, canonicalAudioURL: url))]
        )
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      let firstEditor = try #require(model.editor)
      expectNoDifference(firstEditor.canonicalAudioURL, first)

      // A second import tears the first editor down and builds a fresh one.
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      let secondEditor = try #require(model.editor)
      #expect(firstEditor !== secondEditor)
      expectNoDifference(secondEditor.canonicalAudioURL, second)
    }

    expectNoDifference(model.phase, .loaded)
    expectNoDifference(record.commits.count, 2)
    expectNoDifference(record.commits.last?.file.source.canonicalByteCount, 20)
    expectNoDifference(record.registerChangeCount, 2)
    // The first run's audio is retired, not deleted, while the window is open.
    expectNoDifference(removed.value, [])
  }

  @Test func viewAppearedIsANoOpForAnEmptyModel() async {
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    await model.viewAppeared()
    expectNoDifference(model.phase, .empty)
    #expect(model.editor == nil)
    expectNoDifference(record.commits, [])
  }

  // MARK: - Import entry points (drop / open panel)

  @Test func importButtonPresentsTheImporter() {
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    #expect(!model.isImporterPresented)
    model.importButtonTapped()
    #expect(model.isImporterPresented)
  }

  @Test func filePickFailureIsSurfacedNotSwallowed() {
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    withKnownIssue {
      model.filePickFailed(NSError(domain: "test", code: 1))
    }
    expectNoDifference(model.phase, .empty)  // no phantom import on a failed pick
    expectNoDifference(record.commits, [])
  }

  @Test func nonAudioDropsAreIgnoredAndTheFirstAudioFileWins() async {
    let picked = LockIsolated<URL?>(nil)
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.transcription.transcribe = { url, _, _ in
        picked.setValue(url)
        return neverCompletingEngineEvents()
      }
    } operation: {
      #expect(!model.fileDropped([URL(fileURLWithPath: "/doc.pdf")]))
      expectNoDifference(model.phase, .empty)

      let taken = model.fileDropped([
        URL(fileURLWithPath: "/doc.pdf"),
        URL(fileURLWithPath: "/song.m4a"),
        URL(fileURLWithPath: "/other.wav"),
      ])
      #expect(taken)
      for _ in 0..<1000 where picked.value == nil { await Task.yield() }
      expectNoDifference(picked.value?.path, "/song.m4a")
      #expect(model.showsProgress)
      #expect(!model.acceptsImport)

      // A drop while a run is in flight is refused (one project per window).
      #expect(!model.fileDropped([URL(fileURLWithPath: "/late.m4a")]))
      model.cancelTranscriptionTapped()
    }
  }

  @Test func cancellingAnUntitledImportReturnsToEmpty() async {
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    let task = withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.transcription.transcribe = { _, _, _ in neverCompletingEngineEvents() }
    } operation: {
      model.filePicked(URL(fileURLWithPath: "/clip.m4a"))
      return model.transcriptionTask
    }
    for _ in 0..<1000 where !model.showsCancel { await Task.yield() }
    #expect(model.showsCancel)

    model.cancelTranscriptionTapped()
    await task?.value

    expectNoDifference(model.phase, .empty)
    #expect(!model.showsCancel)
    #expect(model.editor == nil)
    expectNoDifference(record.commits, [])
  }

  @Test func cancellingAReimportKeepsTheProjectAndOffersRetry() async throws {
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    let runs = LockIsolated(0)
    let removed = LockIsolated<[URL]>([])
    let reimport = try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.canonicalAudioStore.remove = { url in removed.withValue { $0.append(url) } }
      $0.transcription.transcribe = { _, _, _ in
        let run = runs.withValue {
          $0 += 1
          return $0
        }
        return run == 1
          ? engineEvents([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
          : neverCompletingEngineEvents()
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      _ = try #require(model.editor)
      model.filePicked(URL(fileURLWithPath: "/clip.m4a"))  // refused: loaded
      expectNoDifference(runs.value, 1)
      let reimport = Task { await model.reimportIgnoringCacheTapped() }
      for _ in 0..<1000 where runs.value < 2 { await Task.yield() }
      return reimport
    }

    model.cancelTranscriptionTapped()
    await reimport.value

    expectNoDifference(model.phase, .failed("Transcription cancelled."))
    #expect(model.editor == nil)
    expectNoDifference(record.commits.count, 1)
    // The document still references the first run's audio; cancelling must not delete it.
    expectNoDifference(removed.value, [])
  }

  @Test func closingTheWindowCancelsAnInFlightExport() async throws {
    let plan = Fixtures.editPlan()
    let renderStarted = LockIsolated(false)
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-project-export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: destination) }
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(plan))])
      }
      $0.exportRender.renderSlice = { _ in
        renderStarted.setValue(true)
        // Cooperative cancellation — never `Task.sleep` — busy-checks the flag that
        // `viewDisappeared`'s `cancelExportTapped()` sets, mirroring how `ExportAudioRenderer`
        // honours `Task.checkCancellation()` between chunks. Bounded so a regression fails the
        // test instead of hanging it.
        for _ in 0..<100_000 where !Task.isCancelled { await Task.yield() }
        try Task.checkCancellation()
      }
      $0.workspace.reveal = { _ in }
      $0.audioPlayer.stop = { _ in }  // closing also stops playback
      $0.canonicalAudioStore.remove = { _ in }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      let editor = try #require(model.editor)

      editor.destinationURL = destination
      editor.slices.append(
        Slice(
          id: UUID(), name: "A", startSample: 0, endSample: 100, wordIDs: [], snippet: "x"))
      editor.exportAllTapped()
      for _ in 0..<1000 where !renderStarted.value { await Task.yield() }
      #expect(editor.isExporting)

      await model.viewDisappeared()  // must cancel the export, not let it outlive the window
      await editor.exportTask?.value
      guard case .failed = editor.exportPhase else {
        Issue.record("expected .failed after close, got \(editor.exportPhase)")
        return
      }
      #expect(model.editor == nil)
    }
  }

  @Test func closingTheWindowRemovesItsCanonicalAudio() async throws {
    // Seed a real cached canonical AIFF, then drive an import whose completion carries
    // its URL; closing the window must delete the cache dir.
    let planAIFF = try temporaryCanonicalAudio(bytes: 9, name: "qie-project-store")
    defer { try? FileManager.default.removeItem(at: planAIFF) }
    let canonical = try CanonicalAudioStore.store(planAIFF: planAIFF)
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(canonicalAudioURL: canonical))])
      }
      $0.audioPlayer.stop = { _ in }
      $0.canonicalAudioStore.remove = { CanonicalAudioStore.remove($0) }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      #expect(FileManager.default.fileExists(atPath: canonical.path))
      await model.viewDisappeared()
      #expect(!FileManager.default.fileExists(atPath: canonical.path))
    }
  }

  // MARK: - Re-import keeps the project (content + audio) until the replacement lands

  @Test func reimportSeedsTheNewEditorFromTheCurrentDocumentNotTheSidecar() async throws {
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.canonicalAudioStore.remove = { _ in }
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      let first = try #require(model.editor)
      first.mutateDocument { $0.speakerCountOverride = 3 }

      await model.reimportIgnoringCacheTapped()
      let second = try #require(model.editor)
      #expect(first !== second)
      // The sidecar seed (never written this session) would say nil; the document says 3.
      expectNoDifference(second.speakerCountOverride, 3)
    }
    expectNoDifference(record.commits.last?.file.content.speakerCountOverride, 3)
  }

  @Test func aReimportWhosePlanChangedRekeysClipsToTheNewWords() async throws {
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    let plan = Fixtures.editPlan()
    let replacement: EditPlan = {
      var replacement = plan
      replacement.words = plan.words.map { word in
        var word = word
        word.text = word.text.uppercased()
        return word
      }
      return replacement
    }()
    let range = try #require(plan.words[0].startSample)..<(try #require(plan.words[1].endSample))
    let stale = Slice(
      id: UUID(), name: "Slice 1", startSample: range.lowerBound, endSample: range.upperBound,
      wordIDs: [99], snippet: "stale")
    let expectedIDs = wordIDs(anyOverlap: range, words: replacement.words)
    let runs = LockIsolated(0)

    try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.canonicalAudioStore.remove = { _ in }
      $0.transcription.transcribe = { _, _, _ in
        let run = runs.withValue {
          $0 += 1
          return $0
        }
        return engineEvents([
          .completed(Fixtures.transcriptionResult(run == 1 ? plan : replacement))
        ])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      let first = try #require(model.editor)
      first.mutateDocument {
        $0.slices = [stale]
        $0.cutSuggestions = [Fixtures.cutSuggestion(id: UUID())]
      }

      await model.reimportIgnoringCacheTapped()
      let second = try #require(model.editor)
      expectNoDifference(second.documentState.slices[0].wordIDs, expectedIDs)
      expectNoDifference(
        second.documentState.slices[0].snippet,
        displaySliceSnippet(sliceSnippet(for: expectedIDs, words: replacement.words)))
      expectNoDifference(second.documentState.cutSuggestions, [])
    }
    expectNoDifference(record.commits.last?.file.content.slices.map(\.wordIDs), [expectedIDs])
  }

  @Test func aReimportThatReproducesTheSameWordsKeepsClipsAndSuggestionsAsIs() async throws {
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    let plan = Fixtures.editPlan()
    // Same words, different silence detection: nothing word-keyed changed, so nothing is
    // re-keyed or dropped.
    let replacement: EditPlan = {
      var replacement = plan
      replacement.silences = []
      return replacement
    }()
    let runs = LockIsolated(0)
    let slice = Slice(
      id: UUID(), name: "Slice 1", startSample: 0, endSample: 44100, wordIDs: [0],
      snippet: "“first”")
    let suggestion = Fixtures.cutSuggestion(id: UUID())

    try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.canonicalAudioStore.remove = { _ in }
      $0.transcription.transcribe = { _, _, _ in
        let run = runs.withValue {
          $0 += 1
          return $0
        }
        return engineEvents([
          .completed(Fixtures.transcriptionResult(run == 1 ? plan : replacement))
        ])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      let first = try #require(model.editor)
      first.mutateDocument {
        $0.slices = [slice]
        $0.cutSuggestions = [suggestion]
      }

      await model.reimportIgnoringCacheTapped()
      let second = try #require(model.editor)
      expectNoDifference(second.documentState.slices, [slice])
      expectNoDifference(second.documentState.cutSuggestions, [suggestion])
    }
  }

  @Test func aDifferentSourceImportedIntoAFailedWindowDoesNotInheritTheOldContent() async throws {
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    let runs = LockIsolated(0)

    try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.canonicalAudioStore.remove = { _ in }
      $0.transcription.transcribe = { _, _, _ in
        let run = runs.withValue {
          $0 += 1
          return $0
        }
        return run == 2
          ? engineEvents([], throwing: EngineClientError.engineFailed("no models"))
          : engineEvents([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      try #require(model.editor).mutateDocument { $0.speakerCountOverride = 3 }
      await model.reimportIgnoringCacheTapped()
      expectNoDifference(model.phase, .failed("Transcription failed: no models"))

      // A failed window takes new audio; another file's edits must not carry over.
      #expect(model.fileDropped([URL(fileURLWithPath: "/other.m4a")]))
      await model.transcriptionTask?.value
      expectNoDifference(try #require(model.editor).speakerCountOverride, nil)
    }
    expectNoDifference(record.commits.last?.file.source.originalFileName, "other.m4a")
    expectNoDifference(record.commits.last?.file.content.speakerCountOverride, nil)
  }

  @Test func aFailedReimportKeepsTheSessionAudioTheDocumentStillReferences() async throws {
    let canonical = try temporaryCanonicalAudio(bytes: 10)
    defer { try? FileManager.default.removeItem(at: canonical) }
    let removed = LockIsolated<[URL]>([])
    let runs = LockIsolated(0)
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.canonicalAudioStore.remove = { url in removed.withValue { $0.append(url) } }
      $0.transcription.transcribe = { _, _, _ in
        let run = runs.withValue {
          $0 += 1
          return $0
        }
        return run == 1
          ? engineEvents([
            .completed(
              Fixtures.transcriptionResult(Fixtures.editPlan(), canonicalAudioURL: canonical))
          ])
          : engineEvents([], throwing: EngineClientError.engineFailed("no models"))
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      await model.reimportIgnoringCacheTapped()
    }

    expectNoDifference(model.phase, .failed("Transcription failed: no models"))
    #expect(model.editor == nil)
    // The document still points at the first run's audio, so a save must still find it.
    expectNoDifference(record.commits.count, 1)
    expectNoDifference(record.commits.last?.audio, .sessionFile(canonical))
    expectNoDifference(removed.value, [])
  }

  @Test func aSuccessfulReimportRetiresThePriorSessionAudioUntilTheWindowCloses() async throws {
    let first = try temporaryCanonicalAudio(bytes: 10, name: "qie-project-first")
    let second = try temporaryCanonicalAudio(bytes: 20, name: "qie-project-second")
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let canonicals = LockIsolated<[URL]>([first, second])
    let removed = LockIsolated<[URL]>([])
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.canonicalAudioStore.remove = { url in removed.withValue { $0.append(url) } }
      $0.transcription.transcribe = { _, _, _ in
        let url = canonicals.withValue { $0.removeFirst() }
        return engineEvents([
          .completed(Fixtures.transcriptionResult(Fixtures.editPlan(), canonicalAudioURL: url))
        ])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      await model.reimportIgnoringCacheTapped()
      expectNoDifference(record.commits.last?.audio, .sessionFile(second))
      // A save snapshotted before the replacement commit may still read the first copy, so it
      // outlives the commit and goes with the window.
      expectNoDifference(removed.value, [])
      await model.viewDisappeared()
    }

    expectNoDifference(removed.value, [first, second])
  }

  @Test func closingTheWindowAfterAFailedReimportReleasesTheRetainedAudio() async throws {
    let canonical = try temporaryCanonicalAudio(bytes: 10)
    defer { try? FileManager.default.removeItem(at: canonical) }
    let removed = LockIsolated<[URL]>([])
    let runs = LockIsolated(0)
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.canonicalAudioStore.remove = { url in removed.withValue { $0.append(url) } }
      $0.transcription.transcribe = { _, _, _ in
        let run = runs.withValue {
          $0 += 1
          return $0
        }
        return run == 1
          ? engineEvents([
            .completed(
              Fixtures.transcriptionResult(Fixtures.editPlan(), canonicalAudioURL: canonical))
          ])
          : engineEvents([], throwing: EngineClientError.engineFailed("no models"))
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      await model.reimportIgnoringCacheTapped()
      expectNoDifference(removed.value, [])
      await model.viewDisappeared()
    }

    expectNoDifference(removed.value, [canonical])
  }
}
