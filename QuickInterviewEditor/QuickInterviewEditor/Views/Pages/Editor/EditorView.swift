import SwiftUI

struct EditorView: View {
  @Bindable var model: EditorModel

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        TranscriptPageView(model: model.transcript)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        WaveformView(model: model)
      }
      Divider()
      SlicesPanelView(model: model)
        .frame(width: 302)
    }
    .background(Color.black)
    .task { await model.loadWaveform() }
    .task { await model.observePlayback() }
  }
}
