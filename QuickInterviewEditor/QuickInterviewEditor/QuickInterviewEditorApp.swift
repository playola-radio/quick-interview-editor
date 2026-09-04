import SwiftUI

@main
struct QuickInterviewEditorApp: App {
  @State private var model = AppLaunchModel()
  @State private var settings = SettingsModel()
  @State private var clipSettings = ClipBoundarySettingsModel()

  var body: some Scene {
    WindowGroup {
      AppLaunchView(model: model)
        .preferredColorScheme(.dark)
    }
    .defaultSize(width: 1200, height: 800)
    .commands {
      TranscriptionCommands(root: model.root)
      UpdaterCommands()
    }

    Settings {
      TabView {
        SettingsView(model: settings)
          .tabItem { Label("Cut Suggestions", systemImage: "scissors") }
        ClipBoundarySettingsView(model: clipSettings)
          .tabItem { Label("Editing", systemImage: "slider.horizontal.3") }
      }
      .preferredColorScheme(.dark)
    }
  }
}
