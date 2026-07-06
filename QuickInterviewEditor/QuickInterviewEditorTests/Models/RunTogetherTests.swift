import CustomDump
import Testing

@testable import QuickInterviewEditor

struct RunTogetherTests {
  @Test func defaultThresholdFlagsKnownFusedPairs() {
    let words = Fixtures.editPlan().words
    let red = runTogetherWordIDs(words, maxGapMs: 30)
    // "want"(id) -> "to" is a known 20ms fused pair; find that pair by text.
    let idx = words.firstIndex { $0.text == "want" }!
    #expect(red.contains(words[idx].id))
    #expect(red.contains(words[idx + 1].id))  // "to"
  }

  @Test func sensitivityChangesCount() {
    let words = Fixtures.editPlan().words
    let tight = runTogetherWordIDs(words, maxGapMs: 10)
    let mid = runTogetherWordIDs(words, maxGapMs: 30)
    let loose = runTogetherWordIDs(words, maxGapMs: 80)
    #expect(tight.count < mid.count)
    #expect(mid.count < loose.count)
  }

  @Test func displayRolePrioritisesSelectedThenRunTogether() {
    let selected = WordViewState(
      id: 1, text: "a", startSample: 0, endSample: 1,
      isSelected: true, isRunTogether: true)
    let runTogether = WordViewState(
      id: 2, text: "b", startSample: 0, endSample: 1,
      isSelected: false, isRunTogether: true)
    let normal = WordViewState(
      id: 3, text: "c", startSample: 0, endSample: 1,
      isSelected: false, isRunTogether: false)
    #expect(selected.displayRole == .selected)
    #expect(runTogether.displayRole == .runTogether)
    #expect(normal.displayRole == .normal)
  }
}
