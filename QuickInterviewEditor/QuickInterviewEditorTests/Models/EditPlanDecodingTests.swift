import CustomDump
import Testing

@testable import QuickInterviewEditor

struct EditPlanDecodingTests {
  @Test func decodesRealFixture() {
    let plan = Fixtures.editPlan()
    expectNoDifference(plan.words.count, 122)
    expectNoDifference(plan.silences.count, 25)
    expectNoDifference(plan.source.sampleRate, 44100)
    expectNoDifference(plan.source.channels, 2)
    expectNoDifference(plan.words.first?.text, "So")
    expectNoDifference(plan.words.first?.startSample, 54772)
  }
}
