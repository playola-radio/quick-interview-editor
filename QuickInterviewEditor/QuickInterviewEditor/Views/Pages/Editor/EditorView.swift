import SwiftUI

struct EditorView: View {
  @Bindable var model: EditorModel

  var body: some View {
    HStack(spacing: 0) {
      TranscriptPageView(model: model.transcript)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      SlicesPanelView(model: model)
        .frame(width: 302)
    }
    .background(Color.black)
  }
}
