import AppKit
import SwiftUI

/// Drops the plain File ▸ Save (⌘S) command `DocumentGroup` installs, which deadlocks the main
/// thread against autosave-in-place (see `SaveMenuSurgery`). Autosave already persists everything.
///
/// SwiftUI owns the menu and can (re)install the Save item after launch — a new document window, a
/// command-group rebuild — so removing it once is not enough: if it comes back the hang comes back.
/// We prune the current menu at launch and then keep pruning for the app's lifetime by observing
/// `NSMenu.didAddItemNotification`, so any Save item is gone before ⌘S can ever reach it.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // The global menu observer below strips Save from *any* menu that gains one, which in the unit
    // test host would tear down the hand-built menus `SaveMenuSurgeryTests` asserts against. Menu
    // surgery is real-app behavior; the test host has no business running it.
    guard !isRunningUnitTests else { return }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(menuDidAddItem(_:)),
      name: NSMenu.didAddItemNotification,
      object: nil)
    removePlainSave()
  }

  private var isRunningUnitTests: Bool {
    NSClassFromString("XCTestCase") != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  @objc private func menuDidAddItem(_ note: Notification) {
    guard let menu = note.object as? NSMenu else { return }
    SaveMenuSurgery.removePlainSave(from: menu)
  }

  private func removePlainSave() {
    // `NSApplicationDelegate` callbacks are nonisolated on the CI SDK (Xcode 16.4), but `NSApp` and
    // `mainMenu` are main-actor-isolated; these callbacks and the menu notification always fire on
    // the main thread, so assert that rather than let strict concurrency reject the build.
    MainActor.assumeIsolated {
      guard let menu = NSApp.mainMenu else { return }
      SaveMenuSurgery.removePlainSave(from: menu)
    }
  }
}

@main
struct QuickInterviewEditorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var launch = AppLaunchModel()
  @State private var settings = SettingsModel()
  @State private var suggestionSettings = SuggestionSettingsModel(isSettingsTab: true)
  @State private var clipSettings = ClipBoundarySettingsModel()

  var body: some Scene {
    DocumentGroup(
      newDocument: { ProjectDocument() },
      editor: { configuration in
        ProjectHostView(document: configuration.document, fileURL: configuration.fileURL)
          // One model per document instance: a Revert/Duplicate that swaps the document
          // object rebuilds the host rather than reusing a model bound to the old one.
          .id(ObjectIdentifier(configuration.document))
          .environment(launch)
          .environment(suggestionSettings)
          .preferredColorScheme(.dark)
      }
    )
    .defaultSize(width: 1200, height: 800)
    .commands {
      EditUndoCommands()
      TranscriptionCommands()
      UpdaterCommands()
    }

    Settings {
      TabView {
        SettingsView(model: settings)
          .tabItem { Label("Cut Suggestions", systemImage: "scissors") }
        SuggestionSettingsView(model: suggestionSettings)
          .tabItem { Label(suggestionSettings.title, systemImage: "list.bullet.rectangle") }
        ClipBoundarySettingsView(model: clipSettings)
          .tabItem { Label("Editing", systemImage: "slider.horizontal.3") }
      }
      .preferredColorScheme(.dark)
    }
  }
}
