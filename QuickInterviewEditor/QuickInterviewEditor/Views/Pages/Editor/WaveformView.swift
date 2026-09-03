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
        playhead: { model.playheadEditedSample },
        highlightRange: model.activeEditingRange,
        onRulerMove: { model.rulerMovedPlayhead(toX: $0) },
        onBodyClick: { model.waveformClicked(atX: $0, extending: $1) },
        onAreaSelectBegan: { model.waveformAreaSelectBegan(atX: $0, extending: $1) },
        onAreaSelectChanged: { model.waveformAreaSelectChanged(toX: $0) },
        onAreaSelectEnded: { model.waveformAreaSelectEnded(toX: $0) },
        seams: model.seamOverlays,
        onContextMenu: { model.seamContextMenuItems(atX: $0) },
        onEdgeDragBegan: { model.selectionEdgeDragBegan($0) },
        onEdgeDragged: { model.selectionEdgeDragged($0, toX: $1) },
        onEdgeDragEnded: { model.selectionEdgeDragEnded($0) },
        auditionOverlay: { span in
          if model.canAudition {
            AuditionEdgeButtons(
              span: span,
              inTitle: model.auditionInButtonTitle,
              inHotkey: model.auditionInHotkey,
              outTitle: model.auditionOutButtonTitle,
              outHotkey: model.auditionOutHotkey,
              isInActive: model.isAuditioningIn,
              isOutActive: model.isAuditioningOut,
              onIn: { Task { await model.auditionInTapped() } },
              onOut: { Task { await model.auditionOutTapped() } })
          }
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
