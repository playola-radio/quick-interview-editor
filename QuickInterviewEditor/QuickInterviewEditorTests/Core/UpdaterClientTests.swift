import CustomDump
import Dependencies
import Testing

@testable import QuickInterviewEditor

/// The live `UpdaterClient` drives Sparkle and can't run in tests; these lock in
/// that the `testValue` is a safe no-op models can exercise without Sparkle.
@MainActor
struct UpdaterClientTests {

  @Test func testValueIsSafeNoOp() {
    let client = UpdaterClient.testValue
    client.start()  // must not crash
    client.checkForUpdates()  // must not crash
    expectNoDifference(client.canCheckForUpdates(), true)
  }
}
