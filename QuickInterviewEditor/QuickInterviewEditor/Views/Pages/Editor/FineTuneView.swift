import SwiftUI

/// The fine-tune pane: two magnified boundary insets plus preview/save/cancel. Pure visuals —
/// every value and gesture is forwarded to the model, which owns all geometry and state.
struct FineTuneView: View {
  @Bindable var model: EditorModel

  private let cardColor = Color(white: 0.075)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(model.fineTune.helperText)
        .font(.system(size: 11)).foregroundStyle(Color(white: 0.44))
      HStack(alignment: .top, spacing: 14) {
        BoundaryInset(
          label: model.fineTune.cutInLabel, timeLabel: model.fineTune.cutInTimeLabel,
          width: model.fineTune.insetWidthPixels, columns: model.cutInColumns,
          safeZones: model.fineTune.cutInSafeZones, keptSpan: model.fineTune.cutInKeptSpan,
          discardedSpan: model.fineTune.cutInDiscardedSpan, lineX: model.fineTune.cutInLineX,
          playheadX: nil,
          nudgeBackLabel: model.fineTune.nudgeBackLabel,
          nudgeForwardLabel: model.fineTune.nudgeForwardLabel,
          onNudgeBack: { model.cutInNudged(byMs: -model.fineTune.nudgeMs) },
          onNudgeForward: { model.cutInNudged(byMs: model.fineTune.nudgeMs) },
          onDrag: { model.cutInDragged(toInsetX: $0) })
        BoundaryInset(
          label: model.fineTune.cutOutLabel, timeLabel: model.fineTune.cutOutTimeLabel,
          width: model.fineTune.insetWidthPixels, columns: model.cutOutColumns,
          safeZones: model.fineTune.cutOutSafeZones, keptSpan: model.fineTune.cutOutKeptSpan,
          discardedSpan: model.fineTune.cutOutDiscardedSpan, lineX: model.fineTune.cutOutLineX,
          playheadX: nil,
          nudgeBackLabel: model.fineTune.nudgeBackLabel,
          nudgeForwardLabel: model.fineTune.nudgeForwardLabel,
          onNudgeBack: { model.cutOutNudged(byMs: -model.fineTune.nudgeMs) },
          onNudgeForward: { model.cutOutNudged(byMs: model.fineTune.nudgeMs) },
          onDrag: { model.cutOutDragged(toInsetX: $0) })
        Spacer(minLength: 0)
      }
      HStack(spacing: 8) {
        Button(model.previewButtonLabel) { Task { await model.previewToggleTapped() } }
        Spacer()
        Button(model.fineTune.cancelLabel) { model.cancelEditTapped() }
          .disabled(!model.fineTune.hasUnsavedChange)
        Button(model.fineTune.commitLabel) { model.commitEditTapped() }
          .disabled(!model.canCommitEdit)
      }
      .buttonStyle(.borderless)
    }
    .padding(12)
    .background(cardColor)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .padding(.horizontal, 20)
    .padding(.bottom, 12)
  }
}
