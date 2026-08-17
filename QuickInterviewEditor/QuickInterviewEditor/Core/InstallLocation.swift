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

  /// First-launch entry point. Returns `true` when it kicked off a move + relaunch
  /// (so the caller knows this process is terminating and should not start the
  /// updater in it). No-op returning `false` in DEBUG/tests so development builds
  /// are never relocated out from under the debugger.
  @MainActor
  static func offerMoveToApplicationsIfNeeded() -> Bool {
    #if DEBUG
      return false
    #else
      let bundleURL = Bundle.main.bundleURL
      guard
        shouldOfferMoveToApplications(
          bundlePath: bundleURL.path,
          isTranslocated: isTranslocated(bundleURL))
      else { return false }
      // If a copy already lives in /Applications, don't nag or clobber it: it may
      // be a newer, older, or currently-running install, and silently swapping it
      // risks discarding the very build the user just launched. Leave it to them.
      guard !FileManager.default.fileExists(atPath: destination(for: bundleURL).path)
      else { return false }
      return presentMoveOffer(from: bundleURL)
    #endif
  }

  private static func destination(for bundleURL: URL) -> URL {
    URL(fileURLWithPath: "/Applications")
      .appendingPathComponent(bundleURL.lastPathComponent)
  }

  /// True when macOS has translocated (path-randomized) the app — Gatekeeper does
  /// this to quarantined apps run in place. Detected by the stable translocation
  /// path marker rather than `SecTranslocateIsTranslocatedURL`, whose Security
  /// submodule isn't reliably importable across our local/CI Xcode toolchains.
  static func isTranslocated(_ url: URL) -> Bool {
    url.path.contains("/AppTranslocation/")
  }

  // MARK: - Side effect (release only)

  /// Returns `true` if a move + relaunch was initiated.
  @MainActor
  private static func presentMoveOffer(from bundleURL: URL) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Move to the Applications folder?"
    alert.informativeText =
      "Quick Interview Editor works best — and can keep itself up to date — when it "
      + "lives in your Applications folder. Would you like to move it there now?"
    alert.addButton(withTitle: "Move to Applications Folder")
    alert.addButton(withTitle: "Not Now")
    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    return moveToApplicationsAndRelaunch(from: bundleURL)
  }

  /// Returns `true` if the copy succeeded and a relaunch was requested (this
  /// process will terminate on success); `false` if the move failed and we stay
  /// running from the current location.
  @MainActor
  private static func moveToApplicationsAndRelaunch(from bundleURL: URL) -> Bool {
    let fileManager = FileManager.default
    let destination = destination(for: bundleURL)

    // Never clobber an existing install (already filtered in the offer, but keep
    // the invariant local): only move into an empty /Applications slot.
    guard !fileManager.fileExists(atPath: destination.path) else { return false }

    // Copy to a hidden staging path on the same volume, then atomically rename it
    // into place. A crash mid-copy can then never leave a half-written bundle at
    // the destination — the rename either fully succeeds or never happens.
    let staging = URL(fileURLWithPath: "/Applications").appendingPathComponent(
      ".\(bundleURL.deletingPathExtension().lastPathComponent)"
        + ".\(ProcessInfo.processInfo.processIdentifier).staging.app")
    do {
      try? fileManager.removeItem(at: staging)
      try fileManager.copyItem(at: bundleURL, to: staging)
      try fileManager.moveItem(at: staging, to: destination)
    } catch {
      NSLog("InstallLocation: move to /Applications failed: \(error)")
      try? fileManager.removeItem(at: staging)
      // Tell the user rather than failing silently: /Applications may not be
      // writable (e.g. a non-admin account). They can still drag it over by hand.
      presentMoveFailed()
      return false  // Stay running from the current location; nothing destructive done.
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: destination, configuration: configuration) {
      _, error in
      // Only quit this instance once the relocated copy has actually launched —
      // otherwise a failed relaunch would leave the user with no running app.
      guard error == nil else {
        NSLog(
          "InstallLocation: relaunch from /Applications failed: \(String(describing: error))")
        return
      }
      Task { @MainActor in NSApp.terminate(nil) }
    }
    return true
  }

  @MainActor
  private static func presentMoveFailed() {
    let alert = NSAlert()
    alert.messageText = "Couldn't move to the Applications folder"
    alert.informativeText =
      "You can move Quick Interview Editor yourself by dragging it into "
      + "Applications in Finder. Auto-update works best once it lives there."
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
