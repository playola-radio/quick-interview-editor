import CustomDump
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
}
