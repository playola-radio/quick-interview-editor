import CustomDump
import Foundation
import IssueReporting
import Testing

@testable import PlayolaInterviewEditor

struct CutSuggestClientTests {
  private static let request = CutSuggestRequest(
    transcriptUnits: [], diarization: nil, productSpecs: ProductSpec.defaults,
    options: CutSuggestOptions(), transcriptHash: "sha256:x", sourceFingerprint: "fp",
    sampleRate: 44100)

  @Test func testValueFailsCleanlyWithoutOverride() async {
    await withKnownIssue {
      for try await _ in CutSuggestClient.testValue.suggestCuts(Self.request, nil) {}
    }
  }

  @Test func previewValueEmitsProgressThenEmptyCompletion() async throws {
    var events: [CutSuggestEvent] = []
    for try await event in CutSuggestClient.previewValue.suggestCuts(Self.request, nil) {
      events.append(event)
    }
    expectNoDifference(events, [.progress("Analyzing transcript…"), .completed([])])
  }
}
