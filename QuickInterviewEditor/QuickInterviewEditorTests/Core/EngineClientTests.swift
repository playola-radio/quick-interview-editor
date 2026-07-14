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
    var got: TranscriptionResult?
    for try await event in EngineClient.previewValue.transcribe(URL(fileURLWithPath: "/x")) {
      if case .completed(let result) = event { got = result }
    }
    expectNoDifference(got?.editPlan.words.count, 122)
    #expect(got?.canonicalAudioURL != nil)
  }

  @Test func testValueRenderSlicesFailsCleanlyWithoutOverride() async {
    await withKnownIssue {
      for try await _ in EngineClient.testValue.renderSlices(Self.sampleRequest) {}
    }
  }

  @Test func previewValueRenderSlicesFinishesWithoutEmitting() async throws {
    var events = 0
    for try await _ in EngineClient.previewValue.renderSlices(Self.sampleRequest) { events += 1 }
    expectNoDifference(events, 0)
  }

  private static let sampleRequest = RenderRequest(
    audioURL: URL(fileURLWithPath: "/clip.m4a"),
    sampleRate: 44100,
    markers: [RenderMarker(position: 0, name: "So")],
    slices: [RenderSliceSpec(id: UUID(), startSample: 0, endSample: 100)]
  )
}

private final class EngineClientBundleToken {}
