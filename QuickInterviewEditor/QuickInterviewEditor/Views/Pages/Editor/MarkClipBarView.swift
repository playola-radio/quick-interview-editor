import SwiftUI

/// The persistent controls for the listen/select/mark flow: always on screen (never popping in
/// and reflowing), the "Mark as Clip" button enabled only when words are selected, plus a
/// jump-back-to-the-playhead button. It sits where the fine-tune pane used to appear.
struct MarkClipBarView: View {
  @Bindable var model: EditorModel

  var body: some View {
    HStack(spacing: 12) {
      Button(model.markAsClipLabel) { model.addSliceTapped() }
        .disabled(!model.canAddSlice)

      Text(model.transcript.selectionSummary)
        .font(.system(size: 12))
        .foregroundStyle(Color(white: 0.5))
        .lineLimit(1)

      Spacer()

      Button {
        model.scrollToCurrentWordTapped()
      } label: {
        Label(model.scrollToCurrentWordLabel, systemImage: "scope")
      }
      .labelStyle(.iconOnly)
      .disabled(!model.canScrollToCurrentWord)
      .help(model.scrollToCurrentWordLabel)
      .accessibilityLabel(model.scrollToCurrentWordLabel)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }
}
