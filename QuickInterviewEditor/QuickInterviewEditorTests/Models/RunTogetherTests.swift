import CustomDump
import Testing

@testable import QuickInterviewEditor

struct RunTogetherTests {
  @Test func wordGapsComputesKnownFusedPair() {
    let words = Fixtures.editPlan().words
    let gaps = wordGaps(words)
    let idx = words.firstIndex { $0.text == "want" }!
    let gap = gaps.first { $0.leftID == words[idx].id && $0.rightID == words[idx + 1].id }!
    #expect(gap.gapMs < 30)
  }
}
