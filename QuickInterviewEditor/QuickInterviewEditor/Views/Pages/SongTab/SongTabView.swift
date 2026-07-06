import SwiftUI

struct SongTabView: View {
  @Bindable var model: SongTabModel
  var onCancel: () -> Void

  var body: some View {
    switch model.phase {
    case .queued, .transcribing:
      VStack(spacing: 14) {
        ProgressView()
        Text(model.progressMessage).foregroundStyle(Color(white: 0.7))
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
