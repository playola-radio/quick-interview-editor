import SwiftUI

@main
struct QuickInterviewEditorApp: App {
  @State private var model = AppLaunchModel()
  @State private var settings = SettingsModel()

  var body: some Scene {
    WindowGroup {
      AppLaunchView(model: model)
        .preferredColorScheme(.dark)
    }
    .defaultSize(width: 1200, height: 800)
    .commands {
      TranscriptionCommands(root: model.root)
    }

    Settings {
      SettingsView(model: settings)
        .preferredColorScheme(.dark)
    }
  }
}
