import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
// `FileStorage.inMemory(fileSystem:)` is `@_spi(Internals)`, mirroring the sidecar-migration
// seeding tests on the tab it replaces.
@_spi(Internals) import Sharing
import Testing

@testable import PlayolaInterviewEditor

private func stream(_ events: [EngineEvent], throwing error: Error? = nil)
  -> AsyncThrowingStream<EngineEvent, Error>
{
  AsyncThrowingStream { continuation in
    for event in events { continuation.yield(event) }
    continuation.finish(throwing: error)
  }
}

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
    #expect(model.editor == nil)
    expectNoDifference(record.commits, [])
    expectNoDifference(record.registerChangeCount, 0)
  }

  @Test func importReachesLoadedAndCommitsSessionFileOnce() async throws {
    let plan = Fixtures.editPlan()
    let canonical = URL(fileURLWithPath: "/tmp/qie-project-canonical.aiff")
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    await withDependencies {
      $0.date = .constant(importedAt)
      $0.transcription.transcribe = { _, _, _ in
        stream([
          .progress(.init(phase: "transcribing", message: "Transcribing")),
          .completed(Fixtures.transcriptionResult(plan, canonicalAudioURL: canonical)),
        ])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }

    expectNoDifference(model.phase, .loaded)
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

  @Test func progressUpdatesTranscribingFraction() async {
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream(
          [.progress(.init(phase: "aligning", message: "Aligning", fraction: 0.42))],
          throwing: CancellationError())
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }
    // The cancelled stream leaves the last observed fraction visible.
    expectNoDifference(model.phase, .transcribing(0.42))
  }

  @Test func failureSetsFailedPhaseWithMessage() async {
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream([], throwing: EngineClientError.engineFailed("no models"))
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }
    expectNoDifference(model.phase, .failed("Transcription failed: no models"))
    #expect(model.editor == nil)
    expectNoDifference(record.commits, [])
  }

  @Test func importPassesUseCachePolicy() async {
    let captured = LockIsolated<CachePolicy?>(nil)
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    await withDependencies {
      $0.date = .constant(importedAt)
      $0.transcription.transcribe = { _, _, policy in
        captured.setValue(policy)
        return stream([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }
    expectNoDifference(captured.value, .useCache)
  }

  @Test func oneDocumentMutationCommitsOnceAndRegistersOneChange() async throws {
    let plan = Fixtures.editPlan()
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    try await withDependencies {
      $0.date = .constant(importedAt)
      $0.transcription.transcribe = { _, _, _ in
        stream([.completed(Fixtures.transcriptionResult(plan))])
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
      $0.date = .constant(importedAt)
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
      $0.transcription.transcribe = { _, _, _ in
        stream([.completed(Fixtures.transcriptionResult(plan))])
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

    await model.viewAppeared()

    expectNoDifference(model.phase, .loaded)
    let editor = try #require(model.editor)
    expectNoDifference(editor.speakerCountOverride, 4)
    expectNoDifference(editor.speakerDisplayNames, ["0": "Host", "1": "Guest"])
    // Building from a decoded package neither transcribes nor commits on its own.
    expectNoDifference(record.commits, [])
    expectNoDifference(record.registerChangeCount, 0)
  }

  @Test func reimportTearsDownPriorEditorAndBuildsFresh() async throws {
    let plan = Fixtures.editPlan()
    let first = URL(fileURLWithPath: "/tmp/qie-project-first.aiff")
    let second = URL(fileURLWithPath: "/tmp/qie-project-second.aiff")
    let canonicals = LockIsolated<[URL]>([first, second])
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    try await withDependencies {
      $0.date = .constant(importedAt)
      $0.transcription.transcribe = { _, _, _ in
        let url = canonicals.withValue { $0.removeFirst() }
        return stream([.completed(Fixtures.transcriptionResult(plan, canonicalAudioURL: url))])
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
}
