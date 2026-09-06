import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import PlayolaInterviewEditor

/// The transcription progress presentation ported from the old per-tab model: phase-of-N
/// headline, monotonic per-phase clamp, stale-event rejection, and the in-phase ETA.
@MainActor
struct ProjectProgressTests {
  private func freshModel() -> ProjectModel {
    let (sink, _) = ProjectDocumentSink.recorder()
    return ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
  }

  private func run(_ model: ProjectModel, _ events: [EngineEvent], throwing error: Error? = nil)
    async
  {
    await withDependencies {
      $0.continuousClock = TestClock()
      $0.transcription.transcribe = { _, _, _ in engineEvents(events, throwing: error) }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/tmp/a.wav"))
    }
  }

  @Test func startingMessageShowsBeforeTheFirstProgressEvent() async {
    let model = freshModel()
    await run(model, [], throwing: CancellationError())
    expectNoDifference(model.phase, .transcribing(nil))
    expectNoDifference(model.progressHeadline, model.startingMessage)
    #expect(!model.isProgressDeterminate)
  }

  @Test func lastProgressStaysVisibleAfterCancellation() async {
    let model = freshModel()
    await run(
      model,
      [
        .progress(
          .init(
            phase: "finalizing", phaseIndex: 3, phaseCount: 3, label: "Finalizing",
            message: "Converting audio…"))
      ], throwing: CancellationError())
    expectNoDifference(model.progressHeadline, "Phase 3 of 3 · Converting audio…")
  }

  @Test func preparingPhaseIsIndeterminate() async {
    let model = freshModel()
    await run(
      model,
      [
        .progress(
          .init(
            phase: "transcribing", phaseIndex: 1, phaseCount: 3, label: "Transcribing",
            message: "Preparing audio…"))
      ])
    #expect(model.isProgressDeterminate == false)
    expectNoDifference(model.progressFraction, nil)
    expectNoDifference(model.progressHeadline, "Phase 1 of 3 · Preparing audio…")
  }

  @Test func headlineShowsPhaseOfNLabelAndPercent() async {
    let model = freshModel()
    await run(
      model,
      [
        .progress(
          .init(
            phase: "aligning", phaseIndex: 2, phaseCount: 3, label: "Aligning words",
            message: "Aligning words", fraction: 0.42))
      ])
    #expect(model.isProgressDeterminate == true)
    expectNoDifference(model.progressFraction, 0.42)
    expectNoDifference(model.determinateValue, 0.42)
    expectNoDifference(model.progressHeadline, "Phase 2 of 3 · Aligning words · 42%")
  }

  @Test func fractionNeverMovesBackwardWithinPhase() async {
    let model = freshModel()
    await run(
      model,
      [
        .progress(
          .init(
            phase: "transcribing", phaseIndex: 1, phaseCount: 3, label: "Transcribing",
            message: "Transcribing", fraction: 0.6)),
        .progress(
          .init(
            phase: "transcribing", phaseIndex: 1, phaseCount: 3, label: "Transcribing",
            message: "Transcribing", fraction: 0.4)),
      ])
    expectNoDifference(model.progressFraction, 0.6)
  }

  @Test func clampResetsWhenPhaseAdvances() async {
    let model = freshModel()
    await run(
      model,
      [
        .progress(
          .init(
            phase: "transcribing", phaseIndex: 1, phaseCount: 3, label: "Transcribing",
            message: "Transcribing", fraction: 0.9)),
        .progress(
          .init(
            phase: "aligning", phaseIndex: 2, phaseCount: 3, label: "Aligning words",
            message: "Aligning words", fraction: 0.1)),
      ])
    // Phase 2 starts its own 0–100%; phase 1's 0.9 doesn't pin it.
    expectNoDifference(model.progressFraction, 0.1)
    expectNoDifference(model.progressHeadline, "Phase 2 of 3 · Aligning words · 10%")
  }

