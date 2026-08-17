import CustomDump
import Dependencies
import Testing

@testable import QuickInterviewEditor

@MainActor
struct UpdaterCommandsModelTests {

  @Test func checkForUpdatesTappedInvokesClient() {
    let called = LockIsolated(false)
    let model = withDependencies {
      $0.updater = UpdaterClient(
        start: {},
        checkForUpdates: { called.setValue(true) },
        canCheckForUpdates: { true })
    } operation: {
      UpdaterCommandsModel()
    }

    model.checkForUpdatesTapped()
    expectNoDifference(called.value, true)
  }

  @Test func labelIsUserFacing() {
    let model = withDependencies {
      $0.updater = .testValue
    } operation: {
      UpdaterCommandsModel()
    }
    expectNoDifference(model.checkForUpdatesLabel, "Check for Updates…")
  }

  @Test func canCheckReflectsClient() {
    let model = withDependencies {
      $0.updater = UpdaterClient(
        start: {}, checkForUpdates: {}, canCheckForUpdates: { false })
    } operation: {
      UpdaterCommandsModel()
    }
    expectNoDifference(model.canCheckForUpdates, false)
  }
}
