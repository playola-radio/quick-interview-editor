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
}
