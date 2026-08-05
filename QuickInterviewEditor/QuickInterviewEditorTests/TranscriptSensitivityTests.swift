import Clocks
import CustomDump
import Dependencies
import Testing

@testable import QuickInterviewEditor

@MainActor
struct TranscriptSensitivityTests {
  private var plan: EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: .init(path: "", sampleRate: 1000, channels: 1, durationSamples: 3000),
      words: [
        Word(id: 1, text: "one", start: 0.0, end: 0.10, startSample: 0, endSample: 100),
        // 20ms gap
        Word(id: 2, text: "two", start: 0.12, end: 0.30, startSample: 120, endSample: 300),
        // 600ms gap
        Word(id: 3, text: "three", start: 0.90, end: 1.0, startSample: 900, endSample: 1000),
      ], silences: [], segments: [])
  }

  @Test func gapRecordsComputeAdjacentGapsInMs() {
    let gaps = wordGaps(plan.words)
    expectNoDifference(
      gaps,
      [
        WordGap(leftID: 1, rightID: 2, gapMs: 20),
        WordGap(leftID: 2, rightID: 3, gapMs: 600),
      ])
  }

  @Test func runTogetherFromGapsMatchesThreshold() {
    let gaps = wordGaps(plan.words)
    expectNoDifference(runTogetherWordIDs(gaps: gaps, maxGapMs: 30), [1, 2])
    expectNoDifference(runTogetherWordIDs(gaps: gaps, maxGapMs: 10), [])
  }

  @Test func draftUpdatesImmediatelyButCommitIsDebounced() async {
    let clock = TestClock()
    await withDependencies {
      $0.continuousClock = clock
    } operation: {
      let model = TranscriptPageModel(editPlan: plan)
      model.sensitivityDragChanged(80)
      expectNoDifference(model.draftGapMs, 80)  // label follows instantly
      expectNoDifference(model.runTogetherMaxGapMs, 30)  // effective value not yet committed
      await clock.advance(by: .milliseconds(200))
      expectNoDifference(model.runTogetherMaxGapMs, 80)  // committed after debounce
    }
  }

  @Test func rapidDragCommitsOnlyTheLastValue() async {
    let clock = TestClock()
    await withDependencies {
      $0.continuousClock = clock
    } operation: {
      let model = TranscriptPageModel(editPlan: plan)
      model.sensitivityDragChanged(50)
      await clock.advance(by: .milliseconds(100))  // still inside the 150ms window
      model.sensitivityDragChanged(80)  // cancels the pending 50ms commit
      expectNoDifference(model.draftGapMs, 80)
      expectNoDifference(model.runTogetherMaxGapMs, 30)  // neither value committed yet
      await clock.advance(by: .milliseconds(200))  // past the second commit's window
      expectNoDifference(model.runTogetherMaxGapMs, 80)  // only the last value commits
    }
  }

  @Test func immediateSetterCancelsPendingDebouncedCommit() async {
    let clock = TestClock()
    await withDependencies {
      $0.continuousClock = clock
    } operation: {
      let model = TranscriptPageModel(editPlan: plan)
      model.sensitivityDragChanged(80)  // schedules a debounced commit of 80
      model.sensitivityChanged(10)  // immediate set to 10 must cancel the pending 80
      expectNoDifference(model.runTogetherMaxGapMs, 10)
      await clock.advance(by: .milliseconds(200))  // the stale 80 commit must not fire
      expectNoDifference(model.runTogetherMaxGapMs, 10)
    }
  }
}
