import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct SmokeTests {
  @Test func viewModelIdentityEquality() {
    let first = ViewModel()
    let second = ViewModel()
    #expect(first == first)
    #expect(first != second)
  }
}
