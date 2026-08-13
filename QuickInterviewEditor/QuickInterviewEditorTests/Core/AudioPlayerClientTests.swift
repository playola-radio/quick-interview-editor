import Dependencies
import Foundation
import IssueReporting
import Testing

@testable import QuickInterviewEditor

struct AudioPlayerClientTests {
  @Test func testValuePlayFailsCleanlyWithoutOverride() async {
    await withKnownIssue {
      _ = try await AudioPlayerClient.testValue.play(
        URL(fileURLWithPath: "/x"), 0..<10, 44100, PlaybackSessionID())
    }
  }

  @Test func previewValuePlayIsANoOp() async throws {
    _ = try await AudioPlayerClient.previewValue.play(
      URL(fileURLWithPath: "/x"), 0..<10, 44100, PlaybackSessionID())
    await AudioPlayerClient.previewValue.stop(nil)
  }
}
