import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

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
      $0.engine.transcribe = { _ in
        stream([
          .progress(.init(phase: .transcribing, message: "Transcribing")),
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

  @Test func progressUpdatesMessageBeforeCompletion() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    await withDependencies {
      $0.engine.transcribe = { _ in
        stream(
          [.progress(.init(phase: .converting, message: "Converting audio"))],
          throwing: CancellationError())
      }
    } operation: {
      await model.startTranscription()
    }
    // last observed progress message stays visible
    expectNoDifference(model.progressMessage, "Converting audio")
  }

  @Test func failureSetsFailedPhaseWithMessage() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    await withDependencies {
      $0.engine.transcribe = { _ in
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
    expectNoDifference(model.progressMessage, model.queuedMessage)
  }

  @Test func completionInvokesOnReadyForNext() async {
    let plan = Fixtures.editPlan()
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    var readyCalled = false
    model.onReadyForNext = { readyCalled = true }
    await withDependencies {
      $0.engine.transcribe = { _ in stream([.completed(Fixtures.transcriptionResult(plan))]) }
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

  @Test func preparingPhaseIsIndeterminate() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    await withDependencies {
      $0.engine.transcribe = { _ in
        stream([.progress(.init(phase: .transcribing, message: "Preparing audio…"))])
      }
    } operation: {
      await model.startTranscription()
    }
    #expect(model.isProgressDeterminate == false)
    expectNoDifference(model.progressFraction, nil)
  }

  @Test func transcribingFractionIsDeterminate() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    await withDependencies {
      $0.engine.transcribe = { _ in
        stream([
          .progress(.init(phase: .transcribing, message: "Transcribing audio…", fraction: 0.25))
        ])
      }
    } operation: {
      await model.startTranscription()
    }
    #expect(model.isProgressDeterminate == true)
    expectNoDifference(model.progressFraction, 0.25)
    expectNoDifference(model.determinateValue, 0.25)
  }

  @Test func fractionNeverMovesBackward() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    await withDependencies {
      $0.engine.transcribe = { _ in
        stream([
          .progress(.init(phase: .transcribing, message: "x", fraction: 0.6)),
          .progress(.init(phase: .transcribing, message: "x", fraction: 0.4)),
        ])
      }
    } operation: {
      await model.startTranscription()
    }
    expectNoDifference(model.progressFraction, 0.6)
  }

  @Test func tailPhaseGoesIndeterminate() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    await withDependencies {
      $0.engine.transcribe = { _ in
        stream([
          .progress(.init(phase: .transcribing, message: "x", fraction: 1.0)),
          .progress(.init(phase: .converting, message: "Converting audio")),
        ])
      }
    } operation: {
      await model.startTranscription()
    }
    #expect(model.isProgressDeterminate == false)
    expectNoDifference(model.progressMessage, "Converting audio")
  }

  @Test func maxFractionResetsAcrossRuns() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
    let callCount = LockIsolated(0)
    await withDependencies {
      $0.continuousClock = ImmediateClock()
      $0.engine.transcribe = { _ in
        let isFirstRun = callCount.withValue { count -> Bool in
          count += 1
          return count == 1
        }
        return isFirstRun
          ? stream([.progress(.init(phase: .transcribing, message: "x", fraction: 0.8))])
          : stream([.progress(.init(phase: .transcribing, message: "x", fraction: 0.1))])
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

  @Test func etaTextBelowThresholdIsNil() {
    expectNoDifference(SongTabModel.etaText(elapsedSeconds: 1, fraction: 0.01), nil)
  }

  @Test func etaTextDuringTranscribeFormatsRemaining() {
    // fraction 0.25 -> within-transcribe p = 0.5; elapsed 120s -> remaining 120s.
    expectNoDifference(
      SongTabModel.etaText(elapsedSeconds: 120, fraction: 0.25),
      "About 2 min remaining")
  }

  @Test func etaTextUnderOneMinute() {
    // p = 0.8, elapsed 120s -> remaining 30s.
    expectNoDifference(
      SongTabModel.etaText(elapsedSeconds: 120, fraction: 0.4),
      "Less than a minute remaining")
  }

  @Test func etaTextWhileAligningIsNonNumeric() {
    expectNoDifference(
      SongTabModel.etaText(elapsedSeconds: 300, fraction: 0.7),
      "Aligning words — almost done")
  }

  @Test func elapsedAdvancesWithClock() async {
    let clock = TestClock()
    let model = withDependencies {
      $0.continuousClock = clock
      var client = EngineClient.testValue
      client.transcribe = { _ in
        AsyncThrowingStream { c in
          c.yield(.progress(EngineProgress(phase: .transcribing, message: "x", fraction: 0.25)))
          // leave the stream open so the tick task keeps running
        }
      }
      $0.engine = client
    } operation: { SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav")) }

    model.start()
    await clock.advance(by: .seconds(120))
    // fraction 0.25 -> p 0.5, elapsed 120 -> remaining 120s
    expectNoDifference(model.etaMessage, "About 2 min remaining")
    model.cancel()
  }
}
