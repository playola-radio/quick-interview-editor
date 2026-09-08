import SwiftUI

@main
struct QuickInterviewEditorApp: App {
  @State private var launch = AppLaunchModel()
  @State private var settings = SettingsModel()
  @State private var suggestionSettings = SuggestionSettingsModel()
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
