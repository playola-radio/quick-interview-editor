import AppKit
import CustomDump
import Testing

@testable import PlayolaInterviewEditor

/// `SaveMenuSurgery` removes the plain File ▸ Save (⌘S) command `DocumentGroup` installs, because
/// pressing it deadlocks the main thread against autosave-in-place (HANG REPORT 2026-09-09). These
/// exercise the pure menu edit against a hand-built File menu — no live `NSDocument`/`NSWindow` —
/// mirroring `DocumentDefaultNameTests`.
@MainActor
struct SaveMenuSurgeryTests {

  private func fileMenu() -> NSMenu {
    let menu = NSMenu(title: "File")
    let items: [NSMenuItem] = [
      NSMenuItem(
        title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
      NSMenuItem(
        title: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s"),
      NSMenuItem(
        title: "Duplicate", action: #selector(NSDocument.duplicate(_:)), keyEquivalent: "S"),
      NSMenuItem(
        title: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: ""),
      NSMenuItem(
        title: "Revert to Saved", action: #selector(NSDocument.revertToSaved(_:)),
        keyEquivalent: ""),
    ]
    for item in items { menu.addItem(item) }
    return menu
  }

  private func hasSave(_ menu: NSMenu) -> Bool {
    menu.items.contains { $0.action == #selector(NSDocument.save(_:)) }
  }

  @Test func removesOnlyPlainSaveKeepingDuplicateSaveAsRevertClose() {
    let file = fileMenu()

    expectNoDifference(SaveMenuSurgery.removePlainSave(from: file), 1)

    #expect(!hasSave(file))
    #expect(file.items.contains { $0.action == #selector(NSDocument.duplicate(_:)) })
    #expect(file.items.contains { $0.action == #selector(NSDocument.saveAs(_:)) })
    #expect(file.items.contains { $0.action == #selector(NSDocument.revertToSaved(_:)) })
    #expect(file.items.contains { $0.action == #selector(NSWindow.performClose(_:)) })
  }

  @Test func recursesIntoSubmenusSoTheMainMenuTreeIsCovered() {
    let main = NSMenu(title: "MainMenu")
    let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    fileItem.submenu = fileMenu()
    main.addItem(fileItem)

    expectNoDifference(SaveMenuSurgery.removePlainSave(from: main), 1)
    #expect(!hasSave(fileItem.submenu!))
  }

  @Test func isIdempotent() {
    let file = fileMenu()
    expectNoDifference(SaveMenuSurgery.removePlainSave(from: file), 1)
    expectNoDifference(SaveMenuSurgery.removePlainSave(from: file), 0)
  }

  /// The whole fix rides on matching AppKit's plain-Save action. If `NSDocument.save(_:)` ever
  /// stopped bridging to `saveDocument:`, the surgery would silently match nothing and the hang
  /// would return. Lock the selector identity so that regression fails a test, not a user.
  @Test func plainSaveSelectorIsSaveDocument() {
    expectNoDifference(NSStringFromSelector(#selector(NSDocument.save(_:))), "saveDocument:")
  }
}
