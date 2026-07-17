import Dependencies
import Foundation
import IdentifiedCollections
import IssueReporting
import Observation

@MainActor
@Observable
final class EditorModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.audioPlayer) var audioPlayer
  @ObservationIgnored @Dependency(\.engine) var engine
  @ObservationIgnored @Dependency(\.workspace) var workspace

  // MARK: - Initialization
  /// The user's original file — used **only** to name exported clips (its stem).
  let sourceURL: URL
  /// The canonical PCM AIFF backing waveform, playback, and render. Every coordinate
  /// is a sample of this one file, so the playhead sits exactly on the pyramid.
  let canonicalAudioURL: URL
  let editPlan: EditPlan
  var transcript: TranscriptPageModel
  var waveform: WaveformModel
  var fineTune: FineTuneModel

  init(sourceURL: URL, canonicalAudioURL: URL, editPlan: EditPlan) {
    self.sourceURL = sourceURL
    self.canonicalAudioURL = canonicalAudioURL
    self.editPlan = editPlan
    self.transcript = TranscriptPageModel(editPlan: editPlan)
    self.waveform = WaveformModel()
    self.fineTune = FineTuneModel(
      sampleRate: editPlan.source.sampleRate, durationSamples: editPlan.source.durationSamples,
      silences: editPlan.silences)
    super.init()
  }

  // MARK: - Export Phase
  enum ExportPhase: Equatable {
    case idle
    case exporting(current: Int, total: Int)
    case done(count: Int)
    case failed(String)
  }

  // MARK: - Properties
  var slices: IdentifiedArrayOf<Slice> = []
  /// Undo/redo history over `slices` only — never selection, zoom, playback, or export
  /// phase. Every slice mutation routes through `mutateSlices`, which records here.
  var sliceUndo = UndoStack<IdentifiedArrayOf<Slice>>()
  var playingSliceID: Slice.ID?
  /// The slice currently open in the fine-tune pane. Distinct from `playingSliceID` — a
  /// slice can be active (being edited) without playing, and vice versa.
  var activeSliceID: Slice.ID?
  /// True while the fine-tune pane's "preview edit" is playing the draft range, so the
  /// waveform playhead follows it even though no slice is "playing" in the panel sense.
  var isPreviewingDraft = false
  var exportPhase: ExportPhase = .idle
  var destinationURL: URL?
  private var nextSliceNumber = 1
  private var lastExportTightNames: [String] = []
  @ObservationIgnored private(set) var exportTask: Task<Void, Never>?

  // MARK: - Display Text
  let addSliceLabel = "Add slice"
  let emptyStateMessage = "Select words in the transcript, then Add slice."
  let playLabel = "Play"
  let stopLabel = "Stop"
  let deleteLabel = "Delete slice"
  let exportLabel = "Export"
  let exportAllLabel = "Export all"
  let cancelExportLabel = "Cancel export"
  let undoLabel = "Undo"
  let redoLabel = "Redo"

  // MARK: - Fine-tune session
  /// The active slice's committed range, if a slice is open in the pane.
  var activeSliceRange: Range<Int>? {
    guard let activeSliceID, let slice = slices[id: activeSliceID] else { return nil }
    return slice.startSample..<slice.endSample
  }
  /// The range a fresh edit session would start from — aligned with `fineTuneTarget`: the
  /// transcript selection takes precedence, else the active slice.
  var activeOrSelectedRange: Range<Int>? { transcript.selectedSampleRange ?? activeSliceRange }
  /// The one range the main waveform overlay tracks — the live draft while dragging, else the
  /// active/selected range. The waveform doesn't care whether it's pending, slice-backed, or
  /// mid-drag.
  var activeEditingRange: Range<Int>? { fineTune.draftRange ?? activeOrSelectedRange }

  /// What the fine-tune pane binds to: a live transcript selection takes precedence (a fresh
  /// selection is a new-slice intent that retargets the pane), else the active slice.
  /// `sliceSelected` clears the selection so an edited slice cleanly becomes the driver.
  var fineTuneTarget: FineTuneModel.Target? {
    if transcript.selectedSampleRange != nil { return .pendingSelection }
    if let activeSliceID { return .slice(activeSliceID) }
    return nil
  }
  var showsFineTunePane: Bool { fineTuneTarget != nil }

  /// The inputs that define which edit session should be open. The view watches this and
  /// calls `syncEditSession()` when it changes, so opening a session stays a model decision.
  /// Includes the active slice's *range* so an undo/redo that moves the active slice (without
  /// removing it) re-fires the sync and re-anchors the draft to the restored cut points.
  var fineTuneSessionKey: FineTuneSessionKey {
    FineTuneSessionKey(
      activeSliceID: activeSliceID, activeSliceRange: activeSliceRange,
      selection: transcript.selectedSampleRange)
  }

  /// True only while an EXISTING slice has an unsaved cut edit — the user must Save or Cancel
  /// before exporting or undo/redo (a pending-selection draft is a new slice, not a mutation,
  /// and export never renders it, so it doesn't gate).
  var hasUncommittedSliceEdit: Bool {
    fineTune.isEditingExistingSlice && fineTune.hasUnsavedChange
  }

  /// Min/max columns for each fine-tune inset silhouette, delegated to the waveform pyramid.
  var cutInColumns: [WaveformColumn] {
    fineTune.cutInWindow.map { waveform.columns(in: $0, pixelWidth: fineTune.insetWidthPixels) }
      ?? []
  }
  var cutOutColumns: [WaveformColumn] {
    fineTune.cutOutWindow.map { waveform.columns(in: $0, pixelWidth: fineTune.insetWidthPixels) }
      ?? []
  }

  // MARK: - Waveform sync
  /// The selected audio range, mirrored from the transcript selection.
  var highlightedSampleRange: Range<Int>? { transcript.selectedSampleRange }

  /// Sample ranges of the run-together (tight-join) words to paint red. Reuses the
  /// transcript's already-computed `isRunTogether` (same gap function + live sensitivity),
  /// so the waveform's red always matches the transcript's without recomputing it. Words
  /// missing sample bounds are excluded.
  var redRanges: [Range<Int>] {
    transcript.words.compactMap { word in
      guard word.isRunTogether, let start = word.startSample, let end = word.endSample,
        start < end
      else { return nil }
      return start..<end
    }
  }

  /// Waveform render data, geometry delegated to the child and combined with the
  /// transcript-derived ranges here (the view reads these; it decides nothing). The highlight
  /// tracks `activeEditingRange`, so it follows a fine-tune drag live.
  var waveformHighlightSpan: WaveformSpan? { activeEditingRange.flatMap(waveform.span(for:)) }
  var waveformRedSpans: [WaveformSpan] { redRanges.compactMap(waveform.span(for:)) }

  // MARK: - View Helpers
  /// A pending selection that's been fine-tuned but not saved. The panel's plain "Add slice"
  /// builds from the raw selection and would discard those adjustments, so it's disabled until
  /// the draft is saved (via "Save cut") or cancelled.
  var hasUncommittedPendingDraft: Bool {
    if case .pendingSelection = fineTune.target { return fineTune.hasUnsavedChange }
    return false
  }
  var canAddSlice: Bool { transcript.selectedSampleRange != nil && !hasUncommittedPendingDraft }
  // Undo/redo restore `slices` wholesale; doing that under an open cut edit would leave the
  // draft anchored to a stale committed range, so gate on Save/Cancel first.
  var canUndo: Bool { sliceUndo.canUndo && !hasUncommittedSliceEdit }
  var canRedo: Bool { sliceUndo.canRedo && !hasUncommittedSliceEdit }

  var sliceCountLabel: String {
    "\(slices.count) \(slices.count == 1 ? "clip" : "clips")"
  }

  var isExporting: Bool {
    if case .exporting = exportPhase { return true }
    return false
  }
  var canExportAll: Bool { !slices.isEmpty && !isExporting && !hasUncommittedSliceEdit }
  var canExportSlice: Bool { !isExporting && !hasUncommittedSliceEdit }

  var exportStatusMessage: String {
    switch exportPhase {
    case .idle:
      return ""
    case .exporting(let current, let total):
      return current <= 0 ? "Preparing export…" : "Exporting slice \(current) of \(total)…"
    case .done(let count):
      let clips = count == 1 ? "clip" : "clips"
      let location = destinationURL.map { " to \($0.lastPathComponent)" } ?? ""
      return "Exported \(count) \(clips)\(location)."
    case .failed(let message):
      return message
    }
  }

  /// After a successful export, names the exported slices whose cut points weren't in
  /// silence — the user's cue to add a fade in Logic. Empty otherwise. This carries the
  /// tight-join warning into the summary; it is never written into the AIFF markers.
  var exportTightWarning: String {
    guard case .done = exportPhase, !lastExportTightNames.isEmpty else { return "" }
    let names = lastExportTightNames.joined(separator: ", ")
    let verb = lastExportTightNames.count == 1 ? "has a tight join" : "have tight joins"
    return "\(names) \(verb) — add a fade in Logic."
  }

  var showsExportStatus: Bool { !exportStatusMessage.isEmpty }
  var showsCancelExport: Bool { isExporting }

  var sliceRows: IdentifiedArrayOf<SliceRowState> {
    let sampleRate = editPlan.source.sampleRate
    return IdentifiedArray(
      uniqueElements: slices.map { slice in
        SliceRowState(
          id: slice.id,
          name: slice.name,
          durationLabel: sampleDurationLabel(
            slice.endSample - slice.startSample, sampleRate: sampleRate),
          rangeLabel: "\(sampleTimecodeLabel(slice.startSample, sampleRate: sampleRate)) – "
            + sampleTimecodeLabel(slice.endSample, sampleRate: sampleRate),
          snippet: slice.snippet,
          isTight: !slice.warnings.isEmpty,
          warningLabel: slice.warnings.isEmpty ? "" : "Tight join — add a fade in Logic",
          isPlaying: playingSliceID == slice.id,
          playButtonLabel: playingSliceID == slice.id ? stopLabel : playLabel,
          isActive: activeSliceID == slice.id
        )
      })
  }

  let fineTuneLabel = "Fine-tune cuts"

  // MARK: - User Actions
  /// Builds the waveform peak pyramid for the canonical audio, in plan-sample
  /// coordinates. Reading the canonical AIFF (already at the plan rate) means the
  /// pyramid, playhead, and cuts share one sample grid — no native→plan resample.
  func loadWaveform() async {
    await waveform.load(
      url: canonicalAudioURL, planSampleRate: editPlan.source.sampleRate,
      durationSamples: editPlan.source.durationSamples)
  }

  /// Streams playback positions from the (shared) player into the waveform playhead.
  /// The player is global — only one slice plays at a time — so ticks are applied only
  /// when THIS editor owns the playback (`playingSliceID != nil`); otherwise this editor
  /// clears its playhead, so another tab's playback never drives the wrong waveform.
  func observePlayback() async {
    for await position in audioPlayer.positions() {
      guard playingSliceID != nil || isPreviewingDraft else {
        if waveform.playheadSample != nil { waveform.playheadSample = nil }
        continue
      }
      waveform.playheadSample = position.isPlaying ? position.sample : nil
    }
    // The loop also exits when the view's task is cancelled (tab switch / disappear);
    // clear the playhead so a stale marker doesn't linger when the tab reactivates.
    waveform.playheadSample = nil
  }

  /// Waveform → transcript: a click at view-x selects the word whose audio contains that
  /// point. A click landing in a gap (or exactly on a word's end, which is exclusive)
  /// selects nothing and leaves the current selection untouched.
  func waveformTapped(atX positionX: CGFloat) {
    let sample = waveform.xToSample(positionX)
    guard let wordID = wordID(atSample: sample) else { return }
    transcript.selectWord(wordID)
  }

  /// The single funnel for every `slices` mutation: snapshots before/after and records
  /// the change on the undo stack (a no-op when nothing changed). Restoring history via
  /// `undoTapped`/`redoTapped` deliberately bypasses this — it assigns `slices` directly
  /// so replaying the stack never records a new entry.
  func mutateSlices(_ body: (inout IdentifiedArrayOf<Slice>) -> Void) {
    let old = slices
    body(&slices)
    sliceUndo.record(before: old, after: slices)
  }

  func addSliceTapped() {
    guard canAddSlice, let range = transcript.selectedSampleRange else { return }
    let wordIDs = transcript.orderedSelectedWordIDs
    guard !wordIDs.isEmpty else { return }
    let slice = Slice(
      id: UUID(),
      name: "Slice \(nextSliceNumber)",
      startSample: range.lowerBound,
      endSample: range.upperBound,
      wordIDs: wordIDs,
      snippet: displaySnippet(transcript.selectionSnippet),
      warnings: sliceWarnings(
        startSample: range.lowerBound, endSample: range.upperBound,
        durationSamples: editPlan.source.durationSamples, silences: editPlan.silences)
    )
    mutateSlices { $0.append(slice) }
    nextSliceNumber += 1
    transcript.clearSelectionTapped()
  }

  func renameSlice(_ id: Slice.ID, to name: String) {
    mutateSlices { $0[id: id]?.name = name }
  }

  func moveSlices(fromOffsets source: IndexSet, toOffset destination: Int) {
    mutateSlices { $0.move(fromOffsets: source, toOffset: destination) }
  }

  func deleteSlice(_ id: Slice.ID) async {
    await deleteSlices([id])
  }

  /// Deletes one or more slices as a **single** undo entry. A multi-row Delete in the
  /// panel is one user action, so it records once and reconciles playback once — undoing
  /// it restores every removed slice in one step.
  func deleteSlices(_ ids: [Slice.ID]) async {
    mutateSlices { slices in
      for id in ids { slices.remove(id: id) }
    }
    await reconcilePlayback()
  }

  // MARK: - Undo / Redo
  /// Restores the previous `slices` snapshot, then reconciles playback. History stores
  /// only `slices`, so anything derived (selection, zoom, export phase, playback) is left
  /// as-is except where reconciliation demands otherwise.
  func undoTapped() async {
    // Guard here too, not just on `canUndo`: a menu item or keyboard shortcut could fire this
    // while an existing-slice edit is open, which would rewind `slices` under a live draft.
    guard !hasUncommittedSliceEdit, let restored = sliceUndo.undo(current: slices) else { return }
    slices = restored
    await reconcilePlayback()
  }

  /// Reapplies the next `slices` snapshot on the redo branch, then reconciles playback.
  func redoTapped() async {
    guard !hasUncommittedSliceEdit, let restored = sliceUndo.redo(current: slices) else { return }
    slices = restored
    await reconcilePlayback()
  }

  /// Reconciles derived state after any slice list change (explicit delete, undo, redo):
  /// stops playback if the playing slice is gone, and closes the fine-tune pane if the active
  /// slice is gone (clearing its target + draft). Centralized so every removal path behaves
  /// the same.
  private func reconcilePlayback() async {
    if let playing = playingSliceID, slices[id: playing] == nil {
      playingSliceID = nil
      await audioPlayer.stop()
    }
    if let active = activeSliceID {
      if let slice = slices[id: active] {
        // The active slice survived but undo/redo may have moved its cut points; re-anchor the
        // session at the model level (not only via the view's onChange) when nothing is unsaved.
        let range = slice.startSample..<slice.endSample
        if !fineTune.hasUnsavedChange, fineTune.committedRange != range {
          fineTune.begin(target: .slice(active), range: range)
        }
      } else {
        activeSliceID = nil
        fineTune.clear()
      }
    }
  }

  func playSliceTapped(_ id: Slice.ID) async {
    guard let slice = slices[id: id] else { return }
    playingSliceID = id
    do {
      try await audioPlayer.play(
        canonicalAudioURL, slice.startSample..<slice.endSample, editPlan.source.sampleRate)
    } catch {
      reportIssue(error)
    }
    if playingSliceID == id { playingSliceID = nil }
  }

  func stopPlaybackTapped() async {
    playingSliceID = nil
    await audioPlayer.stop()
  }

  func playStopTapped(_ id: Slice.ID) async {
    if playingSliceID == id {
      await stopPlaybackTapped()
    } else {
      await playSliceTapped(id)
    }
  }

  // MARK: - Fine-tune editing
  /// Opens the fine-tune pane on a slice and starts an edit session anchored to its current
  /// range. Choosing the slice explicitly (rather than from ambient state) is what makes it
  /// the edit target.
  func sliceSelected(_ id: Slice.ID) {
    // Switching away would abandon an unsaved cut edit — of either an existing slice OR a tuned
    // pending selection — so require Save or Cancel first. Re-selecting the active slice is a
    // no-op that must not trip the guard.
    guard !fineTune.hasUnsavedChange || activeSliceID == id else { return }
    // Clear any live selection so the slice — not a lingering selection — drives the pane.
    transcript.clearSelectionTapped()
    activeSliceID = id
    syncEditSession()
  }

  /// Reconciles the fine-tune session to the current target/range. Called by the view when the
  /// active slice or selection changes, and lazily before any edit gesture. Preserves an
  /// in-progress draft: it only (re)begins when the target changed, no session is open, or the
  /// committed range drifted (e.g. an undo moved the active slice).
  func syncEditSession() {
    guard let target = fineTuneTarget, let range = activeOrSelectedRange else {
      // Don't tear down an unsaved existing-slice edit just because the target went nil.
      if fineTune.target != nil, !hasUncommittedSliceEdit { fineTune.clear() }
      return
    }
    // Never abandon an unsaved existing-slice edit by retargeting (e.g. a new transcript
    // selection arriving mid-edit); the user must Save or Cancel first.
    if hasUncommittedSliceEdit, fineTune.target != target { return }
    // Re-anchor when the target changed, no session is open, or the anchor range drifted from
    // the committed baseline. A drifted range is the source of truth moving: a pending selection
    // changing (reset the stale draft) or the active slice being restored by undo. An in-progress
    // draft only changes `draftRange`, never `committedRange`, so a live drag never trips this.
    let shouldBegin =
      fineTune.target != target || fineTune.committedRange == nil
      || fineTune.committedRange != range
    if shouldBegin {
      // A transcript selection taking over releases the previously active slice, so clearing the
      // selection later doesn't silently reopen the pane on a stale slice.
      if case .pendingSelection = target { activeSliceID = nil }
      fineTune.begin(target: target, range: range)
    }
  }

  func cutInDragged(toInsetX positionX: CGFloat) {
    beginEditIfNeeded()
    fineTune.dragCutIn(toInsetX: positionX)
  }
  func cutOutDragged(toInsetX positionX: CGFloat) {
    beginEditIfNeeded()
    fineTune.dragCutOut(toInsetX: positionX)
  }
  func cutInNudged(byMs deltaMs: Double) {
    beginEditIfNeeded()
    fineTune.nudgeCutIn(byMs: deltaMs)
  }
  func cutOutNudged(byMs deltaMs: Double) {
    beginEditIfNeeded()
    fineTune.nudgeCutOut(byMs: deltaMs)
  }

  /// Commits the draft as exactly ONE `mutateSlices` (one undo entry) for a whole drag: an
  /// existing slice's cut points are updated (word IDs + snippet + warnings re-derived from
  /// the new range); a pending selection becomes a new slice. No-op when nothing changed.
  func commitEditTapped() {
    guard fineTune.hasUnsavedChange, let draft = fineTune.draftRange, let target = fineTune.target
    else { return }
    switch target {
    case .slice(let id):
      guard slices[id: id] != nil else { return }
      mutateSlices { slices in
        if let slice = slices[id: id] { slices[id: id] = updatedSlice(slice, to: draft) }
      }
      fineTune.markCommitted(draft)
    case .pendingSelection:
      let slice = makeSlice(range: draft)
      mutateSlices { $0.append(slice) }
      nextSliceNumber += 1
      fineTune.clear()
      transcript.clearSelectionTapped()
    }
    syncEditSession()
  }

  /// Drops the unsaved change, leaving the pane open on the committed range. Re-syncs so a
  /// selection made (but ignored) during the edit can now take over the pane.
  func cancelEditTapped() {
    fineTune.resetDraft()
    syncEditSession()
  }

  /// The preview button reflects playback state so a single control both starts and stops it.
  var previewButtonLabel: String {
    isPreviewingDraft ? fineTune.previewStopLabel : fineTune.previewEditLabel
  }

  func previewToggleTapped() async {
    if isPreviewingDraft {
      await stopPreviewTapped()
    } else {
      await previewEditTapped()
    }
  }

  /// Preview the in-progress draft (falls back to the committed range). Uses a distinct
  /// playback identity so slice-panel rows don't flip to "Stop".
  func previewEditTapped() async {
    guard let range = fineTune.draftRange ?? fineTune.committedRange else { return }
    playingSliceID = nil
    isPreviewingDraft = true
    do {
      try await audioPlayer.play(canonicalAudioURL, range, editPlan.source.sampleRate)
    } catch {
      reportIssue(error)
    }
    isPreviewingDraft = false
  }

  func stopPreviewTapped() async {
    isPreviewingDraft = false
    await audioPlayer.stop()
  }

  private func beginEditIfNeeded() {
    if fineTune.committedRange == nil { syncEditSession() }
  }

  // MARK: - Export Actions
  func exportSliceTapped(_ id: Slice.ID) {
    guard !isExporting, !hasUncommittedSliceEdit, let slice = slices[id: id] else { return }
    startExport([slice])
  }

  func exportAllTapped() {
    guard !isExporting, !hasUncommittedSliceEdit, !slices.isEmpty else { return }
    startExport(Array(slices))
  }

  func cancelExportTapped() {
    exportTask?.cancel()
  }

  // MARK: - Lifecycle
  /// Removes this session's canonical audio cache dir. Called when the tab closes:
  /// the AIFF is derived data, rebuildable by re-transcribing, so it shouldn't linger.
  func discardCanonicalAudio() {
    CanonicalAudioStore.remove(canonicalAudioURL)
  }

  // MARK: - Private Helpers
  /// The word whose half-open sample range `[startSample, endSample)` contains `sample`.
  /// Words missing sample bounds are skipped, never guessed from seconds.
  private func wordID(atSample sample: Int) -> Word.ID? {
    for word in editPlan.words {
      guard let start = word.startSample, let end = word.endSample, start < end else { continue }
      if sample >= start, sample < end { return word.id }
    }
    return nil
  }

  private func displaySnippet(_ text: String) -> String {
    "“\(middleTruncatedSnippet(text, maxLength: 68))”"
  }

  /// Re-derives a slice's word membership, snippet, and warnings for a new sample range once
  /// the cut points move. Word membership is by midpoint — the old, selection-time word IDs go
  /// stale under an arbitrary cut.
  private func updatedSlice(_ slice: Slice, to range: Range<Int>) -> Slice {
    var updated = slice
    updated.startSample = range.lowerBound
    updated.endSample = range.upperBound
    updated.wordIDs = wordIDs(overlapping: range, words: editPlan.words)
    updated.snippet = displaySnippet(sliceSnippet(for: updated.wordIDs, words: editPlan.words))
    updated.warnings = sliceWarnings(
      startSample: range.lowerBound, endSample: range.upperBound,
      durationSamples: editPlan.source.durationSamples, silences: editPlan.silences)
    return updated
  }

  /// Builds a brand-new slice from a fine-tuned sample range, deriving word membership by
  /// midpoint (not the raw transcript selection) so a dragged cut owns the right words.
  private func makeSlice(range: Range<Int>) -> Slice {
    let ids = wordIDs(overlapping: range, words: editPlan.words)
    return Slice(
      id: UUID(), name: "Slice \(nextSliceNumber)", startSample: range.lowerBound,
      endSample: range.upperBound, wordIDs: ids,
      snippet: displaySnippet(sliceSnippet(for: ids, words: editPlan.words)),
      warnings: sliceWarnings(
        startSample: range.lowerBound, endSample: range.upperBound,
        durationSamples: editPlan.source.durationSamples, silences: editPlan.silences))
  }

  /// Marks the export as running synchronously (so the buttons disable immediately
  /// and a rapid second tap can't start a parallel export) and spawns the worker,
  /// keeping a handle so `cancelExportTapped` can kill the process group.
  private func startExport(_ targets: [Slice]) {
    exportTask?.cancel()
    exportPhase = .exporting(current: 0, total: targets.count)
    exportTask = Task { await performExport(targets) }
  }

  private func performExport(_ targets: [Slice]) async {
    guard let destination = await resolvedDestination() else {
      exportPhase = .idle
      return
    }
    exportPhase = .exporting(current: 0, total: targets.count)

    do {
      var rendered: [RenderedSlice] = []
      var workDir: URL?
      for try await event in engine.renderSlices(renderRequest(for: targets)) {
        switch event {
        case .progress(let progress):
          exportPhase = .exporting(
            current: progress.index,
            total: progress.total == 0 ? targets.count : progress.total)
        case .completed(let result):
          rendered = result.slices
          workDir = result.workDir
        }
      }
      if Task.isCancelled {
        await removeWorkDir(workDir)
        exportPhase = .failed(cancelMessage(copied: 0, total: targets.count))
        return
      }
      // Copy off the main actor — copying many/large AIFFs (or to a slow/network
      // folder) must not freeze the UI or block the cancel control.
      let byID = Dictionary(
        rendered.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
      let stem = sourceURL.deletingPathExtension().lastPathComponent
      let outcome = await Self.copyRenderedSlices(
        stem: stem, targets: targets, renderedByID: byID, destination: destination)
      await removeWorkDir(workDir)

      if outcome.cancelled || Task.isCancelled {
        // A cancel landing during the final copy also lands here, so the cancel
        // button can never report success.
        exportPhase = .failed(cancelMessage(copied: outcome.copied.count, total: targets.count))
      } else if let message = outcome.errorMessage {
        exportPhase = .failed(message)
      } else if outcome.copied.count != targets.count {
        // A short result means the engine didn't render every requested slice —
        // report it rather than claiming success on a partial reveal.
        exportPhase = .failed(
          "The engine rendered \(outcome.copied.count) of \(targets.count) slices.")
      } else {
        workspace.reveal(outcome.copied)
        lastExportTightNames = targets.filter { !$0.warnings.isEmpty }.map(\.name)
        exportPhase = .done(count: outcome.copied.count)
      }
    } catch is CancellationError {
      // The engine cleans up its own work-dir on a cancelled/failed run.
      exportPhase = .failed(cancelMessage(copied: 0, total: targets.count))
    } catch {
      exportPhase = .failed(error.localizedDescription)
    }
  }

  private func resolvedDestination() async -> URL? {
    if let destinationURL { return destinationURL }
    guard let chosen = await workspace.chooseDirectory() else { return nil }
    destinationURL = chosen
    return chosen
  }

  private func renderRequest(for targets: [Slice]) -> RenderRequest {
    let sampleRate = editPlan.source.sampleRate
    // Walk words in spoken order and nudge any tie one frame forward so two markers
    // never stack on the same position or get reordered by Logic — matching the
    // engine's own `build_markers` invariant (aligned timestamps occasionally
    // collide at the same rounded sample).
    var lastPosition = Int.min
    let markers = editPlan.words.map { word -> RenderMarker in
      var position = word.startSample ?? Int(word.start * Double(sampleRate))
      if position <= lastPosition { position = lastPosition + 1 }
      lastPosition = position
      return RenderMarker(position: position, name: word.text)
    }
    let specs = targets.map {
      RenderSliceSpec(id: $0.id, startSample: $0.startSample, endSample: $0.endSample)
    }
    return RenderRequest(
      audioURL: canonicalAudioURL, sampleRate: sampleRate,
      durationSamples: editPlan.source.durationSamples, markers: markers, slices: specs)
  }

  /// The result of copying rendered slices to the destination, computed off the main
  /// actor. `cancelled` means the export task was cancelled mid-copy (partial state);
  /// `errorMessage` means a copy failed; otherwise `copied` holds one URL per target.
  struct CopyOutcome: Sendable {
    var copied: [URL]
    var cancelled: Bool
    var errorMessage: String?
  }

  /// Copies each rendered temp AIFF to the destination under a unique, sanitized name.
  /// `nonisolated` so the file IO runs off the main actor. Cancellation is honoured
  /// between files so a mid-copy cancel reports how many actually landed.
  private nonisolated static func copyRenderedSlices(
    stem: String, targets: [Slice], renderedByID: [UUID: URL], destination: URL
  ) async -> CopyOutcome {
    var taken = Set(
      ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
        .map { $0.lowercased() })
    var copied: [URL] = []
    for (offset, slice) in targets.enumerated() {
      if Task.isCancelled {
        return CopyOutcome(copied: copied, cancelled: true, errorMessage: nil)
      }
      guard let source = renderedByID[slice.id] else { continue }
      let name = exportFileName(
        sourceStem: stem, sliceName: slice.name, index: offset + 1, taken: &taken)
      let target = destination.appendingPathComponent(name)
      do {
        try FileManager.default.copyItem(at: source, to: target)
        copied.append(target)
      } catch {
        return CopyOutcome(
          copied: copied, cancelled: false, errorMessage: error.localizedDescription)
      }
    }
    return CopyOutcome(copied: copied, cancelled: false, errorMessage: nil)
  }

  private nonisolated func removeWorkDir(_ workDir: URL?) async {
    guard let workDir else { return }
    try? FileManager.default.removeItem(at: workDir)
  }

  private func cancelMessage(copied: Int, total: Int) -> String {
    "Export cancelled — \(copied) of \(total) exported."
  }
}

