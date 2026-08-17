import AppKit
import Foundation

/// Decides whether to nudge the user to move the app into /Applications on first
/// launch. Running from the DMG (read-only) or a translocated path breaks
/// self-update and can surface Gatekeeper "damaged app" errors, so we offer to
/// relocate. The decision is pure so it is unit-testable; the actual move is a
/// side-effecting helper below that never runs in DEBUG/tests.
enum InstallLocation {

  /// Pure relocation decision. `bundlePath` is `Bundle.main.bundlePath`;
  /// `isTranslocated` comes from ``isTranslocated(_:)`` at the call site.
  static func shouldOfferMoveToApplications(bundlePath: String, isTranslocated: Bool) -> Bool {
    if isTranslocated { return true }
    let inSystemApps = bundlePath.hasPrefix("/Applications/")
    let inUserApps = bundlePath.hasPrefix("\(NSHomeDirectory())/Applications/")
    return !(inSystemApps || inUserApps)
  }

  /// First-launch entry point. No-op in DEBUG/tests so development builds are
  /// never relocated out from under the debugger.
  @MainActor
  static func offerMoveToApplicationsIfNeeded() {
    #if DEBUG
    return
    #else
    let bundleURL = Bundle.main.bundleURL
    guard
      shouldOfferMoveToApplications(
        bundlePath: bundleURL.path,
        isTranslocated: isTranslocated(bundleURL))
    else { return }
    presentMoveOffer(from: bundleURL)
    #endif
  }

  /// True when macOS has translocated (path-randomized) the app — Gatekeeper does
  /// this to quarantined apps run in place. Detected by the stable translocation
  /// path marker rather than `SecTranslocateIsTranslocatedURL`, whose Security
  /// submodule isn't reliably importable across our local/CI Xcode toolchains.
  static func isTranslocated(_ url: URL) -> Bool {
    url.path.contains("/AppTranslocation/")
  }

  // MARK: - Side effect (release only)

  @MainActor
  private static func presentMoveOffer(from bundleURL: URL) {
    let alert = NSAlert()
    alert.messageText = "Move to the Applications folder?"
    alert.informativeText =
      "Quick Interview Editor works best — and can keep itself up to date — when it "
      + "lives in your Applications folder. Would you like to move it there now?"
    alert.addButton(withTitle: "Move to Applications Folder")
    alert.addButton(withTitle: "Not Now")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    moveToApplicationsAndRelaunch(from: bundleURL)
  }

  @MainActor
  private static func moveToApplicationsAndRelaunch(from bundleURL: URL) {
    let fileManager = FileManager.default
    let destination = URL(fileURLWithPath: "/Applications")
      .appendingPathComponent(bundleURL.lastPathComponent)

    // Never clobber an existing install: if a copy is already in /Applications the
    // user has it installed, so just launch that one and quit this stray instance.
    if !fileManager.fileExists(atPath: destination.path) {
      do {
        try fileManager.copyItem(at: bundleURL, to: destination)
      } catch {
        NSLog("InstallLocation: move to /Applications failed: \(error)")
        return  // Stay running from the current location rather than risk anything.
      }
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: destination, configuration: configuration) {
      _, _ in
    }
    NSApp.terminate(nil)
  }
}
