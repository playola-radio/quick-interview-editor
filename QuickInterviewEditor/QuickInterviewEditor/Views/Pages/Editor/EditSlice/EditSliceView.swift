import SwiftUI

/// The slice-detail sheet: the scoped transcript, the full ``WaveformLaneView`` (same ruler / zoom /
/// scroll / seek as the main editor, scoped to this slice), the two magnified boundary insets
/// (reusing ``BoundaryInset``), a transport row, and Cancel/Save. Pure visuals — every value and
/// gesture is forwarded to `model`, which owns all geometry and state.
struct EditSliceView: View {
  let model: EditSliceModel

  var body: some View {
    VStack(spacing: 12) {
      Text(model.title).font(.headline)

      TranscriptPageView(model: model.transcript)
        .frame(minHeight: 160, maxHeight: .infinity)

      Divider()

      SliceWaveformLane(model: model)

      FineTuneInsets(model: model)

      HStack(spacing: 8) {
        Button {
          Task { await model.playPauseTapped() }
        } label: {
          Image(systemName: model.playButtonSystemImage)
        }
        .help(model.playPauseLabel)
        Button(model.stopLabel) { Task { await model.stopTapped() } }
        Spacer()
        Button(model.cancelLabel) { model.cancelTapped() }
        Button(model.saveLabel) { model.saveTapped() }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canSave)
      }
    }
    .padding()
    .presentationSizing(.fitted)
    .frame(
      minWidth: 1040, idealWidth: 1140, maxWidth: .infinity,
      minHeight: 680, idealHeight: 800, maxHeight: .infinity
    )
    // ⌘← / ⌘→ step-zoom and Z zoom-to-fit, scoped to this sheet's lane (the main editor's monitor
    // stands down because its window isn't key while the sheet is up).
    .background(SliceEditKeyMonitor(model: model))
  }
}

/// The slice's waveform lane: the same reusable ``WaveformLaneView`` the main editor mounts, wired
/// for navigation only. Ruler/body clicks seek the cursor; the draft kept range is the highlight
/// band. Marquee area-select is intentionally inert here — boundary editing is the fine-tune insets'
/// job, so a lane selection would have no meaning (a deliberate divergence from the main editor).
private struct SliceWaveformLane: View {
  let model: EditSliceModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      zoomHeader
      WaveformLaneView(
        waveform: model.waveform,
        playhead: { model.playheadSample },
        highlightRange: model.waveformHighlightRange,
        onRulerMove: { positionX in Task { await model.waveformSeeked(toX: positionX) } },
        onBodyClick: { positionX, _ in Task { await model.waveformSeeked(toX: positionX) } },
        onAreaSelectBegan: { _, _ in },
        onAreaSelectChanged: { _ in },
        onAreaSelectEnded: { _ in },
        auditionOverlay: { _ in EmptyView() }
      )
    }
  }

  private var zoomHeader: some View {
    HStack(spacing: 8) {
      Spacer()
      Button {
        model.zoomOutTapped()
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .disabled(!model.canZoomOut)
      .help(model.zoomOutLabel)
      Button {
        model.zoomInTapped()
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .disabled(!model.canZoomIn)
      .help(model.zoomInLabel)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(Color(white: 0.6))
  }
}

/// The two magnified boundary insets ("Cut in" / "Cut out"), wired to `model` exactly as
/// ``FineTuneView`` wires the same ``BoundaryInset`` to `EditorModel`.
private struct FineTuneInsets: View {
  let model: EditSliceModel

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      BoundaryInset(
        label: model.fineTune.cutInLabel, timeLabel: model.fineTune.cutInTimeLabel,
        width: model.fineTune.insetWidthPixels, columns: model.cutInColumns(),
        safeZones: model.fineTune.cutInSafeZones, keptSpan: model.fineTune.cutInKeptSpan,
        discardedSpan: model.fineTune.cutInDiscardedSpan, lineX: model.fineTune.cutInLineX,
        isTight: model.fineTune.isCutInTight, nudgeBackLabel: model.fineTune.nudgeBackLabel,
        nudgeForwardLabel: model.fineTune.nudgeForwardLabel,
        onNudgeBack: { model.cutInNudgedBack() },
        onNudgeForward: { model.cutInNudgedForward() },
        onDrag: { model.cutInDragged(toInsetX: $0) })
      BoundaryInset(
        label: model.fineTune.cutOutLabel, timeLabel: model.fineTune.cutOutTimeLabel,
        width: model.fineTune.insetWidthPixels, columns: model.cutOutColumns(),
        safeZones: model.fineTune.cutOutSafeZones, keptSpan: model.fineTune.cutOutKeptSpan,
        discardedSpan: model.fineTune.cutOutDiscardedSpan, lineX: model.fineTune.cutOutLineX,
        isTight: model.fineTune.isCutOutTight, nudgeBackLabel: model.fineTune.nudgeBackLabel,
        nudgeForwardLabel: model.fineTune.nudgeForwardLabel,
        onNudgeBack: { model.cutOutNudgedBack() },
        onNudgeForward: { model.cutOutNudgedForward() },
        onDrag: { model.cutOutDragged(toInsetX: $0) })
      Spacer(minLength: 0)
    }
  }
}
