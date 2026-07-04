import Testing
@testable import QuickInterviewEditor

@MainActor
struct SmokeTests {
  @Test func viewModelIdentityEquality() {
    let a = ViewModel()
    let b = ViewModel()
    #expect(a == a)
    #expect(a != b)
  }
}
