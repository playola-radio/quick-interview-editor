import Dependencies
import Observation

@MainActor
@Observable
final class UpdaterCommandsModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.updater) var updater

  // MARK: - View Helpers
  var checkForUpdatesLabel: String { "Check for Updates…" }
  var canCheckForUpdates: Bool { updater.canCheckForUpdates() }

  // MARK: - User Actions
  func checkForUpdatesTapped() { updater.checkForUpdates() }
}
