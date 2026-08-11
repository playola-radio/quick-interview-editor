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
    #expect(LiveEngine.sanitizedFraction(0.4) == 0.4)
    #expect(LiveEngine.sanitizedFraction(-1) == 0)
    #expect(LiveEngine.sanitizedFraction(2) == 1)
    #expect(LiveEngine.sanitizedFraction(.nan) == nil)
    #expect(LiveEngine.sanitizedFraction(.infinity) == nil)
    #expect(LiveEngine.sanitizedFraction(nil) == nil)
  }
}
