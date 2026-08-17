import Dependencies
import Foundation
import Sparkle

/// Wraps Sparkle's updater so the app's models can trigger an update check and
/// reflect its availability without importing Sparkle or holding a non-Sendable
/// controller. The live path drives `SPUStandardUpdaterController`; tests get
/// no-ops, so Sparkle never runs in the test suite.
struct UpdaterClient: Sendable {
  /// Explicitly create/start Sparkle's controller. Called once at launch (after
  /// the relocation guard) so background checks don't hinge on SwiftUI evaluating
  /// the menu, and never start before the app has decided where it lives.
  var start: @MainActor @Sendable () -> Void
  var checkForUpdates: @MainActor @Sendable () -> Void
  var canCheckForUpdates: @MainActor @Sendable () -> Bool
}

extension UpdaterClient: DependencyKey {
  static var liveValue: UpdaterClient {
    // The singleton is touched only inside these @MainActor closures, so the
    // nonisolated `liveValue` accessor stays concurrency-clean and Sparkle's
    // main-thread controller is never created off the main actor.
    UpdaterClient(
      start: { _ = LiveUpdaterHolder.shared },
      checkForUpdates: { LiveUpdaterHolder.shared.controller.updater.checkForUpdates() },
      canCheckForUpdates: { LiveUpdaterHolder.shared.controller.updater.canCheckForUpdates }
    )
  }
}

extension UpdaterClient: TestDependencyKey {
  static var testValue: UpdaterClient {
    UpdaterClient(start: {}, checkForUpdates: {}, canCheckForUpdates: { true })
  }
  static var previewValue: UpdaterClient { testValue }
}

extension DependencyValues {
  var updater: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}

/// Owns the single Sparkle controller for the app's lifetime. `startingUpdater:
/// true` begins scheduled background checks immediately on first live use.
@MainActor
final class LiveUpdaterHolder {
  static let shared = LiveUpdaterHolder()
  let controller = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  private init() {}
}
