import SwiftUI

struct EditorView: View {
  @Bindable var model: EditorModel

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        TranscriptPageView(model: model.transcript)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The selection controls (Mark as Clip / Clear) sit right under the transcript where the
        // words are selected. The fine-tune PANE is intentionally not mounted in this flow — it
        // popped in on selection and reflowed the layout; FineTuneView stays in the codebase,
        // unmounted, ready to re-enable when a visual boundary-editing UI returns. The fine-tune
        // SESSION itself is wired below (`fineTuneSessionKey`) so the ←/→ nudge keys (Task 9) have
        // a draft to move even with no pane on screen.
        MarkClipBarView(model: model)
        Divider()
        WaveformView(model: model)
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
    // `onDismiss` covers EVERY way the sheet can go away — Save, Cancel, AND an Escape-key/
    // outside-click dismissal that bypasses both buttons — so `.sliceEdit` transport can never be
    // left orphaned. `sliceEditSheetDismissed` captures the session synchronously (so a late stop
    // can't kill a newer one) and skips the stop when a new modal is already present, so the button
    // paths' own dismiss stop plus a rapid dismiss→reopen are both handled safely.
    .sheet(
      item: $model.editSlice,
      onDismiss: { model.sliceEditSheetDismissed() },
      content: { EditSliceView(model: $0) }
    )
    .task { await model.loadWaveform() }
    .task { await model.observePlayback() }
    // Kick off a background suggestion pass as soon as the file is open, so the user lands on
    // suggestions already in flight. Quietly no-ops when suggestions already exist or no API key
    // resolves — it never opens the key-entry sheet on its own.
    .task { await model.cutSuggestions.autoSuggestCutsIfNeeded() }
    // A fresh transcript/waveform selection (or an active-slice change) opens/reconciles a
    // fine-tune session — invisible, since the pane isn't mounted, but it gives ←/→/⇧←/⇧→ a
    // `draftRange` to nudge before the pending removal commits (Task 9). `activeEditingRange`/
    // `waveformHighlightSpan` already prefer the draft over the raw selection, so the existing
    // waveform highlight moves with the nudge automatically — no new UI needed.
    .onChange(of: model.fineTuneSessionKey) { _, _ in model.syncEditSession() }
    // The editor derives the clip bands (slices + pending suggestions, green over amber) and
    // pushes them into the transcript, which stays layout-local and only renders what it's
    // handed. `initial: true` seeds the containers on first appearance.
    .onChange(of: model.clipBands, initial: true) { _, bands in
      model.transcript.clipBands = bands
    }
    // Words whose midpoint falls inside a removed section get struck through — same
    // pushed-in pattern as `clipBands`, so the transcript doesn't know about removals.
    .onChange(of: model.removedWordIDs, initial: true) { _, ids in
      model.transcript.removedWordIDs = ids
    }
    .onChange(of: model.audioSelection) { _, newRange in
      // `audioSelection` is now the selection source of truth, so transport-snap tracks it directly.
      // Capture the cursor token synchronously at the moment the selection changes, so a ruler click
      // landing before this snap runs is seen as the newer cursor action and the snap yields to it.
      let cursorToken = model.cursorMoveToken
      Task { await model.transportSelectionChanged(newRange, cursorToken: cursorToken) }
    }
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
