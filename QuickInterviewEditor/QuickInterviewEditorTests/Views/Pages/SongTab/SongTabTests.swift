import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
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
struct SongTabTests {
  @Test func progressThenCompletedWalksToLoaded() async {
    let plan = Fixtures.editPlan()
    let canonical = URL(fileURLWithPath: "/tmp/qie-songtab-canonical.aiff")
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream([
          .progress(.init(phase: "transcribing", message: "Transcribing")),
          .completed(Fixtures.transcriptionResult(plan, canonicalAudioURL: canonical)),
        ])
      }
    } operation: {
      await model.startTranscription()
    }
    #expect(model.isLoaded)
    expectNoDifference(model.editor?.transcript.document.wordRanges.count, 122)
    // The canonical AIFF from the completion is handed to the editor.
    expectNoDifference(model.editor?.canonicalAudioURL, canonical)
  }

  @Test func progressUpdatesHeadlineBeforeCompletion() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream(
          [
            .progress(
              .init(
                phase: "finalizing", phaseIndex: 3, phaseCount: 3, label: "Finalizing",
                message: "Converting audio…"))
          ],
          throwing: CancellationError())
      }
    } operation: {
      await model.startTranscription()
    }
    // last observed progress stays visible
    expectNoDifference(model.progressHeadline, "Phase 3 of 3 · Converting audio…")
  }

  @Test func failureSetsFailedPhaseWithMessage() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream([], throwing: EngineClientError.engineFailed("no models"))
      }
    } operation: {
      await model.startTranscription()
    }
    expectNoDifference(model.errorMessage, "Transcription failed: no models")
    #expect(!model.isLoaded)
  }

  @Test func titleIsFilenameWithoutExtension() {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/a/Interview_047.m4a"))
    expectNoDifference(model.title, "Interview_047")
  }

  @Test func startsQueued() {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    #expect(model.isQueued)
    expectNoDifference(model.progressHeadline, model.queuedMessage)
  }

  @Test func completionInvokesOnReadyForNext() async {
    let plan = Fixtures.editPlan()
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    var readyCalled = false
    model.onReadyForNext = { readyCalled = true }
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream([.completed(Fixtures.transcriptionResult(plan))])
      }
    } operation: {
      await model.startTranscription()
    }
    #expect(readyCalled)  // slot freed → RootModel can start the next queued tab
  }

  @Test func retryRequeuesAndInvokesOnReadyForNext() {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    var readyCalled = false
    model.onReadyForNext = { readyCalled = true }
    model.retryTapped()
    #expect(model.isQueued)  // re-enters the queue so the cap is respected
    #expect(readyCalled)
  }

  @Test func startPassesUseCachePolicyByDefault() async {
    let captured = LockIsolated<CachePolicy?>(nil)
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    await withDependencies {
      $0.transcription.transcribe = { _, _, policy in
        captured.setValue(policy)
        return stream([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.startTranscription()
    }
    expectNoDifference(captured.value, .useCache)
  }

  @Test func reimportIgnoringCacheRequeuesWithForceFresh() async {
    let captured = LockIsolated<CachePolicy?>(nil)
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    var readyCalled = false
    model.onReadyForNext = { readyCalled = true }

    model.reimportIgnoringCacheTapped()
    #expect(model.isQueued)  // re-enters the queue so the cap is respected
    #expect(readyCalled)

    await withDependencies {
      $0.transcription.transcribe = { _, _, policy in
        captured.setValue(policy)
        return stream([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.startTranscription()
    }
    expectNoDifference(captured.value, .forceFresh)
  }

  @Test func canReimportOnlyWhenLoaded() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    #expect(!model.canReimport)  // queued
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.startTranscription()
    }
    #expect(model.canReimport)  // loaded
  }

  @Test func preparingPhaseIsIndeterminate() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream([
          .progress(
            .init(
              phase: "transcribing", phaseIndex: 1, phaseCount: 3, label: "Transcribing",
              message: "Preparing audio…"))
        ])
      }
    } operation: {
      await model.startTranscription()
    }
    #expect(model.isProgressDeterminate == false)
    expectNoDifference(model.progressFraction, nil)
    expectNoDifference(model.progressHeadline, "Phase 1 of 3 · Preparing audio…")
  }

  @Test func headlineShowsPhaseOfNLabelAndPercent() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream([
          .progress(
            .init(
              phase: "aligning", phaseIndex: 2, phaseCount: 3, label: "Aligning words",
              message: "Aligning words", fraction: 0.42))
        ])
      }
    } operation: {
      await model.startTranscription()
    }
    #expect(model.isProgressDeterminate == true)
    expectNoDifference(model.progressFraction, 0.42)
    expectNoDifference(model.determinateValue, 0.42)
    expectNoDifference(model.progressHeadline, "Phase 2 of 3 · Aligning words · 42%")
  }

  @Test func fractionNeverMovesBackwardWithinPhase() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream([
          .progress(
            .init(
              phase: "transcribing", phaseIndex: 1, phaseCount: 3, label: "Transcribing",
              message: "Transcribing", fraction: 0.6)),
          .progress(
            .init(
              phase: "transcribing", phaseIndex: 1, phaseCount: 3, label: "Transcribing",
              message: "Transcribing", fraction: 0.4)),
        ])
      }
    } operation: {
      await model.startTranscription()
    }
    expectNoDifference(model.progressFraction, 0.6)
  }

  @Test func clampResetsWhenPhaseAdvances() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream([
          .progress(
            .init(
              phase: "transcribing", phaseIndex: 1, phaseCount: 3, label: "Transcribing",
              message: "Transcribing", fraction: 0.9)),
          .progress(
            .init(
              phase: "aligning", phaseIndex: 2, phaseCount: 3, label: "Aligning words",
              message: "Aligning words", fraction: 0.1)),
        ])
      }
    } operation: {
      await model.startTranscription()
    }
    // Phase 2 starts its own 0–100%; phase 1's 0.9 doesn't pin it.
    expectNoDifference(model.progressFraction, 0.1)
    expectNoDifference(model.progressHeadline, "Phase 2 of 3 · Aligning words · 10%")
  }

  @Test func ignoresStaleEarlierPhaseEvent() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream([
          .progress(
            .init(
              phase: "aligning", phaseIndex: 2, phaseCount: 3, label: "Aligning words",
              message: "Aligning words", fraction: 0.3)),
          // A late phase-1 event arrives after phase 2 started; it must be ignored.
          .progress(
            .init(
              phase: "transcribing", phaseIndex: 1, phaseCount: 3, label: "Transcribing",
              message: "Transcribing", fraction: 0.9)),
        ])
      }
    } operation: {
      await model.startTranscription()
    }
    expectNoDifference(model.progressFraction, 0.3)
    expectNoDifference(model.progressHeadline, "Phase 2 of 3 · Aligning words · 30%")
  }

  @Test func invalidHighPhaseIndexDoesNotPoisonLaterValidPhase() async {
    // A malformed index (999 of 3) must normalize away, not pin the phase high —
    // otherwise a subsequent valid phase 2 would look stale and be ignored forever.
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream([
          .progress(
            .init(
              phase: "bogus", phaseIndex: 999, phaseCount: 3, label: "Bogus",
              message: "Bogus", fraction: 0.4)),
          .progress(
            .init(
              phase: "aligning", phaseIndex: 2, phaseCount: 3, label: "Aligning words",
              message: "Aligning words", fraction: 0.3)),
        ])
      }
    } operation: {
      await model.startTranscription()
    }
    // The later valid phase 2 is honored (not dropped as stale), and its own 0–100%
    // is shown rather than the bogus event's 40%.
    expectNoDifference(model.progressFraction, 0.3)
    expectNoDifference(model.progressHeadline, "Phase 2 of 3 · Aligning words · 30%")
  }

  @Test func tailPhaseGoesIndeterminate() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream([
          .progress(
            .init(
              phase: "transcribing", phaseIndex: 1, phaseCount: 3, label: "Transcribing",
              message: "Transcribing", fraction: 1.0)),
          .progress(
            .init(
              phase: "finalizing", phaseIndex: 3, phaseCount: 3, label: "Finalizing",
              message: "Converting audio…")),
        ])
      }
    } operation: {
      await model.startTranscription()
    }
    #expect(model.isProgressDeterminate == false)
    expectNoDifference(model.progressHeadline, "Phase 3 of 3 · Converting audio…")
  }

  @Test func oldFormatMessageOnlyPhaseGoesIndeterminate() async {
    // Old-format events carry no phase_index, so the clamp must reset on the raw phase
    // name changing — otherwise a message-only tail phase would freeze the prior
    // phase's determinate percent instead of showing a spinner.
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        stream([
          .progress(.init(phase: "transcribing", message: "Transcribing", fraction: 0.5)),
          .progress(.init(phase: "converting", message: "Converting audio")),
        ])
      }
    } operation: {
      await model.startTranscription()
    }
    #expect(model.isProgressDeterminate == false)
    expectNoDifference(model.progressHeadline, "Converting audio")
  }

  @Test func maxFractionResetsAcrossRuns() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    let callCount = LockIsolated(0)
    await withDependencies {
      $0.continuousClock = ImmediateClock()
      $0.transcription.transcribe = { _, _, _ in
        let isFirstRun = callCount.withValue { count -> Bool in
          count += 1
          return count == 1
        }
        return isFirstRun
          ? stream([.progress(.init(phase: "transcribing", message: "x", fraction: 0.8))])
          : stream([.progress(.init(phase: "transcribing", message: "x", fraction: 0.1))])
      }
    } operation: {
      await withCheckedContinuation { continuation in
        model.onReadyForNext = { continuation.resume() }
        model.start()
      }
      expectNoDifference(model.progressFraction, 0.8)

      // A second real run (start(), not startTranscription()) must reset the monotonic
      // ceiling — otherwise a shorter/faster retry would stay pinned at the prior run's max.
      await withCheckedContinuation { continuation in
        model.onReadyForNext = { continuation.resume() }
        model.start()
      }
      expectNoDifference(model.progressFraction, 0.1)
    }
  }

  @Test func phaseETABelowThresholdsIsNil() {
    // Too early in the phase (elapsed) and too little progress (fraction).
    expectNoDifference(
      SongTabModel.phaseETAText(phaseElapsedSeconds: 20, fraction: 0.5), nil)
    expectNoDifference(
      SongTabModel.phaseETAText(phaseElapsedSeconds: 60, fraction: 0.03), nil)
  }

  @Test func phaseETAFormatsRemainingInThisPhase() {
    // fraction 0.25, elapsed 120s in-phase -> remaining 360s -> 6 min.
    expectNoDifference(
      SongTabModel.phaseETAText(phaseElapsedSeconds: 120, fraction: 0.25),
      "About 6 min left in this phase")
  }

  @Test func phaseETAUnderOneMinute() {
    // fraction 0.7, elapsed 120s -> remaining ~51s.
    expectNoDifference(
      SongTabModel.phaseETAText(phaseElapsedSeconds: 120, fraction: 0.7),
      "Less than a minute left in this phase")
  }

  @Test func etaMeasuresElapsedWithinCurrentPhase() async {
    let clock = TestClock()
    let model = withDependencies {
      $0.continuousClock = clock
      $0.transcription.transcribe = { _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(
            .progress(
              EngineProgress(
                phase: "transcribing", phaseIndex: 1, phaseCount: 3, label: "Transcribing",
                message: "Transcribing", fraction: 0.25)))
          // leave the stream open so the tick task keeps running
        }
      }
    } operation: {
      SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    }

    await withMainSerialExecutor {
      model.start()
      await clock.advance(by: .seconds(120))
      // 120s in phase, fraction 0.25 -> remaining 360s -> 6 min.
      expectNoDifference(model.etaMessage, "About 6 min left in this phase")
      model.cancel()
    }
  }
}
