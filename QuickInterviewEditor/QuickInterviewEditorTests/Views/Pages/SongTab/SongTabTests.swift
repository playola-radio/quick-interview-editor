import CustomDump
import Dependencies
import Foundation
import Testing
@testable import QuickInterviewEditor

private func stream(_ events: [EngineEvent], throwing error: Error? = nil)
  -> AsyncThrowingStream<EngineEvent, Error> {
  AsyncThrowingStream { c in
    for e in events { c.yield(e) }
    c.finish(throwing: error)
  }
}

@MainActor
struct SongTabTests {
  @Test func progressThenCompletedWalksToLoaded() async {
    let plan = Fixtures.editPlan()
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    await withDependencies {
      $0.engine.transcribe = { _ in
        stream([.progress(.init(phase: .transcribing, message: "Transcribing")),
                .completed(plan)])
      }
    } operation: {
      await model.startTranscription()
    }
    #expect(model.isLoaded)
    expectNoDifference(model.transcript?.words.count, 122)
  }

  @Test func progressUpdatesMessageBeforeCompletion() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    await withDependencies {
      $0.engine.transcribe = { _ in
        stream([.progress(.init(phase: .converting, message: "Converting audio"))],
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
      $0.engine.transcribe = { _ in stream([.completed(plan)]) }
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
    #expect(model.isQueued)   // re-enters the queue so the cap is respected
    #expect(readyCalled)
  }
}
