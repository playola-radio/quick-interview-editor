import CustomDump
import Dependencies
import Testing

@testable import PlayolaInterviewEditor

struct AudioOutputClientTests {

  @Test func testValueCurrentIsOverridable() {
    let device = OutputDevice(id: 7, uid: "uid-x", name: "Test Buds")
    withDependencies {
      $0.audioOutput = AudioOutputClient(
        current: { device }, changes: { AsyncStream { $0.finish() } })
    } operation: {
      @Dependency(\.audioOutput) var audioOutput
      expectNoDifference(audioOutput.current(), device)
    }
  }

  @Test func testValueCurrentReportsIssueWithoutOverride() {
    withKnownIssue {
      _ = AudioOutputClient.testValue.current()
    }
  }

  @Test func previewValueCurrentReturnsBuiltInOutput() {
    expectNoDifference(
      AudioOutputClient.previewValue.current(),
      OutputDevice(id: 0, uid: "preview", name: "Built-in Output"))
  }

  @Test func previewValueChangesFinishesImmediately() async {
    var count = 0
    for await _ in AudioOutputClient.previewValue.changes() {
      count += 1
    }
    expectNoDifference(count, 0)
  }
}
