import CustomDump
import Dependencies
import Foundation
import IssueReporting
import Testing

@testable import PlayolaInterviewEditor

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
    var got: TranscriptionResult?
    for try await event in EngineClient.previewValue.transcribe(URL(fileURLWithPath: "/x")) {
      if case .completed(let result) = event { got = result }
    }
    expectNoDifference(got?.editPlan.words.count, 122)
    #expect(got?.canonicalAudioURL != nil)
  }

  @Test func testValueInjectMarkersFailsCleanlyWithoutOverride() async {
    await withKnownIssue {
      try await EngineClient.testValue.injectMarkers([])
    }
  }

  @Test func previewValueInjectMarkersFinishesWithoutThrowing() async throws {
    try await EngineClient.previewValue.injectMarkers([])
  }
}

private final class EngineClientBundleToken {}
