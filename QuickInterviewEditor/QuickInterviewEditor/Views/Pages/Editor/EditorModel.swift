import Dependencies
import Foundation
import IdentifiedCollections
import IssueReporting
import Observation

/// The editor-global shortcuts the key monitor can deliver. PR 2 adds transport cases here.
enum EditorKey {
  case zoomIn
  case zoomOut
  case zoomFit
}

@MainActor
@Observable
final class EditorModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.audioPlayer) var audioPlayer
  @ObservationIgnored @Dependency(\.engine) var engine
  @ObservationIgnored @Dependency(\.workspace) var workspace
  @ObservationIgnored @Dependency(\.continuousClock) var clock

  // MARK: - Initialization
  /// The user's original file — used **only** to name exported clips (its stem).
  let sourceURL: URL
  /// The canonical PCM AIFF backing waveform, playback, and render. Every coordinate
  /// is a sample of this one file, so the playhead sits exactly on the pyramid.
  let canonicalAudioURL: URL
  let editPlan: EditPlan
  /// Stable identity for the source file, keying the per-file project sidecar the
  /// cut-suggester writes to. Content-derived when supplied by the tab; a path-based
  /// fallback keeps previews/tests working without hashing a file.
  let sourceFingerprint: String
  var transcript: TranscriptPageModel
  var waveform: WaveformModel
  var fineTune: FineTuneModel
  var cutSuggestions: CutSuggestionsPageModel

  init(sourceURL: URL, canonicalAudioURL: URL, editPlan: EditPlan, sourceFingerprint: String? = nil)
  {
    self.sourceURL = sourceURL
    self.canonicalAudioURL = canonicalAudioURL
    self.editPlan = editPlan
    let fingerprint = sourceFingerprint ?? ("path:" + sourceURL.standardizedFileURL.path)
    self.sourceFingerprint = fingerprint
    self.transcript = TranscriptPageModel(editPlan: editPlan)
    self.waveform = WaveformModel()
    self.fineTune = FineTuneModel(
      sampleRate: editPlan.source.sampleRate, durationSamples: editPlan.source.durationSamples,
      silences: editPlan.silences)
    // Constructed within the ambient dependency context of this init (the parent wraps
    // `EditorModel(...)` in `withDependencies(from:)`), so the child inherits the same deps.
    self.cutSuggestions = CutSuggestionsPageModel(
      editPlan: editPlan, sourceFingerprint: fingerprint)
    super.init()
    // Accepting a suggestion adds its slice here (idempotently), through the shared
    // mutation funnel so it's exportable and undoable like any other slice.
    cutSuggestions.onAcceptSlice = { [weak self] slice in
      self?.acceptCutSuggestionSlice(slice)
    }
    // Clicking a suggestion reveals it across both panes so the user can review/audition it.
    cutSuggestions.onSelectSuggestion = { [weak self] suggestion in
      self?.cutSuggestionSelected(suggestion)
    }
  }

  // MARK: - Export Phase
  enum ExportPhase: Equatable {
    case idle
    case exporting(current: Int, total: Int)
    case done(count: Int)
    case failed(String)
  }

  enum AuditionMode: Equatable { case cutIn, cutOut }
  enum AuditionKey: Equatable { case cutIn, cutOut, space }

  // MARK: - Properties
  var slices: IdentifiedArrayOf<Slice> = []
  /// Undo/redo history over `slices` only — never selection, zoom, playback, or export
  /// phase. Every slice mutation routes through `mutateSlices`, which records here.
  var sliceUndo = UndoStack<IdentifiedArrayOf<Slice>>()
  /// The slice currently open in the fine-tune pane. Edit-target state, NOT playback state — a
  /// slice can be active (being edited) without playing, and vice versa.
  var activeSliceID: Slice.ID?
  /// The interview transport's phase. `.playing`/`.paused` carry the `PlaybackSessionID` that owns
  /// the one shared player, so a stale/superseded tick (or another tab's) can be told from the
  /// current one, and the model stops via `stop(session)` so a delayed cleanup can't kill newer or
  /// global playback. This is the single session slot for EVERY playback now: slice, preview,
  /// audition, and free scrubbing all run through the transport (the session is `transportPhase.session`).
  var transportPhase: TransportPhase = .stopped
  /// Which convenience shortcut (if any) owns the current playback. `.free` is plain scrubbing; the
  /// others record that a saved slice, the fine-tune preview, or a boundary audition drove Play, so
  /// the derived display props (row highlight, preview/audition labels, status text) reflect it.
  /// Always reset to `.free` when the transport returns to `.stopped`.
  var transportContext: TransportContext = .free
  /// THE persistent, always-visible playhead cursor, in plan samples. Follows audio during
  /// playback and stays put when stopped/paused (never hidden). Kept a SEPARATE observed property
  /// (not folded into a transport struct) so its ~30 Hz updates don't invalidate views that read
  /// `transportPhase`/`transportContext` (the panel, the slice list).
  var playheadSample = 0
  /// Where the transport last started playing; Stop returns the cursor here.
  var transportOriginSample: Int?
  /// What the transport is currently playing, captured at Play. Non-observed — internal bookkeeping.
  @ObservationIgnored private var transportRange: Range<Int>?
  /// Bumped whenever something authoritatively places the cursor outside the selection-snap path — a
  /// ruler move or a transport start. A deferred selection snap (`transportSelectionChanged`) captures
  /// this at selection-change time (via `cursorMoveToken`) and bails if it changed, so it can neither
  /// clobber a newer ruler placement nor stop a playback that started after the selection changed.
  @ObservationIgnored private var cursorMoveGeneration = 0
  /// True while a waveform marquee drag is in progress. The deferred selection→playhead snap
  /// (`transportSelectionChanged`) bails while this is set, so the dozens of live selection updates
  /// a drag emits don't churn the transport; the snap is committed exactly once on release.
  @ObservationIgnored private var isWaveformAreaSelecting = false
  /// Transient state for the in-progress marquee drag (nil when not dragging). `anchorSample` is
  /// captured in plan samples (not a view-x) so a mid-drag zoom or resize can't corrupt the fixed
  /// end of the selection.
  @ObservationIgnored private var areaSelectDrag: WaveformAreaSelectDrag?
  /// The running auto-scroll loop while the pointer sits past a viewport edge (nil otherwise).
  @ObservationIgnored private var autoScrollTask: Task<Void, Never>?
  /// Bumped each time a marquee drag begins so a stale auto-scroll tick from a previous drag bails.
  @ObservationIgnored private var areaSelectGeneration = 0
  var exportPhase: ExportPhase = .idle
  var destinationURL: URL?
  /// Which pane the right column shows. The clips list and the cut-suggester share the
  /// column so accepting a suggestion visibly lands a clip in the Slices tab.
  var rightPanelTab: RightPanelTab = .slices
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
  let tightBadgeLabel = "Tight join"
  let tightBadgeHelp = "A cut point isn't in a silence — add a fade in Logic."
  let slicesTabLabel = "Clips"
  let suggestionsTabLabel = "Suggestions"
  let rightPanelPickerLabel = "Right panel"
  let revealClipLabel = "Reveal clip in transcript and waveform"

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
  // The pane also stays visible while a held draft is unsaved even if the target briefly reads
  // nil (e.g. the selection was cleared), so a tuned pending draft isn't hidden out from under
  // the user before they Save or Cancel.
  var showsFineTunePane: Bool { fineTuneTarget != nil || fineTune.hasUnsavedChange }

  /// "Save cut" is enabled whenever there's something to commit: a pending selection can always
  /// be saved as a slice — even with the untouched, auto-detected cut points — while an existing
  /// slice only commits when its cut points actually changed.
  var canCommitEdit: Bool {
    switch fineTune.target {
    case .pendingSelection: return fineTune.draftRange != nil
    case .slice: return fineTune.hasUnsavedChange
    case .none: return false
    }
  }

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

  /// Sample ranges of the run-together words, reading the transcript's already-computed
  /// `runTogetherSampleRanges`. Retained analysis — no longer painted on the waveform — kept
  /// so a future feature (e.g. revealing tight joins while dragging) can surface it again.
  /// Words missing sample bounds are excluded.
  var redRanges: [Range<Int>] { transcript.runTogetherSampleRanges }

  // MARK: - Clip containers (transcript)
  /// The clip bands the transcript draws as tinted containers: real slices are `approved`
  /// (green); still-pending cut suggestions are `suggested` (amber). Derived read-only from
  /// the editor's own state and pushed into `transcript` by the view; the transcript stays
  /// layout-local and only renders what it's handed.
  ///
  /// Precedence: an actual slice wins over a suggestion on any shared word, so a pending
  /// suggestion is drawn only over the words no slice already claims (green over amber). A
  /// suggestion fully covered by slices contributes no band.
  var clipBands: [TranscriptClipBand] {
    let approved = slices.map { slice in
      TranscriptClipBand(id: slice.id, wordIDs: slice.wordIDs, kind: .approved)
    }
    let claimed = Set(approved.flatMap(\.wordIDs))
    let suggested = cutSuggestions.pendingSuggestions.compactMap {
      suggestion -> TranscriptClipBand? in
      let unclaimed = suggestion.wordIDs.filter { !claimed.contains($0) }
      guard !unclaimed.isEmpty else { return nil }
      return TranscriptClipBand(id: suggestion.id, wordIDs: unclaimed, kind: .suggested)
    }
    return approved + suggested
  }

  /// Waveform render data, geometry delegated to the child (the view reads these; it decides
  /// nothing). The highlight tracks `activeEditingRange`, so it follows a fine-tune drag live.
  var waveformHighlightSpan: WaveformSpan? { activeEditingRange.flatMap(waveform.span(for:)) }

  /// View-x of the persistent cursor, or nil when it's scrolled out of the viewport. The model
  /// owns the cursor sample; the waveform supplies the geometry, so the view stays logic-free.
  var playheadX: CGFloat? { waveform.playheadX(for: playheadSample) }

  // MARK: - View Helpers
  /// The panel's plain "Add slice" builds from the raw selection, so it's disabled whenever any
  /// fine-tune draft is unsaved — a tuned pending selection (whose adjustments it would discard)
  /// or a dirty existing-slice edit with a held selection (which requires Save/Cancel first).
  var canAddSlice: Bool { transcript.selectedSampleRange != nil && !fineTune.hasUnsavedChange }
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
          warningLabel: slice.warnings.isEmpty ? "" : tightBadgeLabel,
          warningHelp: slice.warnings.isEmpty ? "" : tightBadgeHelp,
          // The row highlights while its slice is the transport's context; the button is a pure
          // Play shortcut now (no per-slice Stop — the global transport owns Pause/Stop, ruling F).
          isPlaying: transportContext.sliceID == slice.id,
          playButtonLabel: playLabel,
          isActive: activeSliceID == slice.id,
          // The fine-tune button switches the edit target, which `sliceSelected` rejects while
          // another draft is unsaved — disable it then so it doesn't look broken when clicked.
          canFineTune: !fineTune.hasUnsavedChange || activeSliceID == slice.id
        )
      })
  }

  let fineTuneLabel = "Edit cuts"

  // MARK: - User Actions
  /// Builds the waveform peak pyramid for the canonical audio, in plan-sample
  /// coordinates. Reading the canonical AIFF (already at the plan rate) means the
  /// pyramid, playhead, and cuts share one sample grid — no native→plan resample.
  func loadWaveform() async {
    await waveform.load(
      url: canonicalAudioURL, planSampleRate: editPlan.source.sampleRate,
      durationSamples: editPlan.source.durationSamples)
  }

  /// Streams playback positions from the (shared) player into the persistent playhead cursor.
  /// The player is global — only one thing plays at a time — so ticks move the cursor only while
  /// THIS editor owns the playback (its `transportPhase` holds a session) AND the tick is tagged
  /// with that session. The cursor is never cleared here: it persists where the audio (or the user)
  /// last left it, so a false/final tick or another tab's tick can't blank or yank it.
  func observePlayback() async {
    for await position in audioPlayer.positions() {
      guard let session = transportPhase.session, position.sessionID == session else { continue }
      // A paused transport owns the session but the cursor is frozen at the exact sample `pause`
      // returned; a buffered straggler tick for that session must not thaw it.
      if isTransportPaused { continue }
      if position.isPlaying {
        playheadSample = position.sample
        // Only slice playback drives transcript auto-scroll follow (preview/audition/free do not).
        transcript.playheadChanged(sample: position.sample, isPlaying: transportContext.isSlice)
      } else if transportContext.isSlice {
        // A false tick during slice playback ends transcript follow (so the next slice reads as a
        // rising edge) but leaves the cursor exactly where the audio stopped.
        endTranscriptFollow()
      }
    }
  }

  /// Clears the transport owner so a new playback can take over: it resets the phase/context/range
  /// to stopped (dropping the previous session, so the old suspended `play`'s post-await guard fails
  /// and its cleanup no-ops) and resets transcript follow so the new play reads as a rising edge. It
  /// never resets `playheadSample` — the persistent cursor survives supersession. Callers set the
  /// new session/context *after* this, via `beginTransportPlayback`.
  private func beginExclusivePlayback() {
    endTranscriptFollow()
    resetTransportState()
  }

  /// Clears every field of the transport's ownership state (phase/context/origin/range) back to the
  /// stopped/`.free` baseline — never touching `playheadSample`. The single place transport state
  /// resets, so a future field can't be missed by one of the several cleanup paths.
  private func resetTransportState() {
    transportPhase = .stopped
    transportContext = .free
    transportOriginSample = nil
    transportRange = nil
  }

  /// Stops the given session, or does nothing if it's nil. A nil session means THIS editor
  /// owns no playback, so there is nothing of ours to stop — and calling `stop(nil)` would
  /// stop whatever is playing globally, stealing another tab's playback. Every model stop path
  /// routes through here so an idle editor's cleanup (close tab, reimport) can't steal.
  private func stopOwnedPlayback(_ session: PlaybackSessionID?) async {
    guard let session else { return }
    await audioPlayer.stop(session)
  }

  /// Waveform → transcript: a click at view-x selects the word whose audio contains that
  /// point; Shift extends the current selection to it. A click landing in a gap selects
  /// nothing and leaves the selection untouched.
  func waveformClicked(atX positionX: CGFloat, extending: Bool) {
    let sample = waveform.xToSample(positionX)
    guard let wordID = wordID(atSample: sample) else { return }
    if extending {
      transcript.wordClicked(wordID, extending: true)
    } else {
      transcript.selectWord(wordID)
    }
  }

  // MARK: - Waveform area selection (Logic-style marquee)
  /// Auto-scroll tick cadence and speed (in view pixels per tick, later converted to samples via the
  /// current `samplesPerPixel` so the feel is stable at any zoom). `Gain` maps overshoot-past-the-edge
  /// to speed; the min keeps a barely-past-edge drag moving, the max keeps a far-past drag controllable.
  private static let autoScrollTickMs = 16
  private static let autoScrollGain = 0.5
  private static let minAutoScrollPixelsPerTick: CGFloat = 4
  private static let maxAutoScrollPixelsPerTick: CGFloat = 40

  /// Waveform body drag ⇒ a Logic-style marquee. `startX` fixes the anchor edge (in plan samples);
  /// holding Shift with an existing selection extends it instead of starting fresh. Begins live
  /// selection immediately so the transcript + waveform highlight track the drag. A no-op until the
  /// geometry is loaded (the x→sample mapping is meaningless before then).
  func waveformAreaSelectBegan(atX startX: CGFloat, extending: Bool) {
    guard waveform.hasUsableGeometry else { return }
    cancelAutoScroll()
    areaSelectGeneration &+= 1
    let existingAnchorID = extending ? transcript.selectionAnchorID : nil
    let existingAnchorSample = existingAnchorID.flatMap(anchorSample(forWord:))
    areaSelectDrag = WaveformAreaSelectDrag(
      anchorSample: clampedSample(waveform.xToSample(startX)),
      currentX: startX,
      existingAnchorID: existingAnchorSample == nil ? nil : existingAnchorID,
      existingAnchorSample: existingAnchorSample)
    isWaveformAreaSelecting = true
    updateMarqueeSelection()
  }

  /// A pointer move during the marquee: re-extends the live selection and, when the pointer is past a
  /// viewport edge, starts (or keeps) the auto-scroll loop; back inside, it stops.
  func waveformAreaSelectChanged(toX positionX: CGFloat) {
    guard isWaveformAreaSelecting, areaSelectDrag != nil else { return }
    areaSelectDrag?.currentX = positionX
    updateMarqueeSelection()
    if isPointerPastEdge(positionX) {
      startAutoScrollIfNeeded()
    } else {
      cancelAutoScroll()
    }
  }

  /// Release: stops any auto-scroll, commits the final selection, and — only if it resolved to words —
  /// snaps the playhead to the selection start (claiming cursor authority so a straggler snap can't
  /// undo it) and scrolls the transcript to it. A drag that ended over pure silence clears instead.
  func waveformAreaSelectEnded(toX positionX: CGFloat) {
    guard isWaveformAreaSelecting, areaSelectDrag != nil else { return }
    areaSelectDrag?.currentX = positionX
    cancelAutoScroll()
    let resolved = marqueeAnchorFocus()
    areaSelectDrag = nil
    isWaveformAreaSelecting = false
    // Retire this drag's epoch too (not only `Began`), so a tick already resumed past its sleep bails
    // on the generation guard even before the next drag starts.
    areaSelectGeneration &+= 1
    guard let (anchor, focus) = resolved else {
      transcript.clearSelectionTapped()
      return
    }
    // Commit/reveal are NOT gated on `selectWords`' "did it change" return: the resolved IDs always
    // come from `editPlan.words`, and a release that lands on the same words the last tick set must
    // still snap the playhead and scroll the transcript.
    transcript.selectWords(anchorID: anchor, focusID: focus)
    commitMarqueePlayhead()
    transcript.revealSelection()
  }

  /// Live selection during the drag: sets the anchor/focus for the current marquee, but leaves an
  /// existing selection untouched when the marquee currently covers no word's midpoint (dragging
  /// through silence shouldn't flicker the highlight off and back on).
  private func updateMarqueeSelection() {
    guard let (anchor, focus) = marqueeAnchorFocus() else { return }
    transcript.selectWords(anchorID: anchor, focusID: focus)
  }

  /// Resolves the current drag to the anchor/focus word IDs, or nil when the marquee covers no word.
  /// The overlapped set (words whose midpoint falls in the range) is in transcript order; the drag
  /// direction decides which end is the anchor. Shift-extend keeps the pre-drag anchor and moves only
  /// the focus to the dragged edge. When the pointer is off-screen (auto-scrolling) its x is clamped
  /// to the visible edge, so the far edge is re-read from wherever the viewport has scrolled to.
  private func marqueeAnchorFocus() -> (anchor: Word.ID, focus: Word.ID)? {
    guard let drag = areaSelectDrag else { return nil }
    let fixedSample = drag.existingAnchorSample ?? drag.anchorSample
    let clampedX = min(max(0, drag.currentX), waveform.viewportWidth)
    let focusSample = clampedSample(waveform.xToSample(clampedX))
    let lower = min(fixedSample, focusSample)
    let upper = max(max(fixedSample, focusSample), lower + 1)  // never an empty range
    let ids = wordIDs(overlapping: lower..<upper, words: editPlan.words)
    guard let first = ids.first, let last = ids.last else { return nil }
    if let existing = drag.existingAnchorID {
      return (existing, focusSample >= fixedSample ? last : first)
    }
    return focusSample >= drag.anchorSample ? (first, last) : (last, first)
  }

  /// The synchronous, ordered playhead commit for a finished marquee — mirrors `rulerMovedPlayhead`:
  /// stop the transport, place the cursor at the selection start, and bump the cursor-move epoch so a
  /// deferred selection snap captured earlier in the drag bails instead of clobbering this placement.
  private func commitMarqueePlayhead() {
    guard let range = transcript.selectedSampleRange else { return }
    stopTransportForRuler()
    playheadSample = range.lowerBound
    cursorMoveGeneration &+= 1
  }

  private func isPointerPastEdge(_ positionX: CGFloat) -> Bool {
    positionX < 0 || positionX > waveform.viewportWidth
  }

  private func startAutoScrollIfNeeded() {
    guard autoScrollTask == nil else { return }
    let clock = clock
    let generation = areaSelectGeneration
    autoScrollTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await clock.sleep(for: .milliseconds(Self.autoScrollTickMs)) } catch { return }
        guard let self, self.areaSelectGeneration == generation else { return }
        // Self-terminate if the drag is no longer active (e.g. the window lost mouse tracking and no
        // `mouseUp` was delivered), rather than spinning every 16 ms for the model's lifetime.
        guard self.isWaveformAreaSelecting, self.areaSelectDrag != nil else { return }
        self.autoScrollTick()
      }
    }
  }

  private func cancelAutoScroll() {
    autoScrollTask?.cancel()
    autoScrollTask = nil
  }

  /// One auto-scroll step: pan the viewport toward the off-edge pointer, then re-extend the marquee to
  /// the newly revealed edge. Skips the selection update when the viewport didn't move (already at a
  /// document bound) so a pinned pointer doesn't emit redundant selection writes.
  private func autoScrollTick() {
    guard isWaveformAreaSelecting, let drag = areaSelectDrag, waveform.hasUsableGeometry
    else { return }
    let pixelsPerTick = autoScrollPixelsPerTick(currentX: drag.currentX)
    guard pixelsPerTick != 0 else { return }
    let before = waveform.visibleStartSample
    let deltaSamples = Int((Double(pixelsPerTick) * waveform.samplesPerPixel).rounded())
    waveform.scrolled(toStartSample: before + deltaSamples)
    guard waveform.visibleStartSample != before else { return }
    updateMarqueeSelection()
  }

  /// Signed view-pixels to pan this tick: negative past the left edge, positive past the right, 0 when
  /// the pointer is inside. Speed scales with how far past the edge the pointer is, clamped so it's
  /// smooth at any zoom (samples/tick is derived from this by the caller).
  private func autoScrollPixelsPerTick(currentX: CGFloat) -> CGFloat {
    let overshoot: CGFloat
    let direction: CGFloat
    if currentX < 0 {
      overshoot = -currentX
      direction = -1
    } else if currentX > waveform.viewportWidth {
      overshoot = currentX - waveform.viewportWidth
      direction = 1
    } else {
      return 0
    }
    let speed = min(
      Self.maxAutoScrollPixelsPerTick,
      max(Self.minAutoScrollPixelsPerTick, overshoot * Self.autoScrollGain))
    return direction * speed
  }

  private func clampedSample(_ sample: Int) -> Int {
    min(max(0, sample), waveform.totalSamples)
  }

  private func anchorSample(forWord id: Word.ID) -> Int? {
    editPlan.words.first(where: { $0.id == id })?.startSample
  }

  // swiftlint:disable function_parameter_count
  /// Wheel/trackpad on the waveform. Holding ⌘ while scrolling ⇒ cursor-anchored horizontal
  /// zoom; a plain scroll (no ⌘) ⇒ horizontal pan. ⌘ is a single modifier that a Magic Mouse
  /// swipe reliably carries, matching how Logic users reach for zoom. `optionDown` is accepted
  /// for forward-compatibility but does not affect the decision. Interpretation lives here,
  /// not the view.
  func waveformScrolled(
    deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool,
    optionDown: Bool, commandDown: Bool, atX positionX: CGFloat
  ) {
    guard deltaX.isFinite, deltaY.isFinite else { return }
    if commandDown {
      waveform.zoomByFactor(
        Self.scrollZoomFactor(deltaY: deltaY, hasPreciseDeltas: hasPreciseDeltas),
        anchoredAtX: positionX)
    } else {
      waveform.panByPixels(
        Self.scrollPanPixels(deltaX: deltaX, deltaY: deltaY, hasPreciseDeltas: hasPreciseDeltas))
    }
  }
  // swiftlint:enable function_parameter_count

  func editorKeyDown(_ key: EditorKey) -> Bool {
    switch key {
    case .zoomIn: waveform.zoomInTapped()
    case .zoomOut: waveform.zoomOutTapped()
    case .zoomFit: waveform.zoomFitToggled(selection: transcript.selectedSampleRange)
    }
    return true
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

  /// Adds an accepted suggestion's slice to the editor. Idempotent by `Slice.id` (a
  /// re-accept is a no-op), routed through `mutateSlices` so it's exportable and undoable.
  /// Known limitation: undoing/deleting the slice later does not un-accept the suggestion
  /// in the sidecar — full accept/reject reconciliation is deferred.
  func acceptCutSuggestionSlice(_ slice: Slice) {
    guard slices[id: slice.id] == nil else { return }
    mutateSlices { $0.append(slice) }
  }

  // MARK: - Reveal across panes
  /// Padding left on each side when framing a revealed range on the waveform, so the clip
  /// reads as an object with a little context rather than filling the viewport edge-to-edge.
  let waveformFramePadding = 0.1

  /// Clicking a suggestion selects its words (lighting up the transcript + waveform highlights
  /// and opening the fine-tune pane so Preview/Audition are available) and reveals it in both
  /// panes. A no-op for a suggestion with no words.
  func cutSuggestionSelected(_ suggestion: CutSuggestion) {
    revealWords(suggestion.wordIDs)
  }

  /// Clicking a saved clip reveals it the same way a suggestion does — its words are selected,
  /// the transcript scrolls to them, and the waveform zooms to frame the clip.
  func sliceRevealTapped(_ id: Slice.ID) {
    guard let slice = slices[id: id] else { return }
    revealWords(slice.wordIDs)
  }

  /// Selects the span covered by `wordIDs` then reveals it across both panes. Endpoints are the
  /// earliest and latest words by transcript position (not the array's first/last), so an
  /// unsorted or sparse `wordIDs` still frames the right range. Reveals only when the selection
  /// actually resolved — a stale item whose words are gone leaves the current view untouched
  /// instead of jumping to the previous selection.
  private func revealWords(_ wordIDs: [Word.ID]) {
    let positions = wordIDs.compactMap { id in
      editPlan.words.firstIndex(where: { $0.id == id })
    }
    // Require every word to resolve — a partially-stale item (some words gone) would otherwise
    // reveal the narrower span of the survivors, a subtly wrong jump. Leave the view put instead.
    guard positions.count == wordIDs.count,
      let lower = positions.min(), let upper = positions.max(),
      transcript.selectWords(anchorID: editPlan.words[lower].id, focusID: editPlan.words[upper].id)
    else { return }
    revealSelectionAcrossPanes()
  }

  /// Scrolls the transcript to the current selection and zooms/scrolls the waveform to frame it.
  func revealSelectionAcrossPanes() {
    transcript.revealSelection()
    zoomWaveformToSelection()
  }

  /// Zooms and scrolls the waveform to frame the current transcript selection (padded). A no-op
  /// when nothing is selected.
  func zoomWaveformToSelection() {
    guard let range = transcript.selectedSampleRange else { return }
    waveform.zoomToFit(range, paddingFraction: waveformFramePadding)
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
    if case .slice(let playing) = transportContext, slices[id: playing] == nil {
      await endTransportPlayback()
    }
    if let active = activeSliceID {
      if let slice = slices[id: active] {
        // The active slice survived but undo/redo may have moved its cut points; re-anchor the
        // session at the model level (not only via the view's onChange) when nothing is unsaved.
        let range = slice.startSample..<slice.endSample
        if !fineTune.hasUnsavedChange, fineTune.committedRange != range {
          await stopPreviewIfPlaying()  // the preview was of the old range; the pane now differs
          await stopAuditionIfPlaying()
          fineTune.begin(target: .slice(active), range: range)
        }
      } else {
        activeSliceID = nil
        fineTune.clear()
        await stopPreviewIfPlaying()
        await stopAuditionIfPlaying()
      }
    }
  }

  /// Stops a playing draft preview from an async context, ordered (awaited). No-op unless the
  /// preview is the current transport context.
  private func stopPreviewIfPlaying() async {
    guard case .draftPreview = transportContext else { return }
    await endTransportPlayback()
  }

  /// Stops an in-flight audition from an async context, ordered (awaited) — used when the active
  /// slice an audition was anchored to is removed or re-anchored, so the audition of a now-stale
  /// range doesn't keep playing to end-of-file. No-op unless an audition is the current context.
  private func stopAuditionIfPlaying() async {
    guard case .audition = transportContext else { return }
    await endTransportPlayback()
  }

  /// Convenience shortcut: play a saved slice through the one transport. Positions the cursor at the
  /// slice start, tags the context so the row highlights, and lets the global Play/Pause/Stop govern
  /// it. Refuses an empty or past-EOF range (it would no-op `play()` without superseding, orphaning
  /// current playback) before touching the player.
  func playSliceTapped(_ id: Slice.ID) async {
    guard let slice = slices[id: id] else { return }
    let playableEnd = min(slice.endSample, editPlan.source.durationSamples)
    guard slice.startSample < playableEnd else { return }
    await beginTransportPlayback(
      range: slice.startSample..<slice.endSample, context: .slice(id))
  }

  /// Stops this editor's playback for a lifecycle cleanup (tab switch/close, reimport). Clears the
  /// transport and stops only OUR session — never `stop(nil)` — so an idle editor's cleanup can't
  /// steal another tab's playback. Leaves the cursor where the audio was (not returned to origin):
  /// this is a teardown, not a user Stop.
  func stopPlaybackTapped() async {
    await endTransportPlayback()
  }

  /// Tells the transcript playback has ended or been superseded. `observePlayback` stops pushing
  /// ticks the moment the session clears, so without this the transcript's `wasPlaying` would stay
  /// true and the next slice's start wouldn't read as a rising edge — leaving follow parked in
  /// `.userPaused` if the user had scrolled away.
  private func endTranscriptFollow() {
    transcript.playheadChanged(sample: nil, isPlaying: false)
  }

  // MARK: - Transport
  let transportPlayLabel = "Play"
  let transportPauseLabel = "Pause"
  let transportStopLabel = "Stop"

  var isTransportPlaying: Bool {
    if case .playing = transportPhase { return true }
    return false
  }
  var isTransportPaused: Bool {
    if case .paused = transportPhase { return true }
    return false
  }

  /// Play is available when paused (resume) or when the cursor has somewhere to play to; never
  /// while already playing.
  var canTransportPlay: Bool {
    if isTransportPlaying { return false }
    return isTransportPaused || transportPlayableRange != nil
  }
  var canTransportPause: Bool { isTransportPlaying }
  var canTransportStop: Bool { isTransportPlaying || isTransportPaused }

  /// What a Play-from-stopped would play: from the cursor to the selection's end (if a selection
  /// is active) else end-of-audio, clamped to the file. Nil when the cursor is at/after that end,
  /// so Play is a no-op (Logic: pressing Play with the cursor past the region does nothing).
  private var transportPlayableRange: Range<Int>? {
    let end = min(
      transcript.selectedSampleRange?.upperBound ?? editPlan.source.durationSamples,
      editPlan.source.durationSamples)
    let start = playheadSample
    guard start >= 0, start < end else { return nil }
    return start..<end
  }

  /// Play button / resume. From paused, resumes the frozen session. From stopped, starts at the
  /// cursor and runs to the selection end (or end-of-audio) as plain `.free` scrubbing.
  func transportPlayTapped() async {
    switch transportPhase {
    case .playing:
      return
    case .paused(let session):
      let resumed = await audioPlayer.resume(session)
      // Stay paused if the player couldn't actually resume (e.g. an engine restart failed) so the
      // panel doesn't claim to be playing while silent; re-guard the session after the await too.
      guard transportPhase.session == session, resumed else { return }
      transportPhase = .playing(session)
      return
    case .stopped:
      break
    }
    guard let range = transportPlayableRange else { return }
    await beginTransportPlayback(range: range, context: .free)
  }

  /// The one funnel every playback flows through — plain Play (`.free`) and the slice/preview/
  /// audition shortcuts alike — so one phase machine, one cursor, and one Pause/Stop govern them.
  /// The `range` is EXPLICIT (never recomputed from the selection): the cursor is positioned at its
  /// start, `originSample` records where Stop returns, and `context` records which shortcut owns it.
  /// The `play` await stays suspended across pause/resume until stop, supersede, or natural end.
  private func beginTransportPlayback(range explicitRange: Range<Int>, context: TransportContext)
    async
  {
    // Clamp to the file so a natural finish can rest the cursor at a valid sample (callers guard
    // degenerate ranges already; this is the single safety net and the one place the cursor-at-end
    // is derived from). An empty clamp returns before superseding, so it can't orphan playback.
    let upper = min(explicitRange.upperBound, editPlan.source.durationSamples)
    let lower = max(0, min(explicitRange.lowerBound, upper))
    guard lower < upper else { return }
    let range = lower..<upper
    beginExclusivePlayback()
    let session = PlaybackSessionID()
    transportContext = context
    transportOriginSample = range.lowerBound
    transportRange = range
    playheadSample = range.lowerBound
    // A transport start authoritatively places the cursor, so it takes cursor authority too: a
    // selection snap deferred from before this Play must bail rather than stop us and snap back.
    cursorMoveGeneration &+= 1
    transportPhase = .playing(session)
    let outcome: PlaybackEnd
    do {
      outcome = try await audioPlayer.play(
        canonicalAudioURL, range, editPlan.source.sampleRate, session)
    } catch {
      reportIssue(error)
      outcome = .stopped
    }
    // Clean up only if we're still the current playback (our own Stop/supersede already replaced the
    // session). Only a natural `.finished` lands the cursor at the range end. `.superseded` here
    // means ANOTHER tab took over the shared player — our session is still set because that tab never
    // touched it — so reset the transport WITHOUT jumping the cursor to the end. A failed play
    // (`.stopped`) likewise leaves the cursor put.
    guard transportPhase.session == session else { return }
    if outcome == .finished { playheadSample = range.upperBound }
    resetTransportState()
    // Reset transcript follow here too: on a cross-tab `.superseded` (and on a natural end whose
    // final stop tick races this cleanup) `observePlayback` may never see a gated false tick, so
    // without this a slice's `wasPlaying` stays true and the next slice misses its rising edge.
    endTranscriptFollow()
  }

  /// Pause button. Freezes the cursor at the exact sample the player reports and holds the
  /// suspended `play` call in flight. Re-guards the session after the await so a pause landing
  /// after a supersession doesn't stamp a stale phase over the new owner.
  func transportPauseTapped() async {
    guard case .playing(let session) = transportPhase else { return }
    let sample = await audioPlayer.pause(session)
    guard transportPhase.session == session else { return }
    if let sample { playheadSample = sample }
    transportPhase = .paused(session)
  }

  /// Stop button. Returns the cursor to the origin, then clears the transport and stops the audio.
  /// Clearing the session (in `endTransportPlayback`) before awaiting the stop means the suspended
  /// `play`'s natural-end cleanup won't run and overwrite the origin.
  func transportStopTapped() async {
    if let origin = transportOriginSample { playheadSample = origin }
    await endTransportPlayback()
  }

  /// Clears the transport and stops the audio WITHOUT returning the cursor to origin. Used for
  /// supersession/teardown/reconciliation stops (a retarget, a removed slice, a tab close) where the
  /// user didn't press Stop, so the cursor stays where the audio left it. Stops only OUR session so
  /// a delayed cleanup can't kill newer/global playback.
  private func endTransportPlayback() async {
    let session = transportPhase.session
    resetTransportState()
    endTranscriptFollow()
    await stopOwnedPlayback(session)
  }

  /// Space (Logic parity): Play/Stop toggle. Every owner now runs through the transport, so a
  /// non-stopped phase means something is playing — stop it (to origin); paused resumes; otherwise
  /// start from the cursor.
  func transportPlayStopTapped() async {
    if isTransportPlaying {
      await transportStopTapped()
    } else {
      await transportPlayTapped()  // resumes when paused, starts from the cursor when stopped
    }
  }

  /// Selection reconciliation, driven by `EditorView.onChange(of: transcript.selectedSampleRange)`.
  /// A new selection snaps the cursor to its start; clearing the selection leaves the cursor put.
  /// Any active playback is stopped first — the cursor never jumps while audio keeps playing.
  ///
  /// `onChange` spawns one unstructured task per selection change, so two can overlap: after
  /// awaiting the stop, bail if a newer selection has arrived — OR if a new playback started while
  /// we were stopping (a slice/preview/audition shortcut, which doesn't touch the selection). Either
  /// way the stale task must not snap the cursor over the newer state or into a live playback.
  func transportSelectionChanged(_ newRange: Range<Int>?, cursorToken: Int) async {
    guard let newRange else { return }
    // A marquee drag emits a live selection change on every pointer move; suppress the snap for the
    // duration of the drag so it doesn't churn the transport. `waveformAreaSelectEnded` commits the
    // playhead once, synchronously, when the drag finishes.
    guard !isWaveformAreaSelecting else { return }
    // Bail BEFORE touching playback if the cursor has been placed by a later action — a ruler move or
    // a transport start — since this selection change was registered. `cursorToken` is captured
    // synchronously in the view's `onChange`, so a ruler click or a Play that ran before this deferred
    // task fires makes this stale: it must neither snap over that placement nor stop that new playback.
    guard cursorMoveGeneration == cursorToken else { return }
    if transportPhase.session != nil {
      await endTransportPlayback()
      // Re-check across the stop await: a newer selection, a new playback, or a ruler move (which
      // bumps the generation) all invalidate this snap.
      guard transcript.selectedSampleRange == newRange, transportPhase.session == nil,
        cursorMoveGeneration == cursorToken
      else { return }
    }
    playheadSample = newRange.lowerBound
  }

  // MARK: - Ruler
  /// Ruler click/drag: positions the persistent cursor at the ruler's view-x, mapping x → plan
  /// sample via the shared waveform geometry (clamped to `[0, durationSamples]`). No drag-to-scrub
  /// while playing in v1 — a ruler interaction during playback (or while paused) stops the transport
  /// first, mirroring the selection-snap rule, leaving the cursor where the user placed it rather
  /// than where the audio was. The cursor move is SYNCHRONOUS and ordered, so a fast drag lands it
  /// on the last event's sample (no stale-async-task race); the audio stop is fire-and-forget on OUR
  /// session so a delayed cleanup can't kill newer or global playback. A no-op until the waveform
  /// geometry is loaded — before that the x→sample mapping is meaningless.
  func rulerMovedPlayhead(toX positionX: CGFloat) {
    guard waveform.hasUsableGeometry else { return }
    stopTransportForRuler()
    playheadSample = clampedRulerSample(positionX)
    cursorMoveGeneration &+= 1
  }

  /// Snapshot of the cursor-move counter, captured synchronously by the view when the transcript
  /// selection changes and handed to `transportSelectionChanged`. It lets a deferred selection snap
  /// tell whether a ruler placement has since taken authority over the cursor.
  var cursorMoveToken: Int { cursorMoveGeneration }

  /// Tears down any active transport — playing OR paused — for a ruler move. A paused session still
  /// owns scheduled audio, so without this a later Play would `resume` the old paused audio instead
  /// of playing from the newly placed cursor. Resets ownership synchronously (so `observePlayback`
  /// stops applying ticks at once, and the suspended `beginTransportPlayback` guard fails, never
  /// jumping the cursor to the range end) and stops OUR session off the main actor — exactly the
  /// `cancelPreviewOrAuditionIfNeeded` pattern.
  private func stopTransportForRuler() {
    guard let session = transportPhase.session else { return }
    resetTransportState()
    endTranscriptFollow()
    Task { await stopOwnedPlayback(session) }
  }

  /// The ruler's view-x mapped to a plan sample, clamped to a valid cursor position. `durationSamples`
  /// (end-of-audio) is inclusive: it's a legal resting cursor where Play is a correct no-op.
  private func clampedRulerSample(_ positionX: CGFloat) -> Int {
    min(max(0, waveform.xToSample(positionX)), editPlan.source.durationSamples)
  }

  // MARK: - Fine-tune editing
  /// Opens the fine-tune pane on a slice and starts an edit session anchored to its current
  /// range. Choosing the slice explicitly (rather than from ambient state) is what makes it
  /// the edit target.
  func sliceSelected(_ id: Slice.ID) {
    // Re-selecting the already-active slice is a true no-op: don't clear a selection that may be
    // held pending behind a dirty edit, which would otherwise be lost.
    guard activeSliceID != id else { return }
    // Switching away would abandon an unsaved cut edit — of either an existing slice OR a tuned
    // pending selection — so require Save or Cancel first.
    guard !fineTune.hasUnsavedChange else { return }
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
      // Don't tear down ANY unsaved edit (existing-slice or tuned pending selection) just because
      // the target went nil — the user must Save or Cancel first.
      if fineTune.target != nil, !fineTune.hasUnsavedChange {
        cancelPreviewOrAuditionIfNeeded()  // closing the pane removes the region + Stop control
        fineTune.clear()
      }
      return
    }
    // Never abandon an unsaved edit by retargeting — a new transcript selection arriving mid-edit,
    // for either a slice edit (target changes) or a tuned pending draft (the anchor range drifts).
    // The held draft is preserved until the user Saves or Cancels.
    if fineTune.hasUnsavedChange, fineTune.target != target || fineTune.committedRange != range {
      return
    }
    // Re-anchor when the target changed, no session is open, or the anchor range drifted from the
    // committed baseline with nothing unsaved (a casual re-selection before any tuning, or the
    // active slice restored by undo). An in-progress draft only changes `draftRange`, never
    // `committedRange`, so a live drag never trips this.
    let shouldBegin =
      fineTune.target != target || fineTune.committedRange == nil
      || fineTune.committedRange != range
    if shouldBegin {
      // Retargeting to a different session must not leave an old preview playing — the new pane
      // would show "Stop preview" and the playhead would follow the stale range.
      cancelPreviewOrAuditionIfNeeded()
      // A transcript selection taking over releases the previously active slice, so clearing the
      // selection later doesn't silently reopen the pane on a stale slice.
      if case .pendingSelection = target { activeSliceID = nil }
      fineTune.begin(target: target, range: range)
    }
  }

  /// Stops an in-progress preview or audition when the fine-tune session retargets or closes away
  /// from it, so the pane label, status line, and playhead don't keep claiming a range the editor no
  /// longer shows. Clears the transport synchronously (so the label/ownership update at once), then
  /// stops the audio on a task capturing the session first — the player actor gates `stop(session)`,
  /// so a stale cancel can never stop newer or global playback (what the old generation tokens
  /// guarded). A no-op unless a preview or audition is the current context.
  private func cancelPreviewOrAuditionIfNeeded() {
    switch transportContext {
    case .draftPreview, .audition: break
    case .free, .slice: return
    }
    let session = transportPhase.session
    resetTransportState()
    endTranscriptFollow()
    Task { await stopOwnedPlayback(session) }
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
    guard canCommitEdit, let draft = fineTune.draftRange, let target = fineTune.target
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
      // Closing the pane removes the region, so stop any preview or audition of the draft first.
      cancelPreviewOrAuditionIfNeeded()
      fineTune.clear()
      transcript.clearSelectionTapped()
    }
    syncEditSession()
  }

  /// Drops the unsaved change, leaving the pane open on the committed range. Stops any preview
  /// first — it was playing the now-discarded draft — then re-syncs so a selection made (but
  /// held) during the edit can take over the pane.
  func cancelEditTapped() {
    cancelPreviewOrAuditionIfNeeded()
    fineTune.resetDraft()
    syncEditSession()
  }

  /// The preview button reflects playback state so a single control both starts and stops it.
  var previewButtonLabel: String {
    if case .draftPreview = transportContext { return fineTune.previewStopLabel }
    return fineTune.previewEditLabel
  }

  /// Preview is a transport shortcut: tapping while it's the playing context stops the one transport,
  /// otherwise it starts the preview.
  func previewToggleTapped() async {
    if case .draftPreview = transportContext {
      await transportStopTapped()
    } else {
      await previewEditTapped()
    }
  }

  /// Preview the in-progress draft (falls back to the committed range) through the one transport,
  /// tagged `.draftPreview` so the slice rows don't highlight. Refuses an empty or past-EOF range
  /// (it would no-op `play()` without superseding, orphaning current playback) before touching the
  /// player.
  func previewEditTapped() async {
    guard let range = fineTune.draftRange ?? fineTune.committedRange else { return }
    let playableEnd = min(range.upperBound, editPlan.source.durationSamples)
    guard range.lowerBound < playableEnd else { return }
    await beginTransportPlayback(range: range, context: .draftPreview)
  }

  // MARK: - Audition
  let auditionPreRollSeconds = 2.0
  let auditionInButtonLabel = "▶ In  ["
  let auditionOutButtonLabel = "]  Out ▶"

  /// Samples of pre-roll for the out-cut audition, from the plan sample rate.
  private var auditionPreRollSamples: Int {
    max(0, Int(auditionPreRollSeconds * Double(editPlan.source.sampleRate)))
  }
  /// The region drawn on the waveform, if it's a non-empty range worth auditioning. Clamped to
  /// the file's duration so a corrupt slice/selection range past EOF can't produce a range the
  /// player silently clamps to empty, leaving stale audio playing.
  private var auditionRegion: Range<Int>? {
    guard let region = activeEditingRange else { return nil }
    let upper = min(region.upperBound, editPlan.source.durationSamples)
    let lower = min(region.lowerBound, upper)
    guard lower < upper else { return nil }
    return lower..<upper
  }
  var canAudition: Bool { auditionRegion != nil }
  var isAuditioningIn: Bool { transportContext == .audition(.cutIn) }
  var isAuditioningOut: Bool { transportContext == .audition(.cutOut) }
  var auditionStatusText: String? {
    switch transportContext.auditionMode {
    case .cutIn: return "Auditioning in-cut — Space to stop"
    case .cutOut: return "Auditioning out-cut — Space to stop"
    case .none: return nil
    }
  }

  /// In-cut: drop in at the region's start and play forward to end-of-file, through the one
  /// transport. A toggle: tapping while it's the active audition stops it; tapping the other edge
  /// switches (supersedes).
  func auditionInTapped() async {
    if transportContext == .audition(.cutIn) {
      await transportStopTapped()
      return
    }
    guard let region = auditionRegion else { return }
    let end = editPlan.source.durationSamples
    guard region.lowerBound < end else { return }
    await beginTransportPlayback(range: region.lowerBound..<end, context: .audition(.cutIn))
  }

  /// Out-cut: play a pre-roll ending exactly at the region's out-point, stopping on the cut, through
  /// the one transport. A toggle, mirroring `auditionInTapped`. The pre-roll may begin before the
  /// region's own start (clamped at 0).
  func auditionOutTapped() async {
    if transportContext == .audition(.cutOut) {
      await transportStopTapped()
      return
    }
    guard let region = auditionRegion else { return }
    let end = region.upperBound
    let start = max(0, end - auditionPreRollSamples)
    await beginTransportPlayback(range: start..<end, context: .audition(.cutOut))
  }

  /// Routes a captured key to its action so the key-monitor view stays logic-free. `[`/`]`
  /// audition the cut edges (toggling off if already active); Space is the transport Play/Stop
  /// (Logic parity) — it stops whatever plays and otherwise starts the transport from the cursor.
  func auditionKeyPressed(_ key: AuditionKey) async {
    switch key {
    case .cutIn: await auditionInTapped()
    case .cutOut: await auditionOutTapped()
    case .space: await transportPlayStopTapped()
    }
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
    displaySliceSnippet(text)
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
    buildSlice(id: UUID(), name: "Slice \(nextSliceNumber)", range: range, plan: editPlan)
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

  /// Points a line-based mouse wheel "click" is worth (trackpads report pixel-precise deltas
  /// already). Pan/zoom sensitivity constants; on-screen direction verified in QA.
  private static let pointsPerScrollLine: CGFloat = 40
  private static let pixelsPerZoomDouble = 300.0

  private static func scrollPanPixels(
    deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool
  ) -> CGFloat {
    let primary = abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
    return hasPreciseDeltas ? primary : primary * pointsPerScrollLine
  }

  private static func scrollZoomFactor(deltaY: CGFloat, hasPreciseDeltas: Bool) -> Double {
    let dy = Double(hasPreciseDeltas ? deltaY : deltaY * pointsPerScrollLine)
    // spp *= factor; scrolling "away" should zoom in (spp < 1). Flip the sign in QA if inverted.
    return pow(2.0, -dy / pixelsPerZoomDouble)
  }
}

