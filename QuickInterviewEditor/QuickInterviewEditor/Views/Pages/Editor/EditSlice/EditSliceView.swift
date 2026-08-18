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
/// kept/discarded tint — the whole span is "kept" from this zoomed-out view), a playhead line
/// derived from `model.playheadSample`, and a tap-to-seek gesture. All geometry here is plain
/// pixel math over model-owned values; the model owns every decision about samples and time.
private struct SliceOverviewWaveform: View {
  let model: EditSliceModel

  private let waveColor = Color(white: 0.42)
  private let playheadColor = Color(red: 0.96, green: 0.86, blue: 0.4)

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      ZStack(alignment: .leading) {
        Color(white: 0.03)
        InsetSilhouette(
          columns: model.overviewColumns(pixelWidth: width), keptSpan: nil,
          waveColor: waveColor, keptColor: waveColor)
        if let playheadX = playheadX(width: width) {
          Rectangle().fill(playheadColor).frame(width: 1.5).offset(x: playheadX)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
          .onEnded { value in
            let sample = sample(atX: value.location.x, width: width)
            Task { await model.seekTapped(toSample: sample) }
          }
      )
    }
  }

  private func playheadX(width: CGFloat) -> CGFloat? {
    guard let sample = model.playheadSample, model.overviewWindow.contains(sample) else {
      return nil
    }
    let fraction =
      Double(sample - model.overviewWindow.lowerBound) / Double(model.overviewWindow.count)
    return width * CGFloat(fraction)
  }

  private func sample(atX positionX: CGFloat, width: CGFloat) -> Int {
    let clampedX = min(max(positionX, 0), width)
    let fraction = width > 0 ? Double(clampedX) / Double(width) : 0
    return model.overviewWindow.lowerBound + Int(fraction * Double(model.overviewWindow.count))
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
        onNudgeBack: { model.cutInNudged(byMs: -model.fineTune.nudgeMs) },
        onNudgeForward: { model.cutInNudged(byMs: model.fineTune.nudgeMs) },
        onDrag: { model.cutInDragged(toInsetX: $0) })
      BoundaryInset(
        label: model.fineTune.cutOutLabel, timeLabel: model.fineTune.cutOutTimeLabel,
        width: model.fineTune.insetWidthPixels, columns: model.cutOutColumns(),
        safeZones: model.fineTune.cutOutSafeZones, keptSpan: model.fineTune.cutOutKeptSpan,
        discardedSpan: model.fineTune.cutOutDiscardedSpan, lineX: model.fineTune.cutOutLineX,
        isTight: model.fineTune.isCutOutTight, nudgeBackLabel: model.fineTune.nudgeBackLabel,
        nudgeForwardLabel: model.fineTune.nudgeForwardLabel,
        onNudgeBack: { model.cutOutNudged(byMs: -model.fineTune.nudgeMs) },
        onNudgeForward: { model.cutOutNudged(byMs: model.fineTune.nudgeMs) },
        onDrag: { model.cutOutDragged(toInsetX: $0) })
      Spacer(minLength: 0)
    }
  }
}
