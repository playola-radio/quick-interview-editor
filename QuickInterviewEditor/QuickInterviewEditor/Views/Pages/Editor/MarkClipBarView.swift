import SwiftUI

/// The persistent selection controls for the listen/select/mark flow: always on screen (never
/// popping in and reflowing), sitting right under the transcript. "Mark as Clip" and "Clear" act
/// on the current selection (both enabled only when there is one); a jump-back-to-the-playhead
/// button sits on the trailing edge.
struct MarkClipBarView: View {
  @Bindable var model: EditorModel

  var body: some View {
    HStack(spacing: 12) {
      Button(model.markAsClipLabel) { model.addSliceTapped() }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(!model.canAddSlice)

      Button(model.openSelectionLabel) { model.openSelectionTapped() }
        .disabled(!model.canOpenSelection)

      Button(model.clearButtonLabel) { model.clearSelectionTapped() }
        .disabled(!model.canClearSelection)

      if model.shouldShowSelectedClipControls {
        Button(model.playLabel) { Task { await model.playSelectedClipTapped() } }
      }

      if model.shouldShowSelectedSuggestionControls {
        Button(model.cutSuggestions.acceptLabel) { model.acceptSelectedSuggestionTapped() }
          .disabled(model.isExporting)
        Button(model.cutSuggestions.rejectLabel) { model.rejectSelectedSuggestionTapped() }
          .disabled(model.isExporting)
      }

      if model.shouldShowRemoveSectionControl {
        Button(model.removeSectionLabel) { Task { await model.removeSelectedSectionTapped() } }
          .disabled(!model.canRemoveSelectedSection)
      }

      if model.shouldShowRestoreControl {
        Button(model.restoreRemovedAudioLabel) { model.restoreRemovalTapped() }
          .disabled(!model.canRestoreSelectedRemoval)
      }

      if let message = model.clipEditorMessage {
        Text(message).foregroundStyle(.red)
      }

      Text(model.selectionSummary)
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
