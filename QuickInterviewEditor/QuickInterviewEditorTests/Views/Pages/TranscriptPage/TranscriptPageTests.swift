import CustomDump
import Dependencies
import Foundation
import Testing
@testable import QuickInterviewEditor

@MainActor
struct TranscriptPageTests {
  @Test func viewAppearedLoadsWords() async {
    await withDependencies {
      $0.engine.loadPlan = { _ in Fixtures.editPlan() }
    } operation: {
      let model = TranscriptPageModel(planURL: URL(fileURLWithPath: "/unused"))
      await model.viewAppeared()
      expectNoDifference(model.words.count, 122)
      #expect(model.words.first { $0.text == "want" }?.isRunTogether == true)
    }
  }
}
