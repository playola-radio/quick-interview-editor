import CustomDump
import Dependencies
import Foundation
import IssueReporting
import Testing

@testable import QuickInterviewEditor

struct EngineClientTests {
  @Test func liveValueDecodesFromURL() async throws {
    let url = Bundle(for: EngineClientBundleToken.self)
      .url(forResource: "edit-plan", withExtension: "json")!
    let plan = try await EngineClient.liveValue.loadPlan(url)
    expectNoDifference(plan.words.count, 122)
  }

  @Test func testValueLoadPlanFailsCleanlyWithoutOverride() async {
    await withKnownIssue {
      _ = try await EngineClient.testValue.loadPlan(URL(fileURLWithPath: "/x"))
    }
  }

  @Test func testValueTranscribeFailsCleanlyWithoutOverride() async {
    await withKnownIssue {
      for try await _ in EngineClient.testValue.transcribe(URL(fileURLWithPath: "/x")) {}
    }
  }

  @Test func previewValueYieldsFixture() async throws {
    var got: EditPlan?
    for try await event in EngineClient.previewValue.transcribe(URL(fileURLWithPath: "/x")) {
      if case let .completed(plan) = event { got = plan }
    }
    expectNoDifference(got?.words.count, 122)
  }
}

private final class EngineClientBundleToken {}
