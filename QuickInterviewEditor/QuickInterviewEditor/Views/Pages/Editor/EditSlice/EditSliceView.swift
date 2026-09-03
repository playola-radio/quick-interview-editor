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
        Button(model.removeSectionLabel) { Task { await model.removeSelectionTapped() } }
          .disabled(!model.canRemoveSelection)
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

/// The slice's waveform lane: the same reusable ``WaveformLaneView`` the main editor mounts. Ruler/
/// body clicks seek the cursor; the draft kept range is the highlight band. Marquee area-select and
/// the seam context menu mirror the main editor — a marquee removes (routed to the parent's merge
/// funnel) and a right-click on a seam restores, so the modal edits the slice exactly like the main
/// timeline (Item ①).
private struct SliceWaveformLane: View {
  let model: EditSliceModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      zoomHeader
      WaveformLaneView(
        waveform: model.editedWaveform,
        playhead: { model.laneCursorSample },
        highlightRange: model.waveformHighlightRange,
        onRulerMove: { positionX in Task { await model.waveformDragged(toX: positionX) } },
        onBodyClick: { positionX, _ in Task { await model.waveformSeeked(toX: positionX) } },
        onAreaSelectBegan: { positionX, extending in
          model.waveformAreaSelectBegan(atX: positionX, extending: extending)
        },
        onAreaSelectChanged: { positionX in model.waveformAreaSelectChanged(toX: positionX) },
        onAreaSelectEnded: { positionX in model.waveformAreaSelectEnded(toX: positionX) },
        seams: model.seamOverlays,
        onContextMenu: { positionX in model.waveformContextMenuItems(atX: positionX) },
        // No on-lane audition buttons here — pinned to the band edges they read as in/out
        // markers, not transport. The sheet's audition controls live in ``AuditionPreviewPanel``
        // beside the boundary insets instead.
        auditionOverlay: { _ in }
      )
    }
  }

  private var zoomHeader: some View {
    HStack(spacing: 8) {
      if let status = model.auditionStatusText {
        Text(status)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Color(red: 0.96, green: 0.86, blue: 0.4))
      }
      Spacer()
      WaveformAmplitudeZoomButton(waveform: model.waveform)
        .disabled(!model.waveform.canAmplitudeZoom)
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
        nudgeBackLabel: model.fineTune.nudgeBackLabel,
        nudgeForwardLabel: model.fineTune.nudgeForwardLabel,
        onNudgeBack: { model.cutInNudgedBack() },
        onNudgeForward: { model.cutInNudgedForward() },
        onDrag: { model.cutInDragged(toInsetX: $0) })
      BoundaryInset(
        label: model.fineTune.cutOutLabel, timeLabel: model.fineTune.cutOutTimeLabel,
        width: model.fineTune.insetWidthPixels, columns: model.cutOutColumns(),
        safeZones: model.fineTune.cutOutSafeZones, keptSpan: model.fineTune.cutOutKeptSpan,
        discardedSpan: model.fineTune.cutOutDiscardedSpan, lineX: model.fineTune.cutOutLineX,
        nudgeBackLabel: model.fineTune.nudgeBackLabel,
        nudgeForwardLabel: model.fineTune.nudgeForwardLabel,
        onNudgeBack: { model.cutOutNudgedBack() },
        onNudgeForward: { model.cutOutNudgedForward() },
        onDrag: { model.cutOutDragged(toInsetX: $0) })
      AuditionPreviewPanel(model: model)
      Spacer(minLength: 0)
    }
  }
}

/// The audition transport, parked in the open space beside the boundary insets. Off the waveform
/// (where edge-pinned buttons read as in/out markers) and captioned "To preview:", it reads as
/// "play me this edit" — and the ``KeycapChip``s advertise the `[` / `]` hotkeys.
private struct AuditionPreviewPanel: View {
  let model: EditSliceModel

  private let activeYellow = Color(red: 0.96, green: 0.86, blue: 0.4)

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(model.auditionPanelCaption)
        .font(.system(size: 10.5, weight: .semibold)).tracking(0.8)
        .foregroundStyle(Color(white: 0.48))
      previewButton(
        title: model.auditionInButtonTitle, key: model.auditionInHotkey,
        active: model.isAuditioningIn
      ) { Task { await model.auditionInTapped() } }
      previewButton(
        title: model.auditionOutButtonTitle, key: model.auditionOutHotkey,
        active: model.isAuditioningOut
      ) { Task { await model.auditionOutTapped() } }
    }
    .padding(.top, 2)
  }

  private func previewButton(
    title: String, key: String, active: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title)
          .font(.system(size: 11, weight: .semibold))
        Spacer(minLength: 0)
        KeycapChip(key: key, active: active)
      }
      .frame(width: 68)
      .padding(.vertical, 4)
      .padding(.horizontal, 9)
    }
    .buttonStyle(.borderless)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .fill(active ? activeYellow.opacity(0.28) : Color.white.opacity(0.12))
    )
    .foregroundStyle(active ? activeYellow : Color(white: 0.85))
  }
}
