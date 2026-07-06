import SwiftUI

@main
struct QuickInterviewEditorApp: App {
  @State private var model = RootModel()

  var body: some Scene {
    WindowGroup {
      RootView(model: model)
        .preferredColorScheme(.dark)
    }
  }
}
