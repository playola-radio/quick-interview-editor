import SwiftUI

@main
struct QuickInterviewEditorApp: App {
  @State private var model = TranscriptPageModel()

  var body: some Scene {
    WindowGroup {
      TranscriptPageView(model: model)
        .preferredColorScheme(.dark)
    }
  }
}
