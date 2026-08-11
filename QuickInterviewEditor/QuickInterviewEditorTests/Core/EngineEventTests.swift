import CustomDump
import Testing

@testable import QuickInterviewEditor

struct EngineEventTests {
  @Test func phaseDecodesFromEngineRawValue() {
    #expect(EngineProgress.Phase(rawValue: "analyzing_silence") == .analyzingSilence)
    #expect(EngineProgress.Phase(rawValue: "writing_plan") == .writingPlan)
    #expect(EngineProgress.Phase(rawValue: "transcribing") == .transcribing)
  }

  @Test func errorHasUserFacingDescription() {
    let error = EngineClientError.engineFailed("boom")
    #expect(error.errorDescription?.contains("boom") == true)
  }

  @Test func sanitizedFractionClampsAndDropsJunk() {
    expectNoDifference(LiveEngine.sanitizedFraction(0.4), 0.4)
    expectNoDifference(LiveEngine.sanitizedFraction(-1), 0)
    expectNoDifference(LiveEngine.sanitizedFraction(2), 1)
    expectNoDifference(LiveEngine.sanitizedFraction(.nan), nil)
    expectNoDifference(LiveEngine.sanitizedFraction(.infinity), nil)
    expectNoDifference(LiveEngine.sanitizedFraction(nil), nil)
  }
}
