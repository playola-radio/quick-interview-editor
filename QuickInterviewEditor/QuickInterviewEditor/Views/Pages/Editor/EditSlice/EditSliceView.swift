import SwiftUI

/// The slice-detail sheet: the scoped transcript, an edge-to-edge overview waveform, the two
/// magnified boundary insets (reusing ``BoundaryInset``), a transport row, and Cancel/Save.
/// Pure visuals — every value and gesture is forwarded to `model`, which owns all geometry
/// and state.
struct EditSliceView: View {
  let model: EditSliceModel

  var body: some View {
    VStack(spacing: 12) {
      Text(model.title).font(.headline)

      TranscriptPageView(model: model.transcript)
        .frame(minHeight: 160)

      Divider()

      SliceOverviewWaveform(model: model)
        .frame(height: 120)

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
    .frame(minWidth: 720, minHeight: 560)
  }
}

/// The edge-to-edge overview waveform for the whole slice: reuses ``InsetSilhouette`` (no
/// kept/discarded tint — the whole span is "kept" from this zoomed-out view), the live draft
/// Cut-in/Cut-out lines, a playhead line, and a tap-to-seek gesture. The view owns only pixels:
/// it multiplies the model's 0...1 fractions by its width and normalizes a tap back to a fraction.
/// Every sample↔position decision lives on `model`.
private struct SliceOverviewWaveform: View {
  let model: EditSliceModel

  private let waveColor = Color(white: 0.42)
  private let playheadColor = Color(red: 0.96, green: 0.86, blue: 0.4)
  private let cutLineColor = Color(white: 0.9)

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      ZStack(alignment: .leading) {
        Color(white: 0.03)
        InsetSilhouette(
          columns: model.overviewColumns(pixelWidth: width), keptSpan: nil,
          waveColor: waveColor, keptColor: waveColor)
        if let fraction = model.overviewCutInFraction {
          cutLine(width: width, fraction: fraction)
        }
        if let fraction = model.overviewCutOutFraction {
          cutLine(width: width, fraction: fraction)
        }
        if let fraction = model.overviewPlayheadFraction {
          let playheadWidth: CGFloat = 1.5
          Rectangle().fill(playheadColor).frame(width: playheadWidth)
            .offset(x: lineOffset(width: width, fraction: fraction, lineWidth: playheadWidth))
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
          .onEnded { value in
            let fraction = width > 0 ? Double(value.location.x) / Double(width) : 0
            let sample = model.overviewSeekSample(atFraction: fraction)
            Task { await model.seekTapped(toSample: sample) }
          }
      )
    }
  }

  private func cutLine(width: CGFloat, fraction: Double) -> some View {
    let lineWidth: CGFloat = 1
    return Rectangle().fill(cutLineColor).frame(width: lineWidth)
      .offset(x: lineOffset(width: width, fraction: fraction, lineWidth: lineWidth))
  }

  /// Keeps a boundary/playhead line fully inside the clipped overview: a `fraction` of 1 would
  /// otherwise land the line at `x == width`, just past the trailing clip edge, hiding it. Clamps
  /// the offset to `[0, width - lineWidth]` so the endpoint lines stay flush against the edge.
  private func lineOffset(width: CGFloat, fraction: Double, lineWidth: CGFloat) -> CGFloat {
    min(max(0, width * CGFloat(fraction)), max(0, width - lineWidth))
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
