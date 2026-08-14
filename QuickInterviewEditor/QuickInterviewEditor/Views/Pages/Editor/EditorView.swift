import SwiftUI

struct EditorView: View {
  @Bindable var model: EditorModel

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        TranscriptPageView(
          model: model.transcript,
          blocks: model.visibleClipBlocks,
          rail: model.clipMapSegments,
          counts: model.clipCountsSummary,
          footer: model.currentClipFooter,
          clipActions: transcriptClipActions
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        WaveformView(model: model)
        if model.showsFineTunePane {
          FineTuneView(model: model)
        }
      }
      Divider()
      VStack(spacing: 0) {
        Picker(model.rightPanelPickerLabel, selection: $model.rightPanelTab) {
          Text(model.slicesTabLabel).tag(RightPanelTab.slices)
          Text(model.suggestionsTabLabel).tag(RightPanelTab.suggestions)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(8)
        Divider()
        rightPanel
      }
      .frame(width: 302)
    }
    .background(Color.black)
    .background(
      AuditionKeyMonitor { key in
        Task { await model.auditionKeyPressed(key) }
      }
    )
    .background(EditorKeyMonitor(model: model))
    .background(ClipKeyMonitor(model: model))
    .task { await model.loadWaveform() }
    .task { await model.observePlayback() }
    .onChange(of: model.fineTuneSessionKey, initial: true) { _, _ in model.syncEditSession() }
    .onChange(of: model.transcript.selectedSampleRange) { _, newRange in
      // Capture the cursor token synchronously at the moment the selection changes, so a ruler click
      // landing before this snap runs is seen as the newer cursor action and the snap yields to it.
      let cursorToken = model.cursorMoveToken
      Task { await model.transportSelectionChanged(newRange, cursorToken: cursorToken) }
    }
  }

  /// The clip gestures the transcript surface routes to the model (decision B: an
  /// EditorModel-derived actions object passed in, not a back-reference into the model).
  private var transcriptClipActions: TranscriptBlockActions {
    TranscriptBlockActions(
      railTapped: { model.clipCardTapped($0) },
      select: { model.selectClip($0) },
      interiorClicked: { model.clipInteriorClicked($0, wordID: $1) },
      boundaryDragBegan: { model.clipBoundaryDragBegan($0, side: $1) },
      boundaryDragged: { model.clipBoundaryDragged(toWordID: $0) },
      boundaryDragEnded: { model.clipBoundaryDragEnded() },
      boundaryDragCancelled: { model.clipBoundaryDragCancelled() }
    )
  }

  @ViewBuilder private var rightPanel: some View {
    switch model.rightPanelTab {
    case .slices:
      SlicesPanelView(model: model)
    case .suggestions:
      CutSuggestionsPageView(model: model.cutSuggestions)
    }
  }
}