  @Test func ignoresStaleEarlierPhaseEvent() async {
    let model = freshModel()
    await run(
      model,
      [
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
    expectNoDifference(model.progressFraction, 0.3)
    expectNoDifference(model.progressHeadline, "Phase 2 of 3 · Aligning words · 30%")
  }

  @Test func invalidHighPhaseIndexDoesNotPoisonLaterValidPhase() async {
    // A malformed index (999 of 3) must normalize away, not pin the phase high —
    // otherwise a subsequent valid phase 2 would look stale and be ignored forever.
    let model = freshModel()
    await run(
      model,
      [
        .progress(
          .init(
            phase: "bogus", phaseIndex: 999, phaseCount: 3, label: "Bogus",
            message: "Bogus", fraction: 0.4)),
        .progress(
          .init(
            phase: "aligning", phaseIndex: 2, phaseCount: 3, label: "Aligning words",
            message: "Aligning words", fraction: 0.3)),
      ])
    expectNoDifference(model.progressFraction, 0.3)
    expectNoDifference(model.progressHeadline, "Phase 2 of 3 · Aligning words · 30%")
  }

  @Test func tailPhaseGoesIndeterminate() async {
    let model = freshModel()
    await run(
      model,
      [
        .progress(
          .init(
            phase: "transcribing", phaseIndex: 1, phaseCount: 3, label: "Transcribing",
            message: "Transcribing", fraction: 1.0)),
        .progress(
          .init(
            phase: "finalizing", phaseIndex: 3, phaseCount: 3, label: "Finalizing",
            message: "Converting audio…")),
      ])
    #expect(model.isProgressDeterminate == false)
    expectNoDifference(model.progressHeadline, "Phase 3 of 3 · Converting audio…")
  }

  @Test func oldFormatMessageOnlyPhaseGoesIndeterminate() async {
    // Old-format events carry no phase_index, so the clamp must reset on the raw phase
    // name changing — otherwise a message-only tail phase would freeze the prior
    // phase's determinate percent instead of showing a spinner.
    let model = freshModel()
    await run(
      model,
      [
        .progress(.init(phase: "transcribing", message: "Transcribing", fraction: 0.5)),
        .progress(.init(phase: "converting", message: "Converting audio")),
      ])
    #expect(model.isProgressDeterminate == false)
    expectNoDifference(model.progressHeadline, "Converting audio")
  }

  @Test func maxFractionResetsAcrossRuns() async {
    let model = freshModel()
    let callCount = LockIsolated(0)
    await withDependencies {
      $0.continuousClock = ImmediateClock()
      $0.transcription.transcribe = { _, _, _ in
        let isFirstRun = callCount.withValue { count -> Bool in
          count += 1
          return count == 1
        }
        return isFirstRun
          ? engineEvents([.progress(.init(phase: "transcribing", message: "x", fraction: 0.8))])
          : engineEvents([.progress(.init(phase: "transcribing", message: "x", fraction: 0.1))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/tmp/a.wav"))
      expectNoDifference(model.progressFraction, 0.8)

      // A second run must reset the monotonic ceiling — otherwise a shorter/faster retry
      // would stay pinned at the prior run's max.
      await model.retryTapped()
      expectNoDifference(model.progressFraction, 0.1)
    }
  }

  @Test func phaseETABelowThresholdsIsNil() {
    // Too early in the phase (elapsed) and too little progress (fraction).
    expectNoDifference(ProjectModel.phaseETAText(phaseElapsedSeconds: 20, fraction: 0.5), nil)
    expectNoDifference(ProjectModel.phaseETAText(phaseElapsedSeconds: 60, fraction: 0.03), nil)
  }

  @Test func phaseETAFormatsRemainingInThisPhase() {
    // fraction 0.25, elapsed 120s in-phase -> remaining 360s -> 6 min.
    expectNoDifference(
      ProjectModel.phaseETAText(phaseElapsedSeconds: 120, fraction: 0.25),
      "About 6 min left in this phase")
  }

  @Test func phaseETAUnderOneMinute() {
    // fraction 0.7, elapsed 120s -> remaining ~51s.
    expectNoDifference(
      ProjectModel.phaseETAText(phaseElapsedSeconds: 120, fraction: 0.7),
      "Less than a minute left in this phase")
  }

  @Test func etaMeasuresElapsedWithinCurrentPhase() async {
    let clock = TestClock()
    let model = freshModel()
    await withDependencies {
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
      await withMainSerialExecutor {
        model.filePicked(URL(fileURLWithPath: "/tmp/a.wav"))
        await clock.advance(by: .seconds(120))
        // 120s in phase, fraction 0.25 -> remaining 360s -> 6 min.
        expectNoDifference(model.etaMessage, "About 6 min left in this phase")
        model.cancelTranscriptionTapped()
        await model.transcriptionTask?.value
      }
    }
  }
}
