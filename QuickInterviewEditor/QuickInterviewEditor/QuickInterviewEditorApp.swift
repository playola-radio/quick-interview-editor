import SwiftUI

@main
struct QuickInterviewEditorApp: App {
  @State private var model = AppLaunchModel()

  var body: some Scene {
    WindowGroup {
      AppLaunchView(model: model)
        .preferredColorScheme(.dark)
    }
  }
}
