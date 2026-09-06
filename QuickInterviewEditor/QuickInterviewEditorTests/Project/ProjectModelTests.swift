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
    // Exactly one commit — the transcription completion. No document change registered yet.
    expectNoDifference(record.registerChangeCount, 0)
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
    // canonicalFingerprint is PR 5's; the import leaves it empty.
    expectNoDifference(commit.file.source.canonicalFingerprint, "")
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

  @Test func canReimportOnlyWhenLoadedFromThisSession() async {
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

    // A project opened from disk has no session source to re-run until PR 5.
    let opened = ProjectModel(
      file: Fixtures.projectFile(), plan: Fixtures.editPlan(),
      audio: .sessionFile(Fixtures.canonicalAudioURL), sink: sink)
    await opened.viewAppeared()
    #expect(opened.isLoaded)
    #expect(!opened.canReimport)
    await opened.reimportIgnoringCacheTapped()  // no-op
    #expect(opened.isLoaded)
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

      expectNoDifference(record.registerChangeCount, 1)
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
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
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
    expectNoDifference(record.registerChangeCount, 0)
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
    let reimport = try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
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
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
      #expect(FileManager.default.fileExists(atPath: canonical.path))
      await model.viewDisappeared()
      // Removal happens after playback teardown, on a detached task — let it run.
      for _ in 0..<1000 where FileManager.default.fileExists(atPath: canonical.path) {
        await Task.yield()
      }
      #expect(!FileManager.default.fileExists(atPath: canonical.path))
    }
  }
}
