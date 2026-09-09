import AppKit

/// Removes the plain File ▸ Save (⌘S) command that `DocumentGroup` installs.
///
/// Pressing ⌘S runs `NSDocument.saveDocument(_:)`, which enters
/// `performActivityWithSynchronousWaiting:` and blocks the main thread until the document's
/// activity queue drains. With autosave-in-place active an autosave activity is almost always
/// outstanding, and its completion has to get back through the very main run loop that Save has
/// frozen — a deadlock (HANG REPORT 2026-09-09: the app hung 33s+ the moment ⌘S was pressed).
/// Autosave already persists every change (the window's "Saving…/Saved" indicator reflects it),
/// so plain Save is redundant. Duplicate, Save As…, Revert to Saved, and Close stay in place and
/// fully native — only the one deadlocking command is removed.
enum SaveMenuSurgery {

  /// Recursively removes every `saveDocument:` item from `menu` and its submenus, taking its ⌘S
  /// equivalent with it. Returns the number of items removed so callers can log the result.
  /// Idempotent: a menu that has already been operated on returns `0`.
  ///
  /// `NSDocument.save(_:)` is the Swift name for the `saveDocument:` action selector.
  @discardableResult
  static func removePlainSave(from menu: NSMenu) -> Int {
    var removed = 0
    for item in menu.items {
      if item.action == #selector(NSDocument.save(_:)) {
        menu.removeItem(item)
        removed += 1
      } else if let submenu = item.submenu {
        removed += removePlainSave(from: submenu)
      }
    }
    return removed
  }
}
