import CustomDump
import Testing

@testable import PlayolaInterviewEditor

struct RunTogetherTests {
  @Test func defaultThresholdFlagsKnownFusedPairs() {
    let words = Fixtures.editPlan().words
    let gaps = wordGaps(words)
    let red = runTogetherWordIDs(gaps: gaps, maxGapMs: 30)
    // "want"(id) -> "to" is a known 20ms fused pair; find that pair by text.
    let idx = words.firstIndex { $0.text == "want" }!
    #expect(red.contains(words[idx].id))
    #expect(red.contains(words[idx + 1].id))  // "to"
  }

  @Test func sensitivityChangesCount() {
    let words = Fixtures.editPlan().words
    let gaps = wordGaps(words)
    let tight = runTogetherWordIDs(gaps: gaps, maxGapMs: 10)
    let mid = runTogetherWordIDs(gaps: gaps, maxGapMs: 30)
    let loose = runTogetherWordIDs(gaps: gaps, maxGapMs: 80)
    #expect(tight.count < mid.count)
    #expect(mid.count < loose.count)
  }
}