/// The interview transport's phase. `playing`/`paused` carry the session that owns the audio,
/// so a stale tick or a superseding owner can be told apart from the current one.
enum TransportPhase: Equatable {
  case stopped
  case playing(PlaybackSessionID)
  case paused(PlaybackSessionID)

  /// The session backing this phase, or nil when stopped.
  var session: PlaybackSessionID? {
    switch self {
    case .stopped: return nil
    case .playing(let session), .paused(let session): return session
    }
  }
}

/// Which convenience shortcut (if any) owns the current transport playback — the collapse of the
/// three former playback owners (`playingSliceID`, `isPreviewingDraft`, `audition`) into one value.
/// `.free` is plain scrubbing; the others let the derived display props reflect what's playing.
enum TransportContext: Equatable {
  case free
  case slice(Slice.ID)
  case draftPreview
  case audition(EditorModel.AuditionMode)

  /// True while a saved slice is the playing context — the only context that drives transcript
  /// auto-scroll follow and the slice-row "playing" highlight.
  var isSlice: Bool {
    if case .slice = self { return true }
    return false
  }
  /// The playing slice's id, or nil when a slice isn't the current context.
  var sliceID: Slice.ID? {
    if case .slice(let id) = self { return id }
    return nil
  }
  /// The auditioning boundary, or nil when an audition isn't the current context.
  var auditionMode: EditorModel.AuditionMode? {
    if case .audition(let mode) = self { return mode }
    return nil
  }
}

