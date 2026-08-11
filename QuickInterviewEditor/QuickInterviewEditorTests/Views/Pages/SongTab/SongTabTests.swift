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
}
