import Dependencies
import Foundation
import IssueReporting
import Testing

@testable import QuickInterviewEditor

struct AudioPlayerClientTests {
  @Test func testValuePlayFailsCleanlyWithoutOverride() async {
    await withKnownIssue {
      try await AudioPlayerClient.testValue.play(URL(fileURLWithPath: "/x"), 0..<10, 44100)
    }
  }

  @Test func previewValuePlayIsANoOp() async throws {
    try await AudioPlayerClient.previewValue.play(URL(fileURLWithPath: "/x"), 0..<10, 44100)
    await AudioPlayerClient.previewValue.stop()
  }
}
