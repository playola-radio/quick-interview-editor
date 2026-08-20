import SwiftUI

/// The read-only waveform section under the transcript. The `EditorModel`-bound header (transport,
/// caption, audition status, zoom buttons) stays here; the ruler + band themselves are the reusable
/// ``WaveformLaneView``, mounted with adapters that forward its raw callbacks to today's
/// `EditorModel` methods so behavior is unchanged. The audition edge buttons are supplied to the
/// lane's overlay slot and stay `EditorModel`-bound.
struct WaveformView: View {
  @Bindable var model: EditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      WaveformLaneView(
        waveform: model.editedWaveform,
        playhead: { model.playheadSample },
        highlightRange: model.activeEditingRange,
        onRulerMove: { model.rulerMovedPlayhead(toX: $0) },
        onBodyClick: { model.waveformClicked(atX: $0, extending: $1) },
        onAreaSelectBegan: { model.waveformAreaSelectBegan(atX: $0, extending: $1) },
        onAreaSelectChanged: { model.waveformAreaSelectChanged(toX: $0) },
        onAreaSelectEnded: { model.waveformAreaSelectEnded(toX: $0) },
        seams: model.seamSpans,
        onEdgeDragBegan: { model.selectionEdgeDragBegan($0) },
        onEdgeDragged: { model.selectionEdgeDragged($0, toX: $1) },
        onEdgeDragEnded: { model.selectionEdgeDragEnded($0) },
        auditionOverlay: { span in
          if model.canAudition { AuditionEdgeButtons(model: model, span: span) }
        }
      )
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(Color.black)
  }

  private var header: some View {
    HStack(spacing: 12) {
      TransportPanelView(model: model)
      Text(model.waveform.caption)
        .font(.system(size: 11, weight: .semibold)).tracking(1.5)
        .foregroundStyle(Color(white: 0.44))
      if let status = model.auditionStatusText {
        Text(status)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Color(red: 0.96, green: 0.86, blue: 0.4))
      }
      if let note = model.removalPlaybackNote {
        Text(note)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Color(white: 0.44))
      }
      Spacer()
      WaveformAmplitudeZoomButton(waveform: model.waveform)
        .disabled(!model.waveform.canAmplitudeZoom)
      Button {
        model.editedWaveform.zoomOutTapped()
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .disabled(!model.editedWaveform.canZoomOut)
      .help(model.waveform.zoomOutLabel)
      Button {
        model.editedWaveform.zoomInTapped()
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .disabled(!model.editedWaveform.canZoomIn)
      .help(model.waveform.zoomInLabel)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(Color(white: 0.6))
  }
}

/// Two buttons pinned to the highlighted region's edges. Labels (and their keys) come from the
/// model; this view only positions them and clamps so they don't overlap on a narrow span.
private struct AuditionEdgeButtons: View {
  let model: EditorModel
  let span: WaveformSpan

  private let buttonWidth: CGFloat = 74
  private let gap: CGFloat = 4

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      // In on the left edge, Out on the right edge; keep both within the band and never
      // overlapping — a narrow or right-clipped span collapses them to a side-by-side pair.
      let maxLeft = max(0, width - (buttonWidth * 2 + gap))
      let left = min(max(0, span.positionX), maxLeft)
      let rightIdeal = span.positionX + span.width - buttonWidth
      let right = min(max(rightIdeal, left + buttonWidth + gap), max(0, width - buttonWidth))
      ZStack(alignment: .topLeading) {
        button(model.auditionInButtonLabel, active: model.isAuditioningIn) {
          Task { await model.auditionInTapped() }
        }
        .offset(x: left, y: 8)
        button(model.auditionOutButtonLabel, active: model.isAuditioningOut) {
          Task { await model.auditionOutTapped() }
        }
        .offset(x: right, y: 8)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private func button(_ label: String, active: Bool, _ run: @escaping () -> Void)
    -> some View
  {
    Button(action: run) {
      Text(label)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: buttonWidth)
        .padding(.vertical, 3)
    }
    .buttonStyle(.borderless)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .fill(
          active
            ? Color(red: 0.96, green: 0.86, blue: 0.4).opacity(0.28)
            : Color.white.opacity(0.12))
    )
    .foregroundStyle(active ? Color(red: 0.96, green: 0.86, blue: 0.4) : Color(white: 0.85))
  }
}