/// Middle-truncate a transcript snippet to at most `maxLength` characters, always
/// keeping the first and last words and filling in as many middle words as fit —
/// e.g. "So a young … think is great" rather than "So a young Hayes Carl…". Short
/// snippets, and those with fewer than three words, pass through unchanged.
func middleTruncatedSnippet(_ text: String, maxLength: Int) -> String {
  let trimmed = text.trimmingCharacters(in: .whitespaces)
  guard trimmed.count > maxLength else { return trimmed }
  let words = trimmed.split(separator: " ").map(String.init)
  guard words.count >= 3 else { return trimmed }

  func rendered(head: Int, tail: Int) -> String {
    words.prefix(head).joined(separator: " ") + " … "
      + words.suffix(tail).joined(separator: " ")
  }
  // Always show the first and last word, then greedily add words toward the
  // middle from alternating ends while they still fit the budget.
  var head = 1
  var tail = 1
  var growTail = true
  // If even the minimal first-word … last-word window overflows (e.g. a single
  // run-on word or a long URL), fall back to a hard character truncation so the
  // maxLength guarantee always holds.
  guard rendered(head: head, tail: tail).count <= maxLength else {
    return String(trimmed.prefix(max(0, maxLength - 1))) + "…"
  }
  while head + tail < words.count {
    let headFits = rendered(head: head + 1, tail: tail).count <= maxLength
    let tailFits = rendered(head: head, tail: tail + 1).count <= maxLength
    if !headFits, !tailFits { break }
    if growTail, tailFits {
      tail += 1
    } else if headFits {
      head += 1
    } else {
      tail += 1
    }
    growTail.toggle()
  }
  // If the head and tail met, nothing is actually elided — show the whole thing.
  return head + tail >= words.count ? trimmed : rendered(head: head, tail: tail)
}

struct SliceRowState: Identifiable, Equatable {
  var id: Slice.ID
  var name: String
  var durationLabel: String
  var rangeLabel: String
  var snippet: String
  var isTight: Bool
  var warningLabel: String
  var isPlaying: Bool
  var playButtonLabel: String
  var isActive: Bool
}

/// The identity of a fine-tune edit session — the active slice, or a live transcript
/// selection. When this changes the view asks the model to reconcile the open session.
struct FineTuneSessionKey: Equatable {
  var activeSliceID: Slice.ID?
  var activeSliceRange: Range<Int>?
  var selection: Range<Int>?
}
