import CustomDump
import Foundation
import Testing
@testable import QuickInterviewEditor

struct EngineClientTests {
  @Test func liveValueDecodesFromURL() async throws {
    let url = Bundle(for: EngineClientBundleToken.self)
      .url(forResource: "edit-plan", withExtension: "json")!
    let plan = try await EngineClient.liveValue.loadPlan(url)
    expectNoDifference(plan.words.count, 122)
  }
}

private final class EngineClientBundleToken {}
