import CustomDump
import Foundation
import IssueReporting
import Testing

@testable import QuickInterviewEditor

struct CutSuggestClientTests {
  private static let request = CutSuggestRequest(
    transcriptUnits: [], diarization: nil, productSpecs: ProductSpec.defaults,
    options: CutSuggestOptions(), transcriptHash: "sha256:x", sourceFingerprint: "fp")

  @Test func liveValueReportsMissingImplementationAndFinishesWithError() async {
    // No live impl until PR 5: it reports an issue and the stream throws `unimplemented`.
    await withKnownIssue {
      for try await _ in CutSuggestClient.liveValue.suggestCuts(Self.request) {}
    }
  }

  @Test func testValueFailsCleanlyWithoutOverride() async {
    await withKnownIssue {
      for try await _ in CutSuggestClient.testValue.suggestCuts(Self.request) {}
    }
  }

  @Test func previewValueEmitsProgressThenEmptyCompletion() async throws {
    var events: [CutSuggestEvent] = []
    for try await event in CutSuggestClient.previewValue.suggestCuts(Self.request) {
      events.append(event)
    }
    expectNoDifference(events, [.progress("Analyzing transcript…"), .completed([])])
  }
}