/// The two panes the editor's right column can show.
enum RightPanelTab: String, CaseIterable, Identifiable, Equatable {
  case slices
  case suggestions
  var id: String { rawValue }
}

struct SliceRowState: Identifiable, Equatable {
  var id: Slice.ID
  var name: String
  var durationLabel: String
  var rangeLabel: String
  var snippet: String
  var isTight: Bool
  var warningLabel: String
  var warningHelp: String
  var isPlaying: Bool
  var playButtonLabel: String
  var isActive: Bool
  var canFineTune: Bool
}

/// The identity of a fine-tune edit session — the active slice, or a live transcript
/// selection. When this changes the view asks the model to reconcile the open session.
struct FineTuneSessionKey: Equatable {
  var activeSliceID: Slice.ID?
  var activeSliceRange: Range<Int>?
  var selection: Range<Int>?
}

/// Transient state for an in-progress waveform marquee drag. `anchorSample` is the fixed edge in
/// plan samples (captured once, so a mid-drag zoom/resize can't move it); `currentX` is the live
/// dragged edge in view coordinates. For a Shift-extend, `existingAnchorSample`/`existingAnchorID`
/// hold the pre-drag selection anchor that the extend must preserve.
private struct WaveformAreaSelectDrag {
  var anchorSample: Int
  var currentX: CGFloat
  var existingAnchorID: Word.ID?
  var existingAnchorSample: Int?
}
