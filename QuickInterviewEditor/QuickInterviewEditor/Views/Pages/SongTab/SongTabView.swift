import SwiftUI

struct SongTabView: View {
  @Bindable var model: SongTabModel
  var onCancel: () -> Void

  var body: some View {
    switch model.phase {
    case .queued, .transcribing:
      VStack(spacing: 14) {
        if model.isProgressDeterminate {
          ProgressView(value: model.determinateValue)
            .progressViewStyle(.linear)
            .frame(maxWidth: 320)
        } else {
          ProgressView()
        }
        Text(model.progressHeadline).foregroundStyle(Color(white: 0.7))
        Text(model.progressNote)
          .font(.caption)
          .multilineTextAlignment(.center)
          .foregroundStyle(Color(white: 0.5))
          .frame(maxWidth: 320)
        if let eta = model.etaMessage {
          Text(eta).font(.caption).foregroundStyle(Color(white: 0.5))
        }
        if model.showsCancel {
          Button(model.cancelButtonLabel) { onCancel() }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black)
    case .loaded:
      if let editor = model.editor { EditorView(model: editor) }
    case .failed:
      VStack(spacing: 14) {
        Text(model.errorMessage ?? "")
          .foregroundStyle(Color(red: 0.89, green: 0.58, blue: 0.58))
          .multilineTextAlignment(.center)
          .textSelection(.enabled)  // errors are copyable (select + Cmd-C)
          .padding(.horizontal, 24)
        Button(model.retryButtonLabel) { model.retryTapped() }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black)
    }
  }
}
