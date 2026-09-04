import Dependencies
import Foundation
import IdentifiedCollections
import IssueReporting
import Observation
import Sharing

/// The editor-global shortcuts the key monitor can deliver. PR 2 adds transport cases here.
enum EditorKey {
  case zoomIn
  case zoomOut
  case zoomFit
  case speedUp
  case speedDown
  case removeSection
  /// Nudges a pending removal's cut points by `FineTuneModel.nudgeMs` before commit — the
  /// forced-alignment word boundaries the removal starts from can blur ~10-20ms into a
  /// neighbor's tail/onset (Task 9).
  case nudgeCutInEarlier
  case nudgeCutInLater
  case nudgeCutOutEarlier
  case nudgeCutOutLater
  /// Deselects a selected crossfade seam (decision 6). Consumed only when a seam is selected,
  /// so it falls through otherwise (e.g. to dismiss a sheet).
  case escape
}

@MainActor
@Observable
final class EditorModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.audioPlayer) var audioPlayer
  @ObservationIgnored @Dependency(\.engine) var engine
  @ObservationIgnored @Dependency(\.exportRender) var exportRender
  @ObservationIgnored @Dependency(\.workspace) var workspace
  @ObservationIgnored @Dependency(\.continuousClock) var clock

  // MARK: - Shared State
  /// The per-file project sidecar, keyed by `sourceFingerprint` — the same store
  /// `cutSuggestions` shares, so both stay backed by one file. Only `timelineRemovals`
  /// is written through here; the sidecar's other sections are `cutSuggestions`' concern.
  @ObservationIgnored @Shared var projectState: ProjectState
  /// The user's global clip-boundary offset preference (Settings → Editing) — nudges every
  /// NEW clip's cut points by up to ±50 ms. Read only by `appendNewClip`; manual boundary
  /// re-edits never consult these.
  @ObservationIgnored @Shared(.clipStartOffsetMs) var clipStartOffsetMs: Double
  @ObservationIgnored @Shared(.clipEndOffsetMs) var clipEndOffsetMs: Double

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
  /// The EDITED (collapsed) waveform the main lane renders and hit-tests on: it owns its own
  /// viewport and maps view-x ↔ source/edited samples through `editedTimeline`. `waveform` stays
  /// source-pure (fine-tune insets + the slice-edit modal still read it). With zero removals the
  /// timeline is identity, so this is behaviorally identical to the source axis.
  var editedWaveform: EditedWaveformAdapter
  var fineTune: FineTuneModel
  var cutSuggestions: CutSuggestionsPageModel
  /// The slice-detail edit modal, presented when non-nil. A separate, scoped model — distinct
  /// from `fineTune`, which drives the docked pane — so the two can't fight over one session.
  var editSlice: EditSliceModel?

  init(sourceURL: URL, canonicalAudioURL: URL, editPlan: EditPlan, sourceFingerprint: String? = nil)
  {
    self.sourceURL = sourceURL
    self.canonicalAudioURL = canonicalAudioURL
    self.editPlan = editPlan
    let fingerprint = sourceFingerprint ?? ("path:" + sourceURL.standardizedFileURL.path)
    self.sourceFingerprint = fingerprint
    self.transcript = TranscriptPageModel(editPlan: editPlan)
    let waveformModel = WaveformModel()
    self.waveform = waveformModel
    self.editedWaveform = EditedWaveformAdapter(
      source: waveformModel,
      timeline: EditedTimeline(
        sourceDurationSamples: editPlan.source.durationSamples, removals: []))
    self.fineTune = FineTuneModel(
      sampleRate: editPlan.source.sampleRate, durationSamples: editPlan.source.durationSamples,
      silences: editPlan.silences)
    // Constructed within the ambient dependency context of this init (the parent wraps
    // `EditorModel(...)` in `withDependencies(from:)`), so the child inherits the same deps.
    self.cutSuggestions = CutSuggestionsPageModel(
      editPlan: editPlan, sourceFingerprint: fingerprint)
    _projectState = Shared(.projectState(fingerprint: fingerprint))
    super.init()
    self.timelineRemovals = Self.validatedRemovals(
      projectState.timelineRemovals, sourceDurationSamples: editPlan.source.durationSamples)
    syncEditedTimeline()
    // Accepting a suggestion adds its slice here (idempotently), through the shared
    // mutation funnel so it's exportable and undoable like any other slice.
    cutSuggestions.onAcceptSlice = { [weak self] slice in
      self?.acceptCutSuggestionSlice(slice)
    }
    // Clicking a suggestion reveals it across both panes so the user can review/audition it.
    cutSuggestions.onSelectSuggestion = { [weak self] suggestion in
      self?.cutSuggestionSelected(suggestion)
    }
    // The speed control lives in the transcript panel, but the transport owns the shared player, so
    // apply its changes here — live while playing and remembered for the next play. Each change
    // applies the model's LATEST committed rate (not the value that triggered this callback), so
    // two rapid changes whose Tasks reach the player out of order still converge on the newest.
    transcript.onPlaybackRateChanged = { [weak self] _ in
      Task { await self?.applyPlaybackRate() }
    }
    // Text-selection gestures are now intents: the transcript resolves which words the gesture hit
    // and hands them here, and THIS model writes the authoritative freeform `audioSelection`. Wired
    // on the model (not a view `.onChange`) so headless model tests apply intents without a view.
    // One-directional — the model never writes the transcript's selection back through this.
    transcript.onSelectionIntent = { [weak self] intent in
      guard let self else { return }
      switch intent {
      case .words(let anchor, let focus): self.selectWords(anchorID: anchor, focusID: focus)
      case .word(let id, let extending): self.selectWord(id, extending: extending)
      case .clear: self.clearSelection()
      }
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
  /// Removed source ranges (with their crossfades) that collapse the timeline. Mutated
  /// only through `mutateDocument`, alongside `slices`, so the two move together on undo.
  var timelineRemovals: IdentifiedArrayOf<TimelineRemoval> = []
  /// Undo/redo history over the document (`slices` + `timelineRemovals`) — never
  /// selection, zoom, playback, or export phase. Every document mutation routes
  /// through `mutateDocument`, which records here.
  var documentUndo = UndoStack<EditorDocumentState>()
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
  /// THE persistent, always-visible playhead cursor, in EDITED-timeline samples — the collapsed
  /// axis the main lane renders. Always edited: with zero removals the timeline is the identity
  /// map, so the value equals the plan/source sample; consumers that need source data convert via
  /// `playheadSourceSample`. Follows audio during playback and stays put when stopped/paused
  /// (never hidden). Kept a SEPARATE observed property (not folded into a transport struct) so its
  /// ~30 Hz updates don't invalidate views that read `transportPhase`/`transportContext` (the
  /// panel, the slice list).
  var playheadEditedSample = 0 {
    didSet {
      cursorSourceAnchor = placingSourceSample
      syncCurrentWordToCursor()
    }
  }

  /// The SOURCE sample under the cursor — the boundary value for anything that reasons about the
  /// original recording (word lookup, transcript follow, the slice-edit modal). A source-axis
  /// cursor placement remembers its EXACT sample (`cursorSourceAnchor`); otherwise the edited
  /// position maps through the timeline, where a seam's overlap zone resolves to the incoming
  /// (post-cut) side — matching what edited playback makes audible.
  var playheadSourceSample: Int {
    cursorSourceAnchor ?? editedWaveform.timeline.editedToSource(playheadEditedSample)
  }

  /// The edited-axis cursor position for a SOURCE sample. Total: outside removals it is the exact
  /// mapped position; inside a removed span the `.rightEdge` bias resolves to the seam's crossfade
  /// start — the edited moment the audio after the cut first becomes audible. The fallback only
  /// fires for a defensively out-of-range input.
  func editedCursor(forSource sourceSample: Int) -> Int {
    let timeline = editedWaveform.timeline
    return timeline.sourceToEdited(sourceSample, bias: .rightEdge)
      ?? min(max(0, sourceSample), timeline.editedDurationSamples)
  }

  /// The EXACT source sample of the most recent SOURCE-axis cursor placement, nil after any
  /// edited-axis write (`didSet` maintains it). Read through `playheadSourceSample` instead of
  /// the lossy edited→source round trip: inside a crossfade's outgoing tail (or a removed span)
  /// the round trip resolves to the post-cut side, which would hand the word highlight and the
  /// slice-edit modal a position the source playback hasn't reached.
  @ObservationIgnored private var cursorSourceAnchor: Int?
  /// Set only for the duration of a `placeCursor(atSource:)` assignment so the cursor's `didSet`
  /// can distinguish a source-axis placement (anchor kept) from an edited-axis write (cleared).
  @ObservationIgnored private var placingSourceSample: Int?

  /// Places the cursor for a SOURCE-axis position: stores the mapped edited sample while
  /// remembering the exact source sample rather than round-tripping through the edited axis.
  /// Every consumer that knows its true source position (ticks, pause freezes, selection snaps,
  /// the modal's seek) funnels through here.
  private func placeCursor(atSource sourceSample: Int) {
    placingSourceSample = sourceSample
    defer { placingSourceSample = nil }
    playheadEditedSample = editedCursor(forSource: sourceSample)
  }

  /// Returns the cursor to where the transport last started: through the origin's exact source
  /// sample for a source-range playback (a plain edited restore would clear the source anchor
  /// and round-trip an in-tail origin to the post-cut side), or the edited origin for
  /// edited-timeline playback.
  private func returnCursorToTransportOrigin() {
    if let sourceOrigin = transportOriginSourceAnchor {
      placeCursor(atSource: sourceOrigin)
    } else if let origin = transportOriginEditedSample {
      playheadEditedSample = origin
    }
  }

  /// Keeps the transcript's current-word highlight on the word under the cursor, so it tracks
  /// where you ARE — playing, paused, scrubbed, ruler-moved, or stopped — never a stale
  /// last-heard word. Keeps the last word in a gap (never lose your place) and only writes on a
  /// real change so a 30 Hz cursor doesn't churn the transcript view.
  private func syncCurrentWordToCursor() {
    guard let word = wordID(atSample: playheadSourceSample), word != transcript.currentWordID
    else { return }
    transcript.currentWordID = word
  }
  /// Where the transport last started playing, in EDITED samples; Stop returns the cursor here.
  var transportOriginEditedSample: Int?
  /// The EXACT source sample of a source-range playback's origin (nil for edited-timeline
  /// playback). Stop and the timeline remap restore through it, so an origin inside a
  /// crossfade tail or removed span isn't round-tripped to the post-cut side.
  @ObservationIgnored private var transportOriginSourceAnchor: Int?
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
  /// Names of slices skipped by the most recent "Export all" because their entire audio
  /// fell inside a removed section — surfaced by `exportSkippedRemovedWarning`.
  private var lastExportSkippedRemovedNames: [String] = []
  @ObservationIgnored private(set) var exportTask: Task<Void, Never>?

  /// Maps between source and edited sample coordinates given the current removals.
  /// Cheap to construct; rebuilt from `timelineRemovals` on every read rather than cached.
  var editedTimeline: EditedTimeline {
    EditedTimeline(
      sourceDurationSamples: editPlan.source.durationSamples,
      removals: Array(timelineRemovals))
  }

  /// The undoable document snapshot: `slices` and `timelineRemovals` together.
  private var documentState: EditorDocumentState {
    EditorDocumentState(slices: slices, timelineRemovals: timelineRemovals)
  }

  /// Rebuilds the edited timeline the collapsed waveform renders on from the current removals,
  /// then re-clamps the adapter's viewport into the new edited duration (never resetting zoom).
  /// Called from every path that changes `timelineRemovals` (the mutation funnel, undo/redo, and
  /// the initial sidecar seed), so the axis and the document can never drift apart.
  ///
  /// The cursor (and the transport origin, if one is live) is stored in EDITED samples, so a
  /// timeline change would silently re-point the same number at different audio. Remap both
  /// through the SOURCE moment they marked — captured against the old timeline, re-resolved
  /// against the new — so they keep pointing at the same instant of the recording.
  ///
  /// A live session whose audio was built from the OLD removal set is stale: letting it run
  /// would reinterpret its ticks against the new axis (free play) or keep playing audio the
  /// document no longer contains (a slice). Stop it — the mirror of the ruler/selection
  /// "stop, then act" rule — leaving the cursor where the remap puts it.
  /// `playbackDependsOnChangedRemovals` decides which sessions that covers.
  private func syncEditedTimeline() {
    // Drop a seam selection whose removal is gone (restore, undo, redo) before anything reads it.
    // Runs ahead of the timeline-equality guard so a stale selection is always reconciled, even in
    // the (impossible-in-practice) case where the removals changed but the collapsed timeline
    // compares equal.
    if let selectedSeamID, timelineRemovals[id: selectedSeamID] == nil {
      self.selectedSeamID = nil
    }
    // Drop a live stretch draft whose seam is gone — its preview would target a removal the
    // timeline no longer has. (Reconciled here for the same reason as the selection above.) Undo
    // the draft's viewport compensation first, so the rebuild below re-clamps from the pre-drag
    // scroll position rather than a shifted one.
    if let crossfadeStretchDraft, timelineRemovals[id: crossfadeStretchDraft.id] == nil {
      editedWaveform.visibleStartSample = crossfadeStretchDraft.frozenVisibleStart
      self.crossfadeStretchDraft = nil
    }
    let newTimeline = editedTimeline
    guard newTimeline != editedWaveform.timeline else { return }
    // Captured BEFORE `resetTransportState` clears `transportContext` to `.free` below — it's the
    // only way to know, after the reset, whether the session we just killed belonged to the sheet.
    var wasSliceEditPlayback = false
    if let session = transportPhase.session, playbackDependsOnChangedRemovals() {
      if case .sliceEdit = transportContext { wasSliceEditPlayback = true }
      resetTransportState()
      endTranscriptFollow()
      Task { await stopOwnedPlayback(session) }
    }
    let sourceCursor = playheadSourceSample
    // A source-range playback's origin keeps its exact source anchor; only an edited-axis
    // origin (already stopped above for free play) falls back to the lossy round trip.
    let sourceOrigin =
      transportOriginSourceAnchor
      ?? transportOriginEditedSample.map(editedWaveform.timeline.editedToSource)
    editedWaveform.timeline = newTimeline
    editedWaveform.timelineChanged()
    placeCursor(atSource: sourceCursor)
    transportOriginEditedSample = sourceOrigin.map(editedCursor(forSource:))
    // Fan the same timeline into an open slice-edit sheet so its collapsed lane reflects the change
    // (a removal / undo / redo on the main timeline) immediately, re-pinned to the slice's new span.
    editSlice?.syncTimeline(newTimeline)
    // The reset above killed the sheet's own session, but its position loop died with it — nothing
    // else ever ticks `isPlaying`/`activeAudition` back to false, so the sheet would otherwise get
    // stuck showing an active Play/Pause or audition state with no audio. Publish "stopped" now.
    if wasSliceEditPlayback {
      editSlice?.updatePlayback(sample: editSlice?.playheadSample, isPlaying: false)
    }
  }

  /// Whether the live playback's audio was built from the removal set that just changed. Free
  /// play always was — its playlist IS the edited timeline. A slice session depends only on the
  /// removals inside its own range: a playlist session is stale once its slice-local timeline no
  /// longer matches what it scheduled, and a raw source-range slice session becomes wrong the
  /// moment a removal first lands inside the slice (it would keep playing audio export now
  /// cuts). Preview/audition sessions stay deliberately source-faithful and keep playing; the
  /// Edit Slice modal is removal-aware and resets like a saved slice.
  private func playbackDependsOnChangedRemovals() -> Bool {
    if case .free = transportContext { return true }
    // The Edit Slice modal previews the collapsed (removal-aware) audio, so it must reset like a
    // saved-slice session; its slice is the open sheet's, since `.sliceEdit` carries no id.
    let contextSliceID: Slice.ID?
    if case .sliceEdit = transportContext {
      contextSliceID = editSlice?.sliceID
    } else {
      contextSliceID = transportContext.sliceID
    }
    guard let sliceID = contextSliceID, let slice = slices[id: sliceID] else {
      return false
    }
    let newLocal = SliceRenderPlanBuilder.localTimeline(
      sliceRange: slice.startSample..<slice.endSample, removals: Array(timelineRemovals))
    guard let scheduled = slicePlaybackConversion?.localTimeline else {
      return !newLocal.removals.isEmpty
    }
    return newLocal != scheduled
  }

  // MARK: - Display Text
  let markAsClipLabel = "Mark as Clip"
  let clearButtonLabel = "Clear"
  let scrollToCurrentWordLabel = "Scroll to current word"
  let emptyStateMessage = "Select words in the transcript, then Mark as Clip."
  let playLabel = "Play"
  let stopLabel = "Stop"
  let deleteLabel = "Delete slice"
  let editSliceLabel = "Edit"
  let exportLabel = "Export"
  let exportAllLabel = "Export all"
  let cancelExportLabel = "Cancel export"
  /// Shown when the canonical AIFF backing this session has vanished before a render —
  /// e.g. cleared by an app update or a second window's launch cleanup. Re-importing
  /// re-materializes it. Named as user-facing copy, not an engine error, on purpose.
  let canonicalMissingMessage =
    "The working audio for this file is no longer available — it can be cleared by an app "
    + "update or another window. Re-import the file to export again."
  let undoLabel = "Undo"
  let redoLabel = "Redo"
  let removedBadgeLabel = "Removed"
  let removedBadgeHelp =
    "This clip's audio is entirely inside a removed section — there is nothing to export."
  let slicesTabLabel = "Clips"
  let suggestionsTabLabel = "Suggestions"
  let rightPanelPickerLabel = "Right panel"
  let revealClipLabel = "Reveal clip in transcript and waveform"
  let restoreRemovedAudioLabel = "Restore Removed Audio"
  /// The mark-clip bar's readout when a crossfade seam (not a word range) is selected.
  let crossfadeSelectedSummary = "Crossfade selected"

  // MARK: - Fine-tune session
  /// The active slice's committed range, if a slice is open in the pane.
  var activeSliceRange: Range<Int>? {
    guard let activeSliceID, let slice = slices[id: activeSliceID] else { return nil }
    return slice.startSample..<slice.endSample
  }
  /// The range a fresh edit session would start from — aligned with `fineTuneTarget`: the
  /// transcript selection takes precedence, else the active slice.
  var activeOrSelectedRange: Range<Int>? { selectedSourceRange ?? activeSliceRange }
  /// The one range the main waveform overlay tracks — the live draft while dragging, else the
  /// active/selected range. The waveform doesn't care whether it's pending, slice-backed, or
  /// mid-drag.
  var activeEditingRange: Range<Int>? { fineTune.draftRange ?? activeOrSelectedRange }

  // MARK: - Selection (source samples — the single source of truth)
  /// The freeform selected range in SOURCE samples. Plain @Observable — not @Shared, not in the
  /// undo stack. During migration it is SEEDED from the transcript selection; later tasks flip the
  /// writers so this becomes authoritative and the transcript derives from it.
  var audioSelection: Range<Int>?
  /// The fixed edge held during a marquee / shift-extend (set in Task 6).
  var selectionAnchorSample: Int?
  /// The edge currently being drag-edited (set in Task 8).
  var selectionEditingEdge: SelectionEdge?

  // MARK: - Seam selection
  /// The crossfade seam currently selected, identified by its removal's id (a `TimelineSeam`'s id
  /// IS its `TimelineRemoval`'s id). A peer of `audioSelection` and MUTUALLY EXCLUSIVE with it
  /// (decision 6): selecting a seam clears the freeform selection, and any freeform-selection write
  /// clears the seam. Plain @Observable transient view state — like `audioSelection`, it is not part
  /// of the undo-tracked document. Kept valid by `syncEditedTimeline`, which drops it when the
  /// removal it points at no longer exists (restore, undo, redo).
  var selectedSeamID: TimelineRemoval.ID?

  /// Selects the crossfade seam for removal `id`, mutually exclusive with the range selection:
  /// clears any freeform selection first, then records the seam. A no-op if that removal doesn't
  /// exist. Unlike a body click this does NOT move the playhead — Logic selects a crossfade on
  /// click without seeking.
  ///
  /// It deliberately does NOT inline-clear the fine-tune session here. `selectSourceRange` (the
  /// range-selection path) doesn't either: both leave fine-tune reconciliation to the single
  /// onChange-driven `syncEditSession()`, which is the one place that knows how to tear down a
  /// pending tuned selection without clobbering an unsaved existing-slice edit. Adding an inline
  /// `fineTune.clear()` on just this path would diverge from that centralization and reintroduce the
  /// unsaved-slice hazard `syncEditSession()` exists to avoid.
  func selectSeam(_ id: TimelineRemoval.ID) {
    guard timelineRemovals[id: id] != nil else { return }
    clearSelection()
    selectedSeamID = id
  }

  /// A click (or context-click) that landed on a seam's bowtie. Selects it.
  func seamClicked(_ id: TimelineRemoval.ID) {
    selectSeam(id)
  }

  /// Drops the seam selection (Escape). Idempotent.
  func deselectSeam() {
    selectedSeamID = nil
  }

  /// The live edge-drag stretch of a seam's crossfade (`CrossfadeStretchDraft`): non-nil only for
  /// the duration of a drag. The document is untouched while it lives — `seamOverlays` previews the
  /// bowtie from it, and `crossfadeStretchEnded` is the one place that commits.
  private(set) var crossfadeStretchDraft: CrossfadeStretchDraft?

  /// Read facade every downstream reader migrates onto (spec §6). Backed by `audioSelection`.
  var selectedSourceRange: Range<Int>? { audioSelection }

  /// A text-view selection intent: the covered word span (first word's start → last word's end,
  /// ordered by transcript position) becomes an exact source range and seeds the freeform selection.
  func selectWords(anchorID: Word.ID, focusID: Word.ID) {
    guard let range = sourceRange(coveringWords: anchorID, focusID) else { return }
    selectionAnchorSample =
      anchorHoldSample(anchorID: anchorID, focusID: focusID) ?? range.lowerBound
    selectSourceRange(range, snapPlayhead: true, origin: .transcript)
  }

  /// The anchor word's far-from-focus edge, so a later Shift-extend pivots from where the drag began
  /// (Logic's "anchor stays put, focus moves"). A right-to-left selection (anchor after focus) must
  /// hold the anchor's END, not the range's lower bound — otherwise the next extension pivots off the
  /// wrong edge. Nil when either word lacks bounds, letting the caller fall back to `range.lowerBound`.
  private func anchorHoldSample(anchorID: Word.ID, focusID: Word.ID) -> Int? {
    guard let anchorRange = sourceRange(ofWord: anchorID),
      let anchorPos = editPlan.words.firstIndex(where: { $0.id == anchorID }),
      let focusPos = editPlan.words.firstIndex(where: { $0.id == focusID })
    else { return nil }
    return anchorPos <= focusPos ? anchorRange.lowerBound : anchorRange.upperBound
  }

  /// A single-word intent: select the word's exact `[startSample, endSample)`. `extending` (Shift)
  /// stretches the current selection from its held anchor to the clicked word instead of replacing.
  func selectWord(_ id: Word.ID, extending: Bool) {
    if extending, let anchor = selectionAnchorSample ?? audioSelection?.lowerBound,
      let wordRange = sourceRange(ofWord: id)
    {
      selectSourceRange(
        min(anchor, wordRange.lowerBound)..<max(anchor, wordRange.upperBound), snapPlayhead: false,
        origin: .transcript)
    } else if let wordRange = sourceRange(ofWord: id) {
      selectionAnchorSample = wordRange.lowerBound
      selectSourceRange(wordRange, snapPlayhead: true, origin: .transcript)
    }
  }

  /// The exact source range of one word, or nil if it has no monotonic sample bounds.
  private func sourceRange(ofWord id: Word.ID) -> Range<Int>? {
    guard let word = editPlan.words.first(where: { $0.id == id }),
      let start = word.startSample, let end = word.endSample, start < end
    else { return nil }
    return start..<end
  }

  /// The source range spanning two words — the earlier word's start to the later word's end — so a
  /// selection from `a` to `b` covers everything between them regardless of drag direction.
  private func sourceRange(coveringWords lhs: Word.ID, _ rhs: Word.ID) -> Range<Int>? {
    guard let left = sourceRange(ofWord: lhs), let right = sourceRange(ofWord: rhs) else {
      return nil
    }
    return min(left.lowerBound, right.lowerBound)..<max(left.upperBound, right.upperBound)
  }

  /// What the fine-tune pane binds to: a live transcript selection takes precedence (a fresh
  /// selection is a new-slice intent that retargets the pane), else the active slice.
  /// `sliceSelected` clears the selection so an edited slice cleanly becomes the driver.
  var fineTuneTarget: FineTuneModel.Target? {
    if selectedSourceRange != nil { return .pendingSelection }
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
    case .pendingSelection:
      // A pending selection commits as a NEW slice, so it must clear the same word-overlap bar as
      // the direct Add path (`canAddSlice`): a silence-only draft would build a slice with no words.
      // `commitEditTapped` guards on this, so the commit path can't append a wordless slice either.
      guard let draft = fineTune.draftRange else { return false }
      return !wordIDs(anyOverlap: draft, words: editPlan.words).isEmpty
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
      selection: selectedSourceRange)
  }

  /// True only while an EXISTING slice has an unsaved cut edit — the user must Save or Cancel
  /// before exporting or undo/redo (a pending-selection draft is a new slice, not a mutation,
  /// and export never renders it, so it doesn't gate). Also true while the Edit Slice sheet holds
  /// an unsaved boundary draft: that draft is the modal's deferred existing-slice edit, so ⌘Z from
  /// inside the sheet must be blocked exactly as a docked draft blocks it here — otherwise undo
  /// would rewind `slices` under the modal's live draft.
  var hasUncommittedSliceEdit: Bool {
    (fineTune.isEditingExistingSlice && fineTune.hasUnsavedChange)
      || (editSlice?.fineTune.hasUnsavedChange ?? false)
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
  var highlightedSampleRange: Range<Int>? { selectedSourceRange }

  /// Sample ranges of the run-together words, reading the transcript's already-computed
  /// `runTogetherSampleRanges`. Retained analysis — no longer painted on the waveform — kept
  /// so a future feature (e.g. revealing tight joins while dragging) can surface it again.
  /// Words missing sample bounds are excluded.
  var redRanges: [Range<Int>] { transcript.runTogetherSampleRanges }

  // MARK: - Removed words (transcript)
  /// Words struck through in the transcript because their ENTIRE `[startSample, endSample)` lies
  /// inside a removed section — the spec's strikethrough predicate ("no audio of this word
  /// survives the removal"). A word only partially clipped by a removal is NOT struck (it still
  /// sounds). Derived from `timelineRemovals`, so a removal or its undo both update this without
  /// any separate bookkeeping.
  var removedWordIDs: Set<Word.ID> {
    Set(
      timelineRemovals.flatMap { wordIDs(fullyContainedIn: $0.removedRange, words: editPlan.words) }
    )
  }

  // MARK: - Selection highlight (transcript)
  /// Words the transcript highlights because any of their audio intersects the freeform
  /// `audioSelection` — the spec's overlap predicate ("is any of this word still heard?"). Derived
  /// from the authoritative selection and pushed into `transcript` by the view, so a freeform
  /// (non-word-aligned) selection highlights the partially-covered words at its edges too. Empty
  /// when there's no selection.
  var selectedWordIDs: Set<Word.ID> {
    audioSelection.map { Set(wordIDs(anyOverlap: $0, words: editPlan.words)) } ?? []
  }

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
    // The Suggestions panel's show/hide toggle mutes the suggestion overlay without touching the
    // ranked list: when it's off, no suggested bands are drawn (accepted slices stay put).
    guard cutSuggestions.showsSuggestionBands else { return approved }
    let claimed = Set(approved.flatMap(\.wordIDs))
    let suggested = cutSuggestions.pendingSuggestions.compactMap {
      suggestion -> TranscriptClipBand? in
      let unclaimed = suggestion.wordIDs.filter { !claimed.contains($0) }
      guard !unclaimed.isEmpty else { return nil }
      return TranscriptClipBand(id: suggestion.id, wordIDs: unclaimed, kind: .suggested)
    }
    return approved + suggested
  }

  /// Waveform render data, geometry delegated to the edited adapter (the view reads these; it
  /// decides nothing). The highlight tracks `activeEditingRange` — a SOURCE range — so it follows
  /// a fine-tune drag live and collapses correctly around any removed spans it straddles.
  var waveformHighlightSpan: WaveformSpan? {
    activeEditingRange.flatMap { editedWaveform.span(forSource: $0) }
  }

  /// View-x of the persistent cursor on the edited axis, or nil when it's scrolled out of the
  /// viewport. The model owns the cursor's EDITED sample; the adapter supplies the geometry, so
  /// the view stays logic-free.
  var playheadX: CGFloat? { editedWaveform.playheadX(forEdited: playheadEditedSample) }

  // MARK: - Seam overlays
  /// The bowtie spans the lane draws at each seam, mapped to edited view coordinates by the
  /// adapter (nil, and so dropped, only for an off-screen seam; a fully-clamped hard cut still
  /// yields a zero-width marker so it stays visible and selectable). A model computed
  /// prop so the view only binds — it never derives waveform geometry. Reads the adapter's
  /// already-synced `editedTimeline` (kept current by `syncEditedTimeline()` on every removal
  /// change) rather than rebuilding one, since `editedTimeline` constructs a fresh value on
  /// every read.
  var seamOverlays: [SeamOverlay] {
    editedWaveform.timeline.seams.compactMap { seam in
      guard let span = editedWaveform.spanForSeam(seam) else { return nil }
      let handles = editedWaveform.seamHandleXs(seam, previewLength: nil)
      return SeamOverlay(
        id: seam.id, span: span, isSelected: seam.id == selectedSeamID,
        leadingHandleX: handles.leading, trailingHandleX: handles.trailing)
    }
  }

  /// Widens each bowtie's clickable target by a few points on each side, so a short crossfade
  /// (a hair wide at low zoom) is still selectable.
  private static let seamHitTolerance: CGFloat = 4

  /// Hit-testing lives here (the view only reports x): the removal id whose bowtie the view-x
  /// lands on, or nil. Walks the same drawn seams the lane renders; a zero-length hard cut has a
  /// zero-width span, so the tolerance below is what makes it clickable. Only a fully off-screen
  /// seam has no span and so isn't hittable. When more than one seam's widened target covers the
  /// x — abutting removals that collapse onto the same join, or two crossfades closer than the
  /// tolerance — the one whose bowtie center is nearest the click wins, so every removal stays
  /// individually reachable rather than the first-drawn one always shadowing the rest.
  func seamID(atX positionX: CGFloat) -> TimelineRemoval.ID? {
    var best: (id: TimelineRemoval.ID, distance: CGFloat)?
    for seam in editedWaveform.timeline.seams {
      guard let span = editedWaveform.spanForSeam(seam) else { continue }
      guard positionX >= span.positionX - Self.seamHitTolerance,
        positionX <= span.positionX + span.width + Self.seamHitTolerance
      else { continue }
      let distance = abs(positionX - (span.positionX + span.width / 2))
      if best == nil || distance < best!.distance {
        best = (seam.id, distance)
      }
    }
    return best?.id
  }

  /// The right-click menu for a waveform position: the Restore item when the x hits a seam's
  /// bowtie, empty otherwise. Context-clicking a seam also SELECTS it (Logic selects on
  /// context-click), so the menu, the ⌫ key, and the panel button all act on the same seam.
  func seamContextMenuItems(atX positionX: CGFloat) -> [WaveformMenuItem] {
    guard let id = seamID(atX: positionX) else { return [] }
    selectSeam(id)
    return [
      WaveformMenuItem(title: restoreRemovedAudioLabel) { [weak self] in
        self?.restoreRemoval(id: id)
      }
    ]
  }

  // MARK: - View Helpers
  /// The panel's plain "Add slice" builds from the raw selection, so it's disabled whenever any
  /// fine-tune draft is unsaved — a tuned pending selection (whose adjustments it would discard)
  /// or a dirty existing-slice edit with a held selection (which requires Save/Cancel first). A
  /// silence-only selection (a marquee over a gap that overlaps no word) also disables it: it would
  /// derive no word IDs, so `addSliceTapped()` would no-op, leaving the button enabled but inert.
  var canAddSlice: Bool {
    guard let range = selectedSourceRange else { return false }
    return !wordIDs(anyOverlap: range, words: editPlan.words).isEmpty
      && !fineTune.hasUnsavedChange
  }
  /// Clear is offered whenever a freeform selection exists — including a marquee/edge-drag one that
  /// never touched the transcript. `audioSelection` is the source of truth; reading it here (not
  /// `transcript.hasSelection`) is what keeps the bar live for waveform-created selections.
  var canClearSelection: Bool { audioSelection != nil }
  /// The bar's word-count readout, derived from the freeform selection so it stays accurate for
  /// every selection path. Counts words the range overlaps (the same set the transcript highlights);
  /// a silence-only selection reads "0 words selected".
  var selectionSummary: String {
    if selectedSeamID != nil { return crossfadeSelectedSummary }
    guard let range = audioSelection else { return "No selection" }
    let count = wordIDs(anyOverlap: range, words: editPlan.words).count
    return "\(count) word\(count == 1 ? "" : "s") selected"
  }
  // Undo/redo restore `slices` wholesale; doing that under an open cut edit would leave the
  // draft anchored to a stale committed range, so gate on Save/Cancel first. Blocked during
  // an export for the same reason `canRemoveSelectedSection` is: the document that gated the
  // export is the one being written to disk, and rewinding it mid-run would leave the
  // finished AIFFs stale relative to what the user sees.
  var canUndo: Bool { documentUndo.canUndo && !hasUncommittedSliceEdit && !isExporting }
  var canRedo: Bool { documentUndo.canRedo && !hasUncommittedSliceEdit && !isExporting }

  var sliceCountLabel: String {
    "\(slices.count) \(slices.count == 1 ? "clip" : "clips")"
  }

  var isExporting: Bool {
    if case .exporting = exportPhase { return true }
    return false
  }
  var canExportAll: Bool {
    !slices.isEmpty && !isExporting && !hasUncommittedSliceEdit && editedTimeline.isValid
      && slices.contains(where: sliceIsExportable)
  }
  var canExportSlice: Bool {
    !isExporting && !hasUncommittedSliceEdit && editedTimeline.isValid
  }

  /// Whether `slice` has any audio left to export once removals collapse the timeline —
  /// false only when the slice's entire source range sits inside one or more removals.
  func sliceIsExportable(_ slice: Slice) -> Bool {
    // A malformed slice (reversed bounds) must read as unexportable, not trap forming the
    // range — this runs from `sliceRows` on every render, long before `renderTargets`
    // reaches its own `invalidSliceRange` check.
    guard slice.startSample < slice.endSample else { return false }
    return SliceRenderPlanBuilder.localTimeline(
      sliceRange: slice.startSample..<slice.endSample, removals: Array(timelineRemovals)
    ).editedDurationSamples > 0
  }

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

  /// After a successful "Export all", names the slices that were skipped because their
  /// entire audio fell inside a removed section. Empty otherwise, and never shown for a
  /// single-slice export (that path already refuses via `sliceIsExportable` before
  /// starting, so there's nothing to report after the fact).
  var exportSkippedRemovedWarning: String {
    guard case .done = exportPhase, !lastExportSkippedRemovedNames.isEmpty else { return "" }
    let names = lastExportSkippedRemovedNames.joined(separator: ", ")
    let verb = lastExportSkippedRemovedNames.count == 1 ? "was" : "were"
    return "\(names) \(verb) skipped — entirely inside a removed section."
  }

  var showsExportStatus: Bool { !exportStatusMessage.isEmpty }
  var showsCancelExport: Bool { isExporting }

  /// Defensive, not routine: the mutation funnel normalizes every removal it accepts, so
  /// `editedTimeline` is normally valid whenever `timelineRemovals` is non-empty. But if a
  /// corrupt persisted removal set ever slipped past that funnel (e.g. loaded straight from
  /// a stale sidecar), `EditedTimeline` would silently degrade to the identity mapping —
  /// which would reintroduce the "removed" audio into every export. Export must refuse
  /// outright rather than risk shipping that, so this is the one place export re-checks
  /// validity directly instead of trusting the funnel (the BINDING PR-2 Codex contract).
  var removalsInvalidNote: String? {
    editedTimeline.isValid
      ? nil
      : "Removed sections failed validation — export is disabled. Undo the last change or remove them."
  }

  var sliceRows: IdentifiedArrayOf<SliceRowState> {
    let sampleRate = editPlan.source.sampleRate
    return IdentifiedArray(
      uniqueElements: slices.map { slice in
        let canExport = sliceIsExportable(slice)
        return SliceRowState(
          id: slice.id,
          name: slice.name,
          durationLabel: sampleDurationLabel(
            slice.endSample - slice.startSample, sampleRate: sampleRate),
          rangeLabel: "\(sampleTimecodeLabel(slice.startSample, sampleRate: sampleRate)) – "
            + sampleTimecodeLabel(slice.endSample, sampleRate: sampleRate),
          snippet: slice.snippet,
          // The row highlights while its slice is the transport's context; the button is a pure
          // Play shortcut now (no per-slice Stop — the global transport owns Pause/Stop, ruling F).
          isPlaying: transportContext.sliceID == slice.id,
          playButtonLabel: playLabel,
          isActive: activeSliceID == slice.id,
          // The fine-tune button switches the edit target, which `sliceSelected` rejects while
          // another draft is unsaved — disable it then so it doesn't look broken when clicked.
          canFineTune: !fineTune.hasUnsavedChange || activeSliceID == slice.id,
          canExport: canExport,
          removedLabel: canExport ? "" : removedBadgeLabel,
          removedHelp: canExport ? "" : removedBadgeHelp
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
    // The lane's `.onGeometryChange` fits the adapter once the viewport is measured, but a load
    // that completes AFTER layout must re-settle the viewport too — mirror `WaveformModel.load`.
    // `viewportResized` only (re)fits when no zoom is set yet, so a user zoom during the decode
    // window survives.
    if editedWaveform.viewportWidth > 0 {
      editedWaveform.viewportResized(width: editedWaveform.viewportWidth)
    }
    // A slice sheet opened WHILE the file was still decoding adopted a nil/empty waveform (a
    // one-time snapshot, unlike the old live column closure). Now that the decode is done, seed
    // that open sheet so its lane and insets fill in instead of staying blank for its lifetime.
    reseedEditSliceWaveformIfNeeded()
  }

  /// Re-seeds an open slice sheet's lane from the now-decoded waveform, but only when that sheet's
  /// lane is still empty (opened mid-decode). A sheet opened after the decode already shows its
  /// waveform, so the guard skips it — a lane the user has zoomed/scrolled over real data is never
  /// re-fit. (A mid-decode lane draws nothing, so snapping it to frame the slice when the audio
  /// finally arrives is the intended reveal, not a lost interaction.)
  private func reseedEditSliceWaveformIfNeeded() {
    guard let editSlice, waveform.showsWaveform, !editSlice.waveform.showsWaveform else { return }
    editSlice.waveform.adopt(
      waveform: waveform.waveform, totalSamples: waveform.totalSamples,
      sampleRate: waveform.sampleRate, contentRange: editSlice.overviewWindow)
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
        // The cursor lives on the EDITED axis: an edited tick (playlist playback) is stored
        // as-is; a source tick (range playback) converts on arrival. The modal/transcript
        // boundaries keep reading SOURCE samples either way.
        let sourceSample: Int
        switch position.sample {
        case .edited(let editedSample):
          sourceSample = applyEditedPlaybackSample(editedSample)
        case .source(let source):
          placeCursor(atSource: source)
          sourceSample = source
        }
        // The slice-detail edit modal owns its own scoped playhead/transcript while it's the
        // playback context, so push the live position into it here — the modal has no other way
        // to see ticks from the shared player.
        if case .sliceEdit = transportContext {
          editSlice?.updatePlayback(sample: sourceSample, isPlaying: true)
        }
        // The listen contexts (a plain Play and slice playback) drive transcript auto-scroll
        // follow, so reading along works during a plain Play, not only slice playback. Preview/
        // audition update the cursor (and thus the highlight) but must not yank the transcript
        // from where the user scrolled.
        transcript.playheadChanged(
          sample: sourceSample, isPlaying: transportContext.followsTranscript)
      } else {
        if transportContext.followsTranscript {
          // A false tick ends transcript follow (so the next playback reads as a rising edge) but
          // leaves the cursor and the current-word highlight where the audio stopped.
          endTranscriptFollow()
        }
        if case .sliceEdit = transportContext {
          editSlice?.updatePlayback(sample: playheadSourceSample, isPlaying: false)
        }
      }
    }
  }

  /// Lands an EDITED-axis playback sample (a tick or a pause freeze) on the cursor and returns the
  /// SOURCE sample it represents.
  ///
  /// The main edited-timeline playback reports on the cursor's own axis, so it stores as-is. A
  /// slice playlist reports on its SLICE-LOCAL axis instead — a number that would point at
  /// unrelated audio if stored directly — so it converts back to an absolute source sample and
  /// goes through `placeCursor`, which keeps the global edited cursor, the exact source anchor,
  /// the transcript's current-word highlight and follow all correct through the same path the
  /// old source ticks used. Inside a seam `editedToSource` resolves to the post-cut side, which
  /// is exactly what the blended audio is making audible at that moment.
  @discardableResult
  private func applyEditedPlaybackSample(_ editedSample: Int) -> Int {
    guard let conversion = slicePlaybackConversion else {
      playheadEditedSample = editedSample
      return playheadSourceSample
    }
    let source = conversion.sliceStart + conversion.localTimeline.editedToSource(editedSample)
    placeCursor(atSource: source)
    return source
  }

  /// Clears the transport owner so a new playback can take over: it resets the phase/context/range
  /// to stopped (dropping the previous session, so the old suspended `play`'s post-await guard fails
  /// and its cleanup no-ops) and resets transcript follow so the new play reads as a rising edge. It
  /// never resets `playheadEditedSample` — the persistent cursor survives supersession. Callers set
  /// the new session/context *after* this, via `beginTransportPlayback`.
  private func beginExclusivePlayback() {
    endTranscriptFollow()
    resetTransportState()
  }

  /// Clears every field of the transport's ownership state (phase/context/origin/range) back to the
  /// stopped/`.free` baseline — never touching `playheadEditedSample`. The single place transport
  /// state resets, so a future field can't be missed by one of the several cleanup paths.
  private func resetTransportState() {
    transportPhase = .stopped
    transportContext = .free
    transportOriginEditedSample = nil
    transportOriginSourceAnchor = nil
    slicePlaybackConversion = nil
  }

  /// Stops the given session, or does nothing if it's nil. A nil session means THIS editor
  /// owns no playback, so there is nothing of ours to stop — and calling `stop(nil)` would
  /// stop whatever is playing globally, stealing another tab's playback. Every model stop path
  /// routes through here so an idle editor's cleanup (close tab, reimport) can't steal.
  private func stopOwnedPlayback(_ session: PlaybackSessionID?) async {
    guard let session else { return }
    await audioPlayer.stop(session)
  }

  /// Waveform click at view-x writes `audioSelection` directly in exact SOURCE samples. A plain
  /// click selects the containing word's exact `[startSample, endSample)` (a convenience seed — the
  /// stored range is the word's real bounds, never a snap of a drag) and snaps the playhead there;
  /// Shift extends the current freeform selection to the clicked sample. A click landing in a gap
  /// (no word contains it) clears the selection.
  func waveformClicked(atX positionX: CGFloat, extending: Bool) {
    // A plain click on a bowtie selects the seam (Logic selects a crossfade on click). Shift-click
    // is a range-extend gesture, so it skips the seam test and falls through to selection.
    if !extending, let seam = seamID(atX: positionX) {
      seamClicked(seam)
      return
    }
    let sample = editedWaveform.xToSourceSample(positionX)
    // Shift-click extends from an existing anchor. With no anchor and no live selection there is
    // nothing to extend, so fall through to plain-click behavior (select the containing word) —
    // matching Logic, and avoiding a degenerate `sample..<sample` that would clear instead.
    if extending, let anchor = selectionAnchorSample ?? audioSelection?.lowerBound {
      selectSourceRange(min(anchor, sample)..<max(anchor, sample), snapPlayhead: false)
      return
    }
    guard let wordID = wordID(atSample: sample),
      let word = editPlan.words.first(where: { $0.id == wordID }),
      let start = word.startSample, let end = word.endSample
    else {
      // A click in empty space deselects everything, including a selected seam.
      clearSelection()
      selectedSeamID = nil
      return
    }
    selectionAnchorSample = start
    selectSourceRange(start..<end, snapPlayhead: true)
    revealSourceRange(start..<end)
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
    guard editedWaveform.hasUsableGeometry else { return }
    // A marquee writes `audioSelection` live from its first move; drop any seam selection up front
    // so the two never coexist (decision 6).
    selectedSeamID = nil
    cancelAutoScroll()
    areaSelectGeneration &+= 1
    // Shift-extend keeps the pre-drag anchor edge (in source samples), so only the focus moves.
    let existingAnchorSample =
      extending ? (selectionAnchorSample ?? audioSelection?.lowerBound) : nil
    let anchor = clampedSample(editedWaveform.xToSourceSample(startX))
    areaSelectDrag = WaveformAreaSelectDrag(
      anchorSample: anchor, currentX: startX, existingAnchorSample: existingAnchorSample)
    selectionAnchorSample = existingAnchorSample ?? anchor
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

  /// Release: stops any auto-scroll, then commits the exact dragged source range to `audioSelection`,
  /// snapping the playhead to its start (claiming cursor authority so a straggler snap can't undo it)
  /// and scrolling the transcript to the range's first overlapping word. Freeform — the committed
  /// range is the raw dragged samples, never snapped to word edges. A degenerate (empty) range clears.
  func waveformAreaSelectEnded(toX positionX: CGFloat) {
    guard isWaveformAreaSelecting, areaSelectDrag != nil else { return }
    areaSelectDrag?.currentX = positionX
    cancelAutoScroll()
    let range = marqueeSourceRange()
    areaSelectDrag = nil
    isWaveformAreaSelecting = false
    // Retire this drag's epoch too (not only `Began`), so a tick already resumed past its sleep bails
    // on the generation guard even before the next drag starts.
    areaSelectGeneration &+= 1
    if let range {
      selectSourceRange(range, snapPlayhead: true)
      revealSourceRange(range)
    } else {
      clearSelection()
    }
  }

  /// Live selection during the drag: writes the exact dragged source range to `audioSelection` on
  /// every pointer move — freeform, no word snap.
  private func updateMarqueeSelection() {
    audioSelection = marqueeSourceRange()
  }

  /// The exact SOURCE range for the current drag: the fixed edge (the drag anchor, or the preserved
  /// Shift-extend anchor) to the live dragged edge, in source samples. Floors to a 1-sample span so a
  /// drag is never empty. When the pointer is off-screen (auto-scrolling) its x is clamped to the
  /// visible edge, so the far edge is re-read from wherever the viewport has scrolled to. Nil only
  /// when there is no active drag.
  private func marqueeSourceRange() -> Range<Int>? {
    guard let drag = areaSelectDrag else { return nil }
    let fixed = drag.existingAnchorSample ?? drag.anchorSample
    let clampedX = min(max(0, drag.currentX), editedWaveform.viewportWidth)
    let focus = clampedSample(editedWaveform.xToSourceSample(clampedX))
    let lower = min(fixed, focus)
    let upper = max(max(fixed, focus), lower + 1)  // never an empty range
    return lower..<upper
  }

  /// Where a `selectSourceRange` write came from. A `.transcript` write is driven by a transcript
  /// gesture that has *already* set the transcript's own anchor/focus, so the funnel must preserve
  /// them. Every other write (`.external` — waveform click/marquee, slice/suggestion reveal) replaces
  /// the freeform selection without any transcript gesture, leaving the transcript's private
  /// anchor/focus pointing at the selection the user just replaced; the funnel drops that stale anchor.
  enum SelectionOrigin { case transcript, external }

  /// Sets the freeform selection to an exact SOURCE range and (optionally) snaps the playhead to its
  /// start, mirroring `rulerMovedPlayhead`: stop the transport, place the cursor, and bump the
  /// cursor-move epoch so a deferred selection snap captured earlier in the drag bails instead of
  /// clobbering this placement. An empty/degenerate range clears. This is the single write path the
  /// waveform (marquee + click), slice/suggestion reveal, and transcript intents all funnel through.
  func selectSourceRange(
    _ range: Range<Int>, snapPlayhead: Bool, origin: SelectionOrigin = .external
  ) {
    // A freeform-selection write and a seam selection are mutually exclusive (decision 6): any
    // range write drops the seam. This is the single range-write funnel, so clearing here covers
    // every caller (transcript, marquee end, word click, reveal).
    selectedSeamID = nil
    // Clamp to the file's real extent so a selection built from bad word bounds (a word whose
    // `endSample` overruns the audio) can never persist an out-of-file removal that revalidation
    // silently drops on reload. `selectSourceRange` is the single write path, so clamping here
    // guards every caller; in-bounds selections are unchanged.
    let lower = max(0, range.lowerBound)
    let upper = min(range.upperBound, editPlan.source.durationSamples)
    guard lower < upper else {
      // Clear everything, not just `audioSelection`: a leftover `selectionAnchorSample` /
      // `selectionEditingEdge` would let a later Shift gesture extend from a selection the user
      // just cleared.
      clearSelection()
      return
    }
    audioSelection = lower..<upper
    // Keep the Shift-extend pivot on a stored edge. Snap it to the NEAREST stored boundary — not just
    // clamp into range — for two reasons: (1) callers pin the anchor to an *unclamped* selection edge
    // that the range above may have clamped into `[0, durationSamples]` (bad word bounds); (2) a
    // Shift-extend whose target word straddles the anchor yields a range that contains the anchor on
    // both sides, which a plain clamp would leave as an interior sample. Snapping keeps the invariant
    // that the anchor is always one of the two stored edges — funnel-enforced, not caller discipline —
    // which is what lets `applyEdgeEdit`'s exact-boundary repair stay exhaustive. For an anchor already
    // on a boundary (the common case) this is identity.
    if let anchor = selectionAnchorSample {
      if anchor <= lower {
        selectionAnchorSample = lower
      } else if anchor >= upper {
        selectionAnchorSample = upper
      } else {
        // Interior anchor: both differences are within the stored range, so this can't overflow even
        // for a wildly out-of-file `anchor` (those hit the guards above before any subtraction).
        selectionAnchorSample = (anchor - lower <= upper - anchor) ? lower : upper
      }
    }
    if origin == .external {
      // A non-transcript write replaced the selection without a transcript gesture, so the
      // transcript's private anchor/focus still identify the *previous* selection. Drop them, or a
      // later transcript re-click of that word toggles it off (thinking it's still the sole
      // selection) and a Shift-click extends from the stale anchor — resurrecting a selection the
      // user already replaced. Transcript-origin writes keep their anchor (the gesture just set it).
      transcript.invalidateSelectionAnchor()
    }
    if snapPlayhead {
      stopTransportForRuler()
      placeCursor(atSource: lower)
      cursorMoveGeneration &+= 1
    }
  }

  /// Clears the freeform selection and any in-progress selection-edit state. The rendered transcript
  /// highlight derives from `audioSelection` (the source of truth), so clearing that clears the
  /// highlight. But the transcript keeps a *gesture* anchor for Shift-click extension, which is not
  /// derived — so we also invalidate it here. Otherwise a later transcript Shift-click would extend
  /// from the anchor of the selection the user just cleared, resurrecting it.
  func clearSelection() {
    audioSelection = nil
    selectionAnchorSample = nil
    selectionEditingEdge = nil
    transcript.invalidateSelectionAnchor()
  }

  /// The Clear button in the mark-clip bar. Drops the freeform selection whatever created it —
  /// transcript click/drag, waveform marquee, or edge drag — since all of them live in `audioSelection`.
  func clearSelectionTapped() {
    clearSelection()
  }

  /// Scrolls the transcript to frame a freeform source range by revealing its first overlapping word,
  /// and (when `zoomWaveform`) zooms the waveform to the current selection. The waveform now owns the
  /// selection directly, so `transcript.revealSelection()` (which read the transcript's own selection)
  /// no longer applies. A range overlapping no word scrolls nowhere.
  ///
  /// `zoomWaveform` defaults to false: the marquee-release and plain-click paths reveal scroll-only
  /// (Logic never zooms on a marquee release — see the waveform-area-select design), while the
  /// suggestion/clip/reveal-words callers opt in to `zoomWaveform: true` to frame the target.
  func revealSourceRange(_ range: Range<Int>, zoomWaveform: Bool = false) {
    guard let wordID = wordIDs(anyOverlap: range, words: editPlan.words).first else { return }
    transcript.revealWord(wordID)
    if zoomWaveform { zoomWaveformToSelection() }
  }

  // MARK: - Selection edge editing (drag handles + nudge)
  /// The raw two-boundary edge math for the primary selection, built from the plan (whole file as the
  /// window, no magnified inset) and reusing `FineTuneModel`'s min-duration / snap-threshold constants
  /// so drag and nudge feel identical to the slice-edit sheet. `snap:false` is the primary path.
  var boundaryEditor: BoundaryRangeEditor {
    BoundaryRangeEditor(
      fileDurationSamples: editPlan.source.durationSamples, sampleRate: editPlan.source.sampleRate,
      minDurationSamples: Int(fineTune.minSliceMs / 1000 * Double(editPlan.source.sampleRate)),
      snapThresholdSamples: Int(
        fineTune.snapThresholdMs / 1000 * Double(editPlan.source.sampleRate)),
      silences: editPlan.silences)
  }

  /// A left/right handle grab begins: mark which edge is live so `transportSelectionChanged` stops
  /// churning the playhead for the duration of the drag (mirrors the marquee's `isWaveformAreaSelecting`
  /// suppression). An edge drag is fine-tune, not seek — it never snaps the playhead.
  func selectionEdgeDragBegan(_ edge: SelectionEdge) { selectionEditingEdge = edge }

  /// A handle drag to view-x: map x → source sample and move only that edge, freeform (no silence
  /// snap). The opposite edge stays fixed; the min-duration floor keeps the range from collapsing.
  func selectionEdgeDragged(_ edge: SelectionEdge, toX posX: CGFloat) {
    selectionEdgeDraggedToSource(edge, editedWaveform.xToSourceSample(posX))
  }

  /// Geometry-free seam behind `selectionEdgeDragged(_:toX:)`: take an exact SOURCE sample directly so
  /// tests exercise the edge math without a viewport (mirrors the marquee's sample-level seams).
  func selectionEdgeDraggedToSource(_ edge: SelectionEdge, _ sourceSample: Int) {
    guard let range = audioSelection else { return }
    // No pre-clamp: `boundaryEditor` already clamps `sourceSample` into the legal window
    // (`0...fileDurationSamples`) via `clampedBoundary`. Clamping here against
    // `waveform.totalSamples` would wrongly couple this geometry-free seam to async waveform load.
    applyEdgeEdit(
      edge, of: range,
      to: edge == .start
        ? boundaryEditor.moveStart(of: range, to: sourceSample, snap: false)
        : boundaryEditor.moveEnd(of: range, to: sourceSample, snap: false))
  }

  /// Commits an edge edit and keeps `selectionAnchorSample` pinned to the edge it already tracks: if
  /// the held anchor sat on the edited edge, it follows that edge to its new sample. Otherwise a later
  /// Shift-extend would pivot from the pre-edit boundary and silently restore audio the user just
  /// trimmed. When the anchor tracks the untouched edge (or is nil), it stays valid and is left alone.
  ///
  /// The exact-boundary test is exhaustive because `selectionAnchorSample` is *always* a boundary of
  /// the current selection (or nil): every selection-replacing writer pins it to an edge, Shift-extend
  /// keeps it as the fixed edge, and `selectSourceRange` snaps it onto the nearest stored boundary
  /// (covering clamped ranges and extends whose target word straddles the anchor). So the anchor sits
  /// on either the edited edge (follow it) or the untouched edge (leave it) — it can never be a stale
  /// interior sample the repair would miss.
  private func applyEdgeEdit(_ edge: SelectionEdge, of old: Range<Int>, to updated: Range<Int>) {
    let anchorTracksEditedEdge =
      edge == .start
      ? selectionAnchorSample == old.lowerBound
      : selectionAnchorSample == old.upperBound
    audioSelection = updated
    if anchorTracksEditedEdge {
      selectionAnchorSample = edge == .start ? updated.lowerBound : updated.upperBound
    }
    // An edge edit replaces the freeform selection without a transcript gesture, so the transcript's
    // private toggle/extend anchor still identifies the *pre-edit* word (same staleness the `.external`
    // branch of `selectSourceRange` drops). Invalidate it here too, or a later transcript re-click of
    // that word toggles the edited selection off, and a Shift-click extends from the stale word.
    transcript.invalidateSelectionAnchor()
  }

  /// Release: the edge is no longer live, so transport-snap resumes tracking selection changes.
  func selectionEdgeDragEnded(_ edge: SelectionEdge) { selectionEditingEdge = nil }

  /// Moves one edge of the selection by a signed millisecond delta (the ←/→/⇧←/⇧→ 10 ms nudges),
  /// freeform. No-op with no selection.
  func selectionNudged(_ edge: SelectionEdge, byMs ms: Double) {
    guard let range = audioSelection else { return }
    applyEdgeEdit(
      edge, of: range,
      to: edge == .start
        ? boundaryEditor.nudgeStart(of: range, byMs: ms)
        : boundaryEditor.nudgeEnd(of: range, byMs: ms))
  }

  private func isPointerPastEdge(_ positionX: CGFloat) -> Bool {
    positionX < 0 || positionX > editedWaveform.viewportWidth
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
    guard isWaveformAreaSelecting, let drag = areaSelectDrag, editedWaveform.hasUsableGeometry
    else { return }
    let pixelsPerTick = autoScrollPixelsPerTick(currentX: drag.currentX)
    guard pixelsPerTick != 0 else { return }
    let before = editedWaveform.visibleStartSample
    let deltaSamples = Int((Double(pixelsPerTick) * editedWaveform.samplesPerPixel).rounded())
    editedWaveform.scrolled(toStartEditedSample: before + deltaSamples)
    guard editedWaveform.visibleStartSample != before else { return }
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
    } else if currentX > editedWaveform.viewportWidth {
      overshoot = currentX - editedWaveform.viewportWidth
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
    editedWaveform.scrolled(
      deltaX: deltaX, deltaY: deltaY, hasPreciseDeltas: hasPreciseDeltas,
      optionDown: optionDown, commandDown: commandDown, atX: positionX)
  }
  // swiftlint:enable function_parameter_count

  func editorKeyDown(_ key: EditorKey) -> Bool {
    switch key {
    case .zoomIn: editedWaveform.zoomInTapped()
    case .zoomOut: editedWaveform.zoomOutTapped()
    case .zoomFit: editedWaveform.zoomFitToggled(sourceSelection: selectedSourceRange)
    case .speedUp: transcript.speedUpTapped()
    case .speedDown: transcript.speedDownTapped()
    case .removeSection:
      return handleRemoveSectionKey()
    case .escape:
      // Consumed only when it actually deselects a seam, so a no-op Escape still propagates.
      guard selectedSeamID != nil else { return false }
      deselectSeam()
    case .nudgeCutInEarlier, .nudgeCutInLater, .nudgeCutOutEarlier, .nudgeCutOutLater:
      return nudgeSelection(key)
    }
    return true
  }

  /// Delete-key arbitration (decision 6), split out of `editorKeyDown`'s switch to keep its
  /// cyclomatic complexity in check: a selected seam restores its removal; else a removable
  /// source-range selection removes a section; else fall through (`false`) so the event still
  /// reaches a focused slice row's List `.onDelete`.
  private func handleRemoveSectionKey() -> Bool {
    if selectedSeamID != nil {
      restoreRemovalTapped()
      return true
    }
    guard canRemoveSelectedSection else { return false }
    Task { await removeSelectedSectionTapped() }
    return true
  }

  /// Nudges one edge of the primary selection by the ←/→/⇧←/⇧→ keys — split out of `editorKeyDown`'s
  /// switch (as one combined case delegating here) to keep its cyclomatic complexity in check. Falls
  /// through unconsumed (`false`) when there is no selection, so the key still reaches a focused slice
  /// row that might handle it.
  private func nudgeSelection(_ key: EditorKey) -> Bool {
    guard audioSelection != nil else { return false }
    switch key {
    case .nudgeCutInEarlier: selectionNudged(.start, byMs: -fineTune.nudgeMs)
    case .nudgeCutInLater: selectionNudged(.start, byMs: fineTune.nudgeMs)
    case .nudgeCutOutEarlier: selectionNudged(.end, byMs: -fineTune.nudgeMs)
    case .nudgeCutOutLater: selectionNudged(.end, byMs: fineTune.nudgeMs)
    default: return false
    }
    return true
  }

  /// The single funnel for every document mutation (`slices` + `timelineRemovals`):
  /// snapshots before/after and records the change on the undo stack (a no-op when
  /// nothing changed), then persists the removals if they actually changed — a
  /// slice-only mutation (rename, reorder, add/delete slice) never touches the sidecar.
  /// Restoring history via `undoTapped`/`redoTapped` deliberately bypasses this — it
  /// assigns the fields directly so replaying the stack never records a new entry.
  func mutateDocument(_ body: (inout EditorDocumentState) -> Void) {
    let old = documentState
    var new = old
    body(&new)
    slices = new.slices
    timelineRemovals = new.timelineRemovals
    documentUndo.record(before: old, after: new)
    if new.timelineRemovals != old.timelineRemovals {
      persistTimelineRemovals()
    }
    syncEditedTimeline()
  }

  /// `slices`-only convenience over `mutateDocument`, kept so every existing slice
  /// mutation site reads the same as before.
  func mutateSlices(_ body: (inout IdentifiedArrayOf<Slice>) -> Void) {
    mutateDocument { doc in body(&doc.slices) }
  }

  /// Writes `timelineRemovals` to the per-file project sidecar so it survives engine
  /// re-runs and reloads.
  private func persistTimelineRemovals() {
    $projectState.withLock { $0.timelineRemovals = timelineRemovals }
  }

  /// Adds an accepted suggestion's slice to the editor. Idempotent by `Slice.id` (a
  /// re-accept is a no-op), routed through `appendNewClip` so it's exportable and undoable.
  /// Known limitation: undoing/deleting the slice later does not un-accept the suggestion
  /// in the sidecar — full accept/reject reconciliation is deferred.
  func acceptCutSuggestionSlice(_ slice: Slice) {
    guard slices[id: slice.id] == nil else { return }
    appendNewClip(slice)
  }

  /// The single funnel for every NEW clip (Mark as Clip, fine-tune commit, accepted
  /// suggestion): nudges its cut points by the user's clip-boundary offset setting, then
  /// appends. Word membership and snippet are intentionally left AS BUILT — the offset is a
  /// small audio padding, not a content change — so the clip stays "the same words" with a
  /// slightly earlier/later cut. Manual boundary re-edits (`updatedSlice`) deliberately do NOT
  /// pass through here (new cuts only).
  private func appendNewClip(_ slice: Slice) {
    let range = offsetClipRange(
      slice.startSample..<slice.endSample,
      startOffsetMs: clipStartOffsetMs, endOffsetMs: clipEndOffsetMs,
      sampleRate: editPlan.source.sampleRate, totalSamples: editPlan.source.durationSamples)
    var nudged = slice
    nudged.startSample = range.lowerBound
    nudged.endSample = range.upperBound
    mutateSlices { $0.append(nudged) }
  }

  // MARK: - Listen pass
  /// The "scroll to current word" control has somewhere to go once playback has placed a word.
  var canScrollToCurrentWord: Bool { transcript.canScrollToCurrentWord }

  /// Re-centres the transcript on the word under the playhead and resumes follow.
  func scrollToCurrentWordTapped() { transcript.scrollToCurrentWordTapped() }

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
      let range = sourceRange(coveringWords: editPlan.words[lower].id, editPlan.words[upper].id)
    else { return }
    // Pin the Shift-extend anchor to the new selection's start edge, like every other
    // selection-replacing writer (plain click, marquee, transcript select). A reveal that skipped this
    // would leave `selectionAnchorSample` on the *previous* selection, so a later Shift-extend or edge
    // edit would pivot from a boundary this selection no longer has and re-extend over unselected audio.
    selectionAnchorSample = range.lowerBound
    selectSourceRange(range, snapPlayhead: true)
    // Only frame the reveal if the selection actually resolved. A range built from out-of-file word
    // bounds collapses to no selection in the funnel; scrolling to that phantom word anyway would
    // leave the panes inconsistent (highlight gone, transcript jumped). Matches this method's contract.
    guard audioSelection != nil else { return }
    revealSourceRange(range, zoomWaveform: true)
  }

  /// Zooms and scrolls the waveform to frame the current selection (padded). A no-op
  /// when nothing is selected.
  func zoomWaveformToSelection() {
    guard let range = selectedSourceRange else { return }
    editedWaveform.zoomToFitSource(range, paddingFraction: waveformFramePadding)
  }

  // MARK: - Slice-detail edit modal

  /// Opens the slice-detail edit modal for `id`, scoped to that slice's own fine-tune session.
  /// Guarded the same way switching the docked pane's target is (`hasUnsavedChange`) so opening
  /// the modal can't silently strand or clobber an in-flight docked-pane edit.
  func editSliceTapped(_ id: Slice.ID) {
    guard let slice = slices[id: id], !fineTune.hasUnsavedChange else { return }
    // Opening the modal supersedes any in-progress MAIN playback — the main timeline and its
    // hidden transcript shouldn't keep running behind the sheet. Snapshot-stop it (covers a PAUSED
    // main transport too, not just a playing one) so this stop, which may land after the modal's
    // own Play has started a fresh `.sliceEdit` session, can never kill that newer session.
    stopActiveTransportSnapshotting()
    let child = EditSliceModel(slice: slice, editPlan: editPlan)
    // Give the sheet its OWN lane, seeded from the already-decoded pyramid so nothing is re-decoded,
    // pinned to this slice (you cannot scroll or zoom past its boundaries). It must not share the
    // main editor's WaveformModel (that one is bound to the main viewport's zoom/scroll/width).
    child.waveform.adopt(
      waveform: waveform.waveform, totalSamples: waveform.totalSamples,
      sampleRate: waveform.sampleRate, contentRange: slice.startSample..<slice.endSample)
    // Seed the sheet's collapsed lane with the parent's current GLOBAL timeline so any removals
    // already inside the slice render collapsed the moment it opens. `syncEditedTimeline` keeps it
    // in sync for every later removal/undo/redo while the sheet stays up.
    child.syncTimeline(editedTimeline)
    // Item ①: the modal edits the slice exactly like the main timeline — a marquee removal and a
    // seam restore route through the SAME funnels the main editor uses, so both surfaces merge
    // cross-seam removals identically and every edit is one ⌘Z step. `syncEditedTimeline` fans the
    // result back into the open sheet.
    child.onRemoveSection = { [weak self] range in await self?.removeSourceRange(range) }
    child.onRestore = { [weak self] removalID in self?.restoreRemoval(id: removalID) }
    // A crossfade stretch inside the sheet commits through the SAME `updateCrossfade` funnel the main
    // editor uses, so a stretch is identical on both surfaces and one ⌘Z step. The sheet drafts the
    // length against its own (parent-synced) lane and hands the committed length here; the parent
    // preserves the removal's curve/center and fans the result back into the open sheet.
    child.onStretchCrossfade = { [weak self] removalID, length in
      guard let self, var crossfade = timelineRemovals[id: removalID]?.crossfade else { return }
      crossfade.lengthSamples = length
      updateCrossfade(id: removalID, crossfade)
    }
    child.currentCrossfadeLength = { [weak self] removalID in
      self?.timelineRemovals[id: removalID]?.crossfade.lengthSamples
    }
    // ⌘Z/⌘⇧Z pressed inside the sheet route here: a modal removal lives on this document's undo
    // stack, and `undoTapped`/`redoTapped` fan the restored timeline back into the open sheet via
    // `syncEditedTimeline`. The main window's SwiftUI undo shortcut can't fire while the sheet is key.
    child.onUndo = { [weak self] in await self?.undoTapped() }
    child.onRedo = { [weak self] in await self?.redoTapped() }
    child.onCommit = { [weak self] range in self?.commitSliceEdit(id: id, range: range) }
    child.onPlay = { [weak self] range in
      // Logic model: Play always plays `range` from the playhead as a fresh, exclusive `.sliceEdit`
      // playback (the child derives `range` from the cursor). Pause merely freezes the cursor; the
      // next Play re-plays from it, and seeking mid-play passes a new range here to re-anchor. There
      // is no bespoke resume/drift branch — `beginTransportPlayback` supersedes any prior (playing or
      // paused) session cleanly.
      //
      // Item ①: `.slice` (not `.sourceRange`) so the sheet PREVIEWS the collapsed audio — a removal
      // inside the slice is skipped on playback exactly as it collapses on the lane and exports, so
      // what you hear matches what you see. With no removal intersecting, `.slice` resolves to the
      // plain source range (identical audio), so removal-free slices are unchanged.
      await self?.beginTransportPlayback(.slice(range), context: .sliceEdit)
    }
    child.onPause = { [weak self] in
      guard let self else { return }
      await transportPauseTapped()
      // Publish the frozen cursor back to the sheet so its "play from the playhead" uses the exact
      // pause point (the position loop stops ticking once paused, so it won't otherwise learn it).
      editSlice?.updatePlayback(sample: playheadSourceSample, isPlaying: isTransportPlaying)
    }
    child.onStop = { [weak self] in
      guard let self else { return }
      await transportStopTapped()
      // Stop returns the cursor to the play origin; publish it so the sheet's next "play from the
      // playhead" starts there rather than from a stale last-tick sample.
      editSlice?.updatePlayback(sample: playheadSourceSample, isPlaying: isTransportPlaying)
    }
    // R4: the transport always plays a whole range, never from an arbitrary point. This callback is
    // the CURSOR-ONLY path — it repositions the persistent cursor and starts nothing. A seek taken
    // WHILE playing on the waveform body does not reach here: `EditSliceModel.waveformSeeked` routes
    // that case to `onPlay`, which re-anchors playback from the click to the cut-out.
    child.onSeek = { [weak self] sample in
      guard let self else { return }
      // The modal reasons in SOURCE samples; the persistent cursor lives on the EDITED axis.
      placeCursor(atSource: sample)
      editSlice?.updatePlayback(sample: sample, isPlaying: isTransportPlaying)
    }
    child.onDismiss = { [weak self] in
      self?.stopActiveTransportSnapshotting()
      self?.editSlice = nil
    }
    editSlice = child
  }

  /// Stops whatever playback the transport currently owns, capturing its session SYNCHRONOUSLY so
  /// a later async stop can't kill a newer session. Mirrors `transportStopTapped` (returns the
  /// cursor to origin, stops OUR session only) but is safe to call across a modal open/dismiss
  /// transition where a fresh `.sliceEdit` session may start right after this returns. Idempotent:
  /// a no-op when nothing is playing, so overlapping open/dismiss stop paths can all call it.
  func stopActiveTransportSnapshotting() {
    guard let session = transportPhase.session else { return }
    returnCursorToTransportOrigin()
    resetTransportState()
    endTranscriptFollow()
    Task { [weak self] in await self?.stopOwnedPlayback(session) }
  }

  /// The SwiftUI `sheet(onDismiss:)` hook — covers Escape / outside-click dismissals that bypass
  /// the Save/Cancel buttons. Guarded on `editSlice == nil` so a rapid dismiss→reopen can't let
  /// this stale callback (it fires after the dismissal transaction) stop the NEXT modal's freshly
  /// started session: when a new modal is already present it owns its own transport lifecycle, and
  /// the old modal's session was already stopped by its dismiss path or by the new modal's open.
  func sliceEditSheetDismissed() {
    guard editSlice == nil else { return }
    stopActiveTransportSnapshotting()
  }

  func addSliceTapped() {
    guard canAddSlice, let range = selectedSourceRange else { return }
    // Clip membership is derived from the selection RANGE (overlap), not the transcript's own
    // selection — a freeform selection has no transcript words, and an edge-clipped word still
    // belongs to the clip.
    let wordIDs = wordIDs(anyOverlap: range, words: editPlan.words)
    guard !wordIDs.isEmpty else { return }
    let slice = buildSlice(
      id: UUID(), name: "Slice \(nextSliceNumber)", range: range, wordIDs: wordIDs,
      plan: editPlan)
    appendNewClip(slice)
    nextSliceNumber += 1
    transcript.clearSelectionTapped()
  }

  // MARK: - Timeline Removals
  /// The default crossfade every new removal starts with — 20 ms at the plan's sample
  /// rate. PR 2 makes it user-editable per removal.
  var defaultCrossfadeSamples: Int { Int(0.020 * Double(editPlan.source.sampleRate)) }

  /// The SOURCE range a removal would apply to: the primary selection. Edge drag + nudge now mutate
  /// `audioSelection` directly (see `selectionNudged` / `selectionEdgeDragged`), so there is no
  /// separate fine-tune draft to prefer — the selection is already the (possibly nudged) truth.
  private var pendingRemovalSourceRange: Range<Int>? { selectedSourceRange }

  /// Whether `range` can become a removal: non-empty. Cross-seam is now allowed — a range that
  /// overlaps existing removals merges them into one larger removal via `removeSourceRange`
  /// (Item ①: the Edit-Slice modal and the main timeline share one collapsed axis, so Delete
  /// must behave identically on both).
  func canRemove(sourceRange range: Range<Int>) -> Bool {
    range.lowerBound < range.upperBound
  }

  /// Drives ⌫ enablement and the Remove Section menu item. Also blocked while an export is
  /// in flight — an in-progress export is rendering the un-cut canonical audio, so adding a
  /// removal mid-export would leave the finished AIFF stale relative to what the editor shows.
  var canRemoveSelectedSection: Bool {
    guard let range = pendingRemovalSourceRange else { return false }
    return canRemove(sourceRange: range) && !isExporting
  }

  /// Turns the current selection (or its nudged draft, if a boundary-nudge session is open) into
  /// a `TimelineRemoval` with the default 20 ms equal-power crossfade, then clears the selection
  /// and the fine-tune session. Belt-and-suspenders guard on `isExporting` (mirrors
  /// `canRemoveSelectedSection`) so a stale invocation can't mutate the document while an export
  /// is rendering.
  func removeSelectedSectionTapped() async {
    guard let range = pendingRemovalSourceRange else { return }
    await removeSourceRange(range)
  }

  /// Removes a SOURCE range, merging any existing removals it overlaps into ONE larger removal
  /// (Item ①). The single funnel both the main timeline (`removeSelectedSectionTapped`) and the
  /// Edit-Slice modal route Remove through, so cross-seam behavior is identical on both surfaces —
  /// the modal is a truncated view of the same collapsed axis. The merged removal spans
  /// `min(lower)..<max(upper)` of the range and every absorbed removal, and carries the default
  /// crossfade: an absorbed removal's crossfade was internal to audio that stays removed, so it is
  /// no longer an audible seam. `normalize` runs only as a validation backstop. A no-op while
  /// exporting (a removal mid-export would leave the finished AIFF stale) or for an empty range.
  func removeSourceRange(_ range: Range<Int>) async {
    guard !isExporting, canRemove(sourceRange: range) else { return }
    let absorbed = timelineRemovals.filter { $0.removedRange.overlaps(range) }
    let mergedLower = min(
      range.lowerBound, absorbed.map(\.removedRange.lowerBound).min() ?? range.lowerBound)
    let mergedUpper = max(
      range.upperBound, absorbed.map(\.removedRange.upperBound).max() ?? range.upperBound)
    let removal = TimelineRemoval(
      id: UUID(), removedRange: mergedLower..<mergedUpper,
      crossfade: Crossfade(lengthSamples: defaultCrossfadeSamples, curve: .equalPower))
    mutateDocument { doc in
      for absorbedRemoval in absorbed { doc.timelineRemovals.remove(id: absorbedRemoval.id) }
      doc.timelineRemovals.append(removal)
      doc.timelineRemovals = IdentifiedArray(
        uniqueElements: TimelineRemovals.normalize(Array(doc.timelineRemovals))
          ?? Array(doc.timelineRemovals))
    }
    transcript.clearSelectionTapped()
    fineTune.clear()
    await reconcilePlayback()
  }

  // MARK: - Restore removed audio
  /// Whether the Restore control is offered: a seam is selected and its removal still exists. The
  /// `!isExporting` guard is defensive symmetry with `canRemoveSelectedSection` — export is
  /// hard-blocked whenever any removal exists, so a seam can't be selected mid-export anyway.
  var canRestoreSelectedRemoval: Bool {
    guard let selectedSeamID else { return false }
    return timelineRemovals[id: selectedSeamID] != nil && !isExporting
  }

  /// Drives whether the panel shows the Restore affordance at all — only when a seam is selected,
  /// so it appears exactly in the context where it acts.
  var shouldShowRestoreControl: Bool { selectedSeamID != nil }

  /// Restores a removed source range: drops the removal (and its crossfade) from the document,
  /// reopening the original audio at that seam. Routed through `mutateDocument`, so it is a single
  /// undo step, re-persists the sidecar, and re-syncs the edited timeline — which stops any stale
  /// free-play and remaps the cursor to the same SOURCE moment (playback reconciliation, PR 3), and
  /// drops this seam from `selectedSeamID` since it no longer exists. A no-op for an unknown id.
  func restoreRemoval(id: TimelineRemoval.ID) {
    guard timelineRemovals[id: id] != nil else { return }
    mutateDocument { doc in
      doc.timelineRemovals.remove(id: id)
    }
  }

  /// The Restore Removed Audio affordance (⌫ on a selected seam, its context menu, the panel
  /// button): restores the currently selected seam's removal. A no-op when no seam is selected.
  func restoreRemovalTapped() {
    guard let selectedSeamID else { return }
    restoreRemoval(id: selectedSeamID)
  }

  /// Updates a removal's crossfade as one undo step — the single commit funnel every fade edit
  /// routes through (the edge-drag stretch below; the numeric inspector and curve/center drags when
  /// they land). The stored length is the user's intent; `EditedTimeline` clamps it per-seam on
  /// build (a too-long fade is clamped for rendering without losing the stored value), mirroring how
  /// `removeSelectedSectionTapped` stores the default length. A no-op for an unknown id.
  func updateCrossfade(id: TimelineRemoval.ID, _ crossfade: Crossfade) {
    guard timelineRemovals[id: id] != nil else { return }
    mutateDocument { doc in
      doc.timelineRemovals[id: id]?.crossfade = crossfade
    }
  }

  // MARK: - Crossfade stretch (edge drag)
  /// Begins an edge-drag stretch of seam `id`: selects it and seeds the draft with its current
  /// length. A no-op for an unknown removal.
  func crossfadeStretchBegan(id: TimelineRemoval.ID) {
    guard let removal = timelineRemovals[id: id] else { return }
    selectSeam(id)
    let seam = editedWaveform.timeline.seams.first { $0.id == id }
    crossfadeStretchDraft = CrossfadeStretchDraft(
      id: id,
      length: removal.crossfade.lengthSamples,
      committedLength: seam?.crossfadeLength ?? removal.crossfade.lengthSamples,
      committedCenterEdited: seam?.editedCrossfadeCenter ?? 0,
      frozenVisibleStart: editedWaveform.visibleStartSample,
      frozenSamplesPerPixel: editedWaveform.samplesPerPixel)
  }

  /// A stretch drag to view-x: map x → edited sample and derive the symmetric length from the
  /// dragged edge's distance to the seam center. Reads the geometry frozen at `crossfadeStretchBegan`
  /// (viewport and center), not the live adapter — the live preview reflows the timeline and shifts
  /// the viewport under the drag, so mapping against live geometry would feed back on itself.
  func crossfadeStretched(_ edge: CrossfadeEdge, toX posX: CGFloat) {
    guard let draft = crossfadeStretchDraft else { return }
    let editedSample = WaveformViewport.xToSample(
      posX, visibleStartSample: draft.frozenVisibleStart,
      samplesPerPixel: draft.frozenSamplesPerPixel)
    let halfWidth =
      edge == .leading
      ? draft.committedCenterEdited - editedSample
      : editedSample - draft.committedCenterEdited
    crossfadeStretched(toLength: halfWidth * 2)
  }

  /// Geometry-free core: clamp the proposed length to `[0, available handle]`, hold it as the draft,
  /// and reflow the collapsed waveform to it live. The clamp bound is read from the COMMITTED
  /// timeline (unchanged mid-drag), so a neighbor can't shift under the drag. The document is still
  /// untouched — `applyStretchPreview` only repaints the adapter; the commit is on release.
  func crossfadeStretched(toLength proposed: Int) {
    guard var draft = crossfadeStretchDraft else { return }
    let maxLength = editedTimeline.maxCrossfadeLength(forSeamID: draft.id) ?? 0
    draft.length = max(0, min(proposed, maxLength))
    crossfadeStretchDraft = draft
    applyStretchPreview(draft)
  }

  /// Reflows the collapsed waveform to the drafted length and shifts the viewport by −ΔL/2 so the
  /// seam grows symmetrically about its start-of-drag screen center (Item ②: the downstream slide
  /// that used to happen on release now happens continuously during the drag). The preview timeline
  /// is built exactly as the commit builds it — the target removal's length overridden, everything
  /// else the document's — so releasing the drag repositions nothing.
  private func applyStretchPreview(_ draft: CrossfadeStretchDraft) {
    let preview = previewTimeline(seamID: draft.id, length: draft.length)
    let shift = (draft.length - draft.committedLength) / 2
    editedWaveform.previewStretch(
      timeline: preview, targetVisibleStart: draft.frozenVisibleStart - shift)
  }

  /// The edited timeline as it will render with seam `id`'s crossfade set to `length`, built the
  /// same way the commit is (override that one removal, rebuild). A no-op-shaped fallback to the
  /// committed timeline for an unknown id.
  private func previewTimeline(seamID id: TimelineRemoval.ID, length: Int) -> EditedTimeline {
    var removals = Array(timelineRemovals)
    guard let index = removals.firstIndex(where: { $0.id == id }) else { return editedTimeline }
    removals[index].crossfade.lengthSamples = length
    return EditedTimeline(
      sourceDurationSamples: editPlan.source.durationSamples, removals: removals)
  }

  /// Release: commit the drafted length as one undo step (via `updateCrossfade`) and clear the
  /// draft. A drag that netted no change pushes no entry. A no-op if no drag is live or the
  /// removal vanished mid-drag.
  func crossfadeStretchEnded() {
    guard let draft = crossfadeStretchDraft else { return }
    crossfadeStretchDraft = nil
    guard let removal = timelineRemovals[id: draft.id],
      draft.length != removal.crossfade.lengthSamples
    else { return }
    // Rewind the adapter to the pre-drag committed timeline (the viewport stays where the preview
    // left it — already clamped into the shorter axis, so it doesn't move). The live preview had
    // installed the timeline the commit is about to produce, which would make `syncEditedTimeline`'s
    // equality guard short-circuit and skip its reconciliation (playback / cursor / transport-origin
    // remap, zoom re-clamp, slice-sheet sync). Rewinding forces a real diff so that body runs.
    editedWaveform.timeline = editedTimeline
    var crossfade = removal.crossfade
    crossfade.lengthSamples = draft.length
    updateCrossfade(id: draft.id, crossfade)
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
  /// Restores the previous document snapshot (`slices` + `timelineRemovals`), then
  /// reconciles playback. History stores only the document, so anything derived
  /// (selection, zoom, export phase, playback) is left as-is except where reconciliation
  /// demands otherwise. Persists the sidecar only when the restored removals actually
  /// differ from the current ones — undoing a slice-only edit (rename, reorder, add/delete
  /// slice) never touches it.
  func undoTapped() async {
    // Guard here too, not just on `canUndo`: a menu item or keyboard shortcut could fire this
    // while an existing-slice edit is open, which would rewind `slices` under a live draft —
    // or mid-export, which would leave the finished AIFFs stale.
    guard !hasUncommittedSliceEdit, !isExporting,
      let restored = documentUndo.undo(current: documentState)
    else { return }
    let removalsChanged = restored.timelineRemovals != timelineRemovals
    slices = restored.slices
    timelineRemovals = restored.timelineRemovals
    if removalsChanged {
      persistTimelineRemovals()
    }
    syncEditedTimeline()
    await reconcilePlayback()
  }

  /// Reapplies the next document snapshot on the redo branch, then reconciles playback. Same
  /// persist-only-on-change behavior as `undoTapped`.
  func redoTapped() async {
    guard !hasUncommittedSliceEdit, !isExporting,
      let restored = documentUndo.redo(current: documentState)
    else { return }
    let removalsChanged = restored.timelineRemovals != timelineRemovals
    slices = restored.slices
    timelineRemovals = restored.timelineRemovals
    if removalsChanged {
      persistTimelineRemovals()
    }
    syncEditedTimeline()
    await reconcilePlayback()
  }

  /// Reconciles derived state after any slice list change (explicit delete, undo, redo):
  /// stops playback if the playing slice is gone, and closes the fine-tune pane if the active
  /// slice is gone (clearing its target + draft). Centralized so every removal path behaves
  /// the same.
  private func reconcilePlayback() async {
    // A shared-document undo/redo can pull the Edit Slice sheet's slice out from under it: ⌘Z can
    // delete the slice (rewinding its creation) OR revert its boundaries. The modal's overview
    // window and committed range are seeded once at open and never re-seed, so a survived-but-moved
    // slice leaves the sheet editing a stale range that a later Save would recommit over the undone
    // state. Either way, close the orphaned sheet and drop its transport with it.
    if let editing = editSlice, editSliceRangeIsStale(editing) {
      stopActiveTransportSnapshotting()
      editSlice = nil
    }
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

  /// Whether the open Edit Slice sheet is now editing a range the document no longer holds: the
  /// slice was deleted, or it survived but its boundaries were reverted away from the range the
  /// modal committed to at open (the modal never re-seeds its overview window / committed range).
  /// A modal removal leaves the slice's own bounds untouched, so it never reads as stale here.
  private func editSliceRangeIsStale(_ editing: EditSliceModel) -> Bool {
    guard let slice = slices[id: editing.sliceID] else { return true }
    return editing.fineTune.committedRange != slice.startSample..<slice.endSample
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
  ///
  /// What it plays is what it would export: resolution routes a slice whose range crosses a removal
  /// through the slice-local render plan, so a clip straddling a cut no longer auditions the audio
  /// export drops. A slice entirely inside a removal has nothing to play and is refused.
  func playSliceTapped(_ id: Slice.ID) async {
    guard let slice = slices[id: id] else { return }
    let playableEnd = min(slice.endSample, editPlan.source.durationSamples)
    guard slice.startSample < playableEnd else { return }
    await beginTransportPlayback(
      .slice(slice.startSample..<slice.endSample), context: .slice(id))
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

  /// Applies the transcript panel's current playback speed to the shared player: live if audio is
  /// playing, and remembered for the next play otherwise. Reads the latest committed rate so racing
  /// callers converge. The player keeps the plan-sample math intact at any rate, so the cursor
  /// stays aligned without adjustment.
  func applyPlaybackRate() async {
    await audioPlayer.setRate(transcript.playbackRate)
  }

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
    return isTransportPaused || canStartTimelinePlayback
  }
  var canTransportPause: Bool { isTransportPlaying }
  var canTransportStop: Bool { isTransportPlaying || isTransportPaused }

  /// Whether a Play-from-stopped has anywhere to go: the cursor sits before the edited end of
  /// the timeline. (Play is a straight listen-through of the EDITED timeline to its end; a
  /// selection marks a clip, it never scopes playback. Logic parity: pressing Play with the
  /// cursor past the region does nothing.)
  private var canStartTimelinePlayback: Bool {
    playheadEditedSample >= 0
      && playheadEditedSample < editedWaveform.timeline.editedDurationSamples
  }

  /// Play button / resume. From paused, resumes the frozen session. From stopped, plays the
  /// edited timeline from the cursor as plain `.free` scrubbing.
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
    await beginTransportPlayback(
      .editedTimeline(fromEdited: playheadEditedSample), context: .free)
  }

  /// What the transport should play. `.sourceRange` = a range of the ORIGINAL audio (preview,
  /// audition, slice-edit modal — paths whose ranges are source data). `.editedTimeline`
  /// = the collapsed timeline from an EDITED sample (the main Play — removals collapsed, seams
  /// blended). With zero removals the edited plan is the identity playlist, so the two produce
  /// the same audio. `.slice` = a saved clip, whose resolution decides between the two: with no
  /// removal intersecting it, the plain source range; otherwise the slice-LOCAL render plan
  /// export renders, so auditioning a clip and exporting it can never disagree.
  private enum TransportPlayback {
    case sourceRange(Range<Int>)
    case editedTimeline(fromEdited: Int)
    case slice(Range<Int>)
  }

  /// Set when a slice's playback must go through the edited playlist (its range intersects a
  /// removal): the offset plan `playEdited` schedules, plus what's needed to convert the
  /// player's slice-LOCAL edited positions back to absolute SOURCE samples for the cursor.
  private struct SlicePlaybackPlaylist {
    var plan: AudioEditRenderPlan
    var localTimeline: EditedTimeline
    var sliceStart: Int
  }

  /// The live slice playlist's conversion state, set while a removal-crossing slice plays and nil
  /// for every other playback. That session's ticks and pause samples arrive on the SLICE-LOCAL
  /// edited axis, which is meaningless to the global cursor — this is what maps them back.
  /// Cleared by `resetTransportState`, so every stop/supersede/teardown path drops it.
  @ObservationIgnored private var slicePlaybackConversion: SlicePlaybackPlaylist?

  /// A playback target clamped to its playable axis: where the cursor starts, where a natural
  /// finish rests it, the SOURCE range handed to the player (range paths only), and — for a
  /// removal-crossing slice — the slice-local playlist to schedule instead of that raw range.
  private struct ResolvedTransportPlayback {
    var startEditedSample: Int
    var finishEditedSample: Int
    var sourceRange: Range<Int>?
    var slicePlaylist: SlicePlaybackPlaylist?
  }

  /// Clamps `playback` to the file/timeline so a natural finish can rest the cursor at a valid
  /// sample (callers guard degenerate inputs already; this is the single safety net and the one
  /// place the cursor-at-end is derived from). Nil for an empty clamp, which must return before
  /// superseding so it can't orphan playback.
  private func resolvedTransportPlayback(_ playback: TransportPlayback)
    -> ResolvedTransportPlayback?
  {
    switch playback {
    case .sourceRange(let explicitRange):
      let upper = min(explicitRange.upperBound, editPlan.source.durationSamples)
      let lower = max(0, min(explicitRange.lowerBound, upper))
      guard lower < upper else { return nil }
      return ResolvedTransportPlayback(
        startEditedSample: editedCursor(forSource: lower),
        finishEditedSample: editedCursor(forSource: upper),
        sourceRange: lower..<upper)
    case .slice(let sliceRange):
      let upper = min(sliceRange.upperBound, editPlan.source.durationSamples)
      let lower = max(0, min(sliceRange.lowerBound, upper))
      guard lower < upper else { return nil }
      // The cursor semantics are the source range's either way: start/origin at the slice's
      // first sample, a natural finish at its last. Only the AUDIO differs.
      var resolved = ResolvedTransportPlayback(
        startEditedSample: editedCursor(forSource: lower),
        finishEditedSample: editedCursor(forSource: upper),
        sourceRange: lower..<upper)
      let render = SliceRenderPlanBuilder.plan(
        sliceRange: lower..<upper, removals: Array(timelineRemovals))
      // No removal reaches into this slice: the raw range IS the edited audio, so keep the
      // tuned source-range path rather than route identical audio through the playlist.
      guard !render.localTimeline.removals.isEmpty else { return resolved }
      // Every sample of the slice is removed — export calls this unexportable, and there is
      // likewise nothing to play. Nil here (before superseding) leaves the transport stopped.
      guard render.editedDurationSamples > 0 else { return nil }
      resolved.slicePlaylist = SlicePlaybackPlaylist(
        plan: render.plan, localTimeline: render.localTimeline, sliceStart: render.sliceStart)
      return resolved
    case .editedTimeline(let fromEdited):
      let editedDuration = editedWaveform.timeline.editedDurationSamples
      let start = max(0, min(fromEdited, editedDuration))
      guard start < editedDuration else { return nil }
      return ResolvedTransportPlayback(
        startEditedSample: start, finishEditedSample: editedDuration, sourceRange: nil)
    }
  }

  /// How a playback ended, plus where a natural finish should rest the cursor: on the EDITED axis
  /// for edited-timeline playback, and — for a slice playlist — the absolute SOURCE sample the
  /// audio actually reached (`nil` when the player didn't report one).
  private struct PlayerFinish {
    var end: PlaybackEnd
    var editedSample: Int
    var sourceSample: Int?
  }

  /// Hands `resolved` to the player and stays suspended until it ends, returning how it ended plus
  /// where a natural finish should rest the cursor.
  ///
  /// That resting position is the plan's declared end for the plain source-range path, but both
  /// `playEdited` paths report the sample they ACTUALLY reached and that wins: against a
  /// stale/short canonical file the schedule clamps and the audio stops early, so trusting the
  /// plan would leave the cursor somewhere the audio never got to. A slice playlist reports on its
  /// slice-LOCAL edited axis, so it is converted back to an absolute source sample here (and
  /// clamped to the slice's end) — the caller's cursor lives on the global axis.
  ///
  /// The speed rides along with the start (not a separate awaited call), so no suspension point
  /// sits between `.playing(session)` and the player marking the session current — a Stop or
  /// selection snap can't slip in and orphan the audio.
  private func runPlayer(
    _ resolved: ResolvedTransportPlayback, timeline: EditedTimeline, session: PlaybackSessionID
  ) async -> PlayerFinish {
    do {
      if let playlist = resolved.slicePlaylist {
        // A removal-crossing slice plays the same plan export renders — absolute source ranges
        // on a slice-local edited axis — so the cut is audible exactly where it will be exported.
        let result = try await audioPlayer.playEdited(
          canonicalAudioURL, playlist.plan, editPlan.source.sampleRate,
          transcript.playbackRate, session)
        let reachedSource = result.finishedEditedSample.map { local in
          let source = playlist.sliceStart + playlist.localTimeline.editedToSource(local)
          return min(source, resolved.sourceRange?.upperBound ?? source)
        }
        return PlayerFinish(
          end: result.end, editedSample: resolved.finishEditedSample,
          sourceSample: reachedSource)
      }
      if let sourceRange = resolved.sourceRange {
        let end = try await audioPlayer.play(
          canonicalAudioURL, sourceRange, editPlan.source.sampleRate,
          transcript.playbackRate, session)
        return PlayerFinish(end: end, editedSample: resolved.finishEditedSample, sourceSample: nil)
      }
      // Seek semantics ride on plan construction: the plan starts at the cursor's edited
      // sample, and a start inside a seam yields a partial seam (`fadeOffset`) so the fade
      // continues from the seek point rather than restarting.
      let result = try await audioPlayer.playEdited(
        canonicalAudioURL,
        AudioEditRenderPlan(timeline: timeline, startEditedSample: resolved.startEditedSample),
        editPlan.source.sampleRate, transcript.playbackRate, session)
      return PlayerFinish(
        end: result.end,
        editedSample: result.finishedEditedSample ?? resolved.finishEditedSample,
        sourceSample: nil)
    } catch {
      reportIssue(error)
      return PlayerFinish(
        end: .stopped, editedSample: resolved.finishEditedSample, sourceSample: nil)
    }
  }

  /// The one funnel every playback flows through — plain Play (`.free`) and the slice/preview/
  /// audition shortcuts alike — so one phase machine, one cursor, and one Pause/Stop govern them.
  /// The playback target is EXPLICIT (never recomputed from the selection): the cursor is
  /// positioned at its start, `transportOriginEditedSample` records where Stop returns, and
  /// `context` records which shortcut owns it. The player await stays suspended across
  /// pause/resume until stop, supersede, or natural end.
  private func beginTransportPlayback(
    _ playback: TransportPlayback, context: TransportContext
  ) async {
    let timeline = editedWaveform.timeline
    guard let resolved = resolvedTransportPlayback(playback) else {
      // Nothing playable (e.g. the slice's whole range has been removed): the caller (Play/Pause,
      // an audition hotkey) already flipped `isPlaying`/`activeAudition` optimistically before this
      // await, and there is no later tick to correct it — publish "stopped" back now so the sheet
      // doesn't get stuck showing an active Play/Pause or audition state with no audio playing.
      if case .sliceEdit = context {
        editSlice?.updatePlayback(sample: editSlice?.playheadSample, isPlaying: false)
      }
      return
    }
    beginExclusivePlayback()
    let session = PlaybackSessionID()
    transportContext = context
    // Armed BEFORE the play call: the player starts ticking on its slice-local axis immediately,
    // and `observePlayback` needs the conversion in place to read those ticks correctly.
    // `beginExclusivePlayback` above just cleared any previous session's conversion.
    slicePlaybackConversion = resolved.slicePlaylist
    transportOriginEditedSample = resolved.startEditedSample
    transportOriginSourceAnchor = resolved.sourceRange?.lowerBound
    if let sourceRange = resolved.sourceRange {
      placeCursor(atSource: sourceRange.lowerBound)
    } else {
      playheadEditedSample = resolved.startEditedSample
    }
    // A transport start authoritatively places the cursor, so it takes cursor authority too: a
    // selection snap deferred from before this Play must bail rather than stop us and snap back.
    cursorMoveGeneration &+= 1
    transportPhase = .playing(session)
    let finish = await runPlayer(resolved, timeline: timeline, session: session)
    // Clean up only if we're still the current playback (our own Stop/supersede already replaced the
    // session). Only a natural `.finished` lands the cursor at the range end. `.superseded` here
    // means ANOTHER tab took over the shared player — our session is still set because that tab never
    // touched it — so reset the transport WITHOUT jumping the cursor to the end. A failed play
    // (`.stopped`) likewise leaves the cursor put.
    guard transportPhase.session == session else { return }
    if finish.end == .finished {
      // Slice playback (playlist or not) always has a source range, so it rests on the SOURCE
      // axis: at the sample a playlist actually reached (already converted off the slice-local
      // axis and clamped), else at the slice's end.
      if let sourceRange = resolved.sourceRange {
        placeCursor(atSource: finish.sourceSample ?? sourceRange.upperBound)
      } else {
        playheadEditedSample = finish.editedSample
      }
    }
    // Capture the slice-edit child (if this playback was the modal's) BEFORE the reset clears the
    // context — reaching here past the session guard means the modal wasn't torn down, so this IS
    // the owning modal. A natural finish / cross-tab supersede must publish "stopped" back to it.
    let owningSliceEdit: EditSliceModel? = {
      if case .sliceEdit = transportContext { return editSlice }
      return nil
    }()
    resetTransportState()
    // Reset transcript follow here too: on a cross-tab `.superseded` (and on a natural end whose
    // final stop tick races this cleanup) `observePlayback` may never see a gated false tick, so
    // without this a slice's `wasPlaying` stays true and the next slice misses its rising edge.
    endTranscriptFollow()
    // The position loop drops the trailing false tick on a natural finish (the reset above cleared
    // the session it guards on), so the modal would never learn it stopped without this explicit
    // publish. `stopTapped`/dismiss handle their own paths; this covers finish + cross-tab supersede.
    owningSliceEdit?.updatePlayback(sample: playheadSourceSample, isPlaying: false)
  }

  /// Pause button. Freezes the cursor at the exact sample the player reports and holds the
  /// suspended `play` call in flight. Re-guards the session after the await so a pause landing
  /// after a supersession doesn't stamp a stale phase over the new owner.
  func transportPauseTapped() async {
    guard case .playing(let session) = transportPhase else { return }
    let sample = await audioPlayer.pause(session)
    guard transportPhase.session == session else { return }
    switch sample {
    case .edited(let editedSample): applyEditedPlaybackSample(editedSample)
    case .source(let source): placeCursor(atSource: source)
    case nil: break
    }
    transportPhase = .paused(session)
  }

  /// Stop button. Returns the cursor to the origin, then clears the transport and stops the audio.
  /// Clearing the session (in `endTransportPlayback`) before awaiting the stop means the suspended
  /// `play`'s natural-end cleanup won't run and overwrite the origin.
  func transportStopTapped() async {
    returnCursorToTransportOrigin()
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

  /// Selection reconciliation, driven by `EditorView.onChange(of: audioSelection)`.
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
    // An edge-handle drag also writes `audioSelection` on every pointer move; suppress the snap while
    // an edge is live so a fine-tune drag doesn't churn the transport. Edge drag never snaps the
    // playhead (it's a boundary edit, not a seek), so there's no commit-once counterpart on release.
    guard selectionEditingEdge == nil else { return }
    // Bail BEFORE touching playback if the cursor has been placed by a later action — a ruler move or
    // a transport start — since this selection change was registered. `cursorToken` is captured
    // synchronously in the view's `onChange`, so a ruler click or a Play that ran before this deferred
    // task fires makes this stale: it must neither snap over that placement nor stop that new playback.
    guard cursorMoveGeneration == cursorToken else { return }
    if transportPhase.session != nil {
      await endTransportPlayback()
      // Re-check across the stop await: a newer selection, a new playback, or a ruler move (which
      // bumps the generation) all invalidate this snap.
      guard audioSelection == newRange, transportPhase.session == nil,
        cursorMoveGeneration == cursorToken
      else { return }
    }
    placeCursor(atSource: newRange.lowerBound)
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
    guard editedWaveform.hasUsableGeometry else { return }
    stopTransportForRuler()
    playheadEditedSample = clampedRulerEditedSample(positionX)
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

  /// The ruler's view-x mapped to an EDITED sample, clamped to a valid cursor position.
  /// `editedDurationSamples` (end-of-timeline) is inclusive: a legal resting cursor where Play is
  /// a correct no-op.
  private func clampedRulerEditedSample(_ positionX: CGFloat) -> Int {
    min(
      max(0, editedWaveform.xToEditedSample(positionX)),
      editedWaveform.timeline.editedDurationSamples)
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
  ///
  /// The "hold an unsaved draft until Save/Cancel" protection below applies ONLY to a currently
  /// open `.slice` session (`fineTune.isEditingExistingSlice`) — it's editing a real, already
  /// -committed slice's real cut points, so silently discarding the draft would lose that data,
  /// and (pre-Task-9) it has a visible pane with Save/Cancel to resolve it. A `.pendingSelection`
  /// draft is a disposable CANDIDATE that commits nothing on its own, and Task 9 wires its session
  /// with no pane at all — so holding it the same way is a dead end: the app would refuse to
  /// retarget it to any later selection, permanently blocking `canAddSlice`/`editSliceTapped` for
  /// every future selection (found in adversarial review of Task 9). A dirty pending draft is
  /// therefore always free to be abandoned the moment the live selection/target moves on.
  func syncEditSession() {
    guard let target = fineTuneTarget, let range = activeOrSelectedRange else {
      // Don't tear down an unsaved SLICE edit just because the target went nil — the user must
      // Save or Cancel first. A dirty PENDING-SELECTION draft has nothing protecting it, so it's
      // discarded right along with a clean one.
      if fineTune.target != nil, !fineTune.isEditingExistingSlice || !fineTune.hasUnsavedChange {
        cancelPreviewOrAuditionIfNeeded()  // closing the pane removes the region + Stop control
        fineTune.clear()
      }
      return
    }
    // Never abandon an unsaved SLICE edit by retargeting — a new transcript selection arriving
    // mid-edit holds it until Save/Cancel. A dirty PENDING-SELECTION draft is NOT held: it falls
    // through to `shouldBegin` below, which re-anchors (and so discards the abandoned draft).
    if fineTune.isEditingExistingSlice, fineTune.hasUnsavedChange,
      fineTune.target != target || fineTune.committedRange != range
    {
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
    case .draftPreview, .audition, .sliceEdit: break
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

  /// Commits an existing slice's cut points to `range` as exactly ONE `mutateSlices` (one undo
  /// entry): word IDs, snippet, and warnings are re-derived from the new range. A no-op if the
  /// slice no longer exists (e.g. deleted out from under an in-flight edit).
  func commitSliceEdit(id: Slice.ID, range: Range<Int>) {
    guard slices[id: id] != nil else { return }
    mutateSlices { slices in
      if let slice = slices[id: id] { slices[id: id] = updatedSlice(slice, to: range) }
    }
  }

  /// Commits the draft as exactly ONE `mutateSlices` (one undo entry) for a whole drag: an
  /// existing slice's cut points are updated (word IDs + snippet + warnings re-derived from
  /// the new range); a pending selection becomes a new slice. No-op when nothing changed.
  func commitEditTapped() {
    guard canCommitEdit, let draft = fineTune.draftRange, let target = fineTune.target
    else { return }
    switch target {
    case .slice(let id):
      commitSliceEdit(id: id, range: draft)
      fineTune.markCommitted(draft)
    case .pendingSelection:
      let slice = makeSlice(range: draft)
      appendNewClip(slice)
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
    await beginTransportPlayback(.sourceRange(range), context: .draftPreview)
  }

  // MARK: - Audition
  let auditionPreRollSeconds = 2.0
  let auditionInButtonTitle = "▶ In"
  let auditionInHotkey = "["
  let auditionOutButtonTitle = "Out ▶"
  let auditionOutHotkey = "]"

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
    await beginTransportPlayback(
      .sourceRange(region.lowerBound..<end), context: .audition(.cutIn))
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
    await beginTransportPlayback(.sourceRange(start..<end), context: .audition(.cutOut))
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
    guard !isExporting, !hasUncommittedSliceEdit, editedTimeline.isValid,
      let slice = slices[id: id], sliceIsExportable(slice)
    else { return }
    lastExportSkippedRemovedNames = []
    startExport([slice])
  }

  func exportAllTapped() {
    guard !isExporting, !hasUncommittedSliceEdit, editedTimeline.isValid else { return }
    let targets = slices.filter(sliceIsExportable)
    guard !targets.isEmpty else { return }
    lastExportSkippedRemovedNames = slices.filter { !sliceIsExportable($0) }.map(\.name)
    startExport(Array(targets))
  }

  func cancelExportTapped() {
    exportTask?.cancel()
  }

  /// Waits for any in-flight export to finish unwinding. The engine subprocess reads the
  /// canonical AIFF, so a caller tearing this editor down (tab close, re-import) must await
  /// this — after ``cancelExportTapped()`` — before ``discardCanonicalAudio()``, or it could
  /// delete the file out from under a render still in flight.
  func awaitExportTeardown() async {
    await exportTask?.value
  }

  // MARK: - Lifecycle
  /// Removes this session's canonical audio cache dir. Called when the tab closes:
  /// the AIFF is derived data, rebuildable by re-transcribing, so it shouldn't linger.
  /// Only safe once any in-flight export has been cancelled AND awaited
  /// (``awaitExportTeardown()``) — the engine reads this file during render.
  func discardCanonicalAudio() {
    CanonicalAudioStore.remove(canonicalAudioURL)
  }

  // MARK: - Private Helpers
  /// Sanitizes a raw (e.g. just-decoded-from-sidecar) removal set before it becomes the
  /// document's source of truth: drops removals with an empty or out-of-`0
  /// ..< sourceDurationSamples` range, then keeps only a sorted, non-overlapping subset (the
  /// first-by-`lowerBound` removal wins any overlap). This keeps `timelineRemovals` always
  /// consistent with `editedTimeline` (`EditedTimeline` silently falls back to an empty removal
  /// set on overlap, so an unsanitized store would split-brain: strike-through/export-gate on,
  /// but no waveform collapse) — guards against a foreign, older, or hand-edited sidecar, or the
  /// same source re-analyzed to a shorter duration.
  ///
  /// Deliberately not `private`: `EditorRemovalTests` calls it directly via `@testable import`.
  static func validatedRemovals(
    _ raw: IdentifiedArrayOf<TimelineRemoval>, sourceDurationSamples: Int
  ) -> IdentifiedArrayOf<TimelineRemoval> {
    let inBounds = raw.filter { removal in
      let range = removal.removedRange
      return range.lowerBound < range.upperBound
        && range.lowerBound >= 0
        && range.upperBound <= sourceDurationSamples
    }
    let sorted = inBounds.sorted { $0.removedRange.lowerBound < $1.removedRange.lowerBound }
    var nonOverlapping: [TimelineRemoval] = []
    for removal in sorted {
      if let last = nonOverlapping.last,
        removal.removedRange.lowerBound < last.removedRange.upperBound
      {
        continue
      }
      nonOverlapping.append(removal)
    }
    return IdentifiedArray(uniqueElements: nonOverlapping)
  }

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

  /// Re-derives a slice's word membership and snippet for a new sample range once the cut
  /// points move. Membership is by overlap ("a word is in a clip iff any of its audio
  /// overlaps the range" — the spec's single clip-membership rule), matching how a clip is built
  /// from a freeform selection so editing a clip's boundaries can never silently drop a word that
  /// creating it included.
  private func updatedSlice(_ slice: Slice, to range: Range<Int>) -> Slice {
    var updated = slice
    updated.startSample = range.lowerBound
    updated.endSample = range.upperBound
    updated.wordIDs = wordIDs(anyOverlap: range, words: editPlan.words)
    updated.snippet = displaySnippet(sliceSnippet(for: updated.wordIDs, words: editPlan.words))
    return updated
  }

  /// Builds a brand-new slice from a fine-tuned sample range, deriving word membership by the
  /// spec's overlap rule (a word is in the clip iff any of its audio overlaps) — the same rule as
  /// direct Add-from-selection, so fine-tuning a selection before committing never silently drops a
  /// partially-overlapped edge word.
  private func makeSlice(range: Range<Int>) -> Slice {
    buildSlice(
      id: UUID(), name: "Slice \(nextSliceNumber)", range: range,
      wordIDs: wordIDs(anyOverlap: range, words: editPlan.words), plan: editPlan)
  }

  /// Marks the export as running synchronously (so the buttons disable immediately
  /// and a rapid second tap can't start a parallel export) and spawns the worker,
  /// keeping a handle so `cancelExportTapped` can kill the process group.
  /// Whether the canonical AIFF still backs this session. It can be reaped or purged out
  /// from under a live editor (an overlapping instance's launch cleanup, a low-disk cache
  /// purge), so export verifies it rather than trusting the URL captured at load.
  private var canonicalAudioIsOnDisk: Bool {
    FileManager.default.fileExists(atPath: canonicalAudioURL.path)
  }

  private func startExport(_ targets: [Slice]) {
    // Fail loud at the tap with actionable copy instead of opening a destination picker and
    // then handing the engine a dead path that surfaces as a raw "no such file".
    guard canonicalAudioIsOnDisk else {
      exportPhase = .failed(canonicalMissingMessage)
      return
    }
    exportTask?.cancel()
    exportPhase = .exporting(current: 0, total: targets.count)
    // Freeze the removal set the export gate just approved. `renderTargets` runs after the
    // destination picker's await, and undo/redo are only *blocked* while exporting — this tap
    // is still outside that window — so re-reading `timelineRemovals` there could render a
    // timeline the export was never gated on (worst case, a slice that became fully removed
    // mid-picker exporting as a 0-frame file "successfully").
    let removals = Array(timelineRemovals)
    exportTask = Task { await performExport(targets, removals: removals) }
  }

  /// Resolves the export destination, then re-checks the canonical audio is still on disk —
  /// it can vanish while the destination picker is open. Sets the terminal phase and returns
  /// nil when export can't proceed.
  private func exportDestination() async -> URL? {
    guard let destination = await resolvedDestination() else {
      exportPhase = .idle
      return nil
    }
    guard canonicalAudioIsOnDisk else {
      exportPhase = .failed(canonicalMissingMessage)
      return nil
    }
    return destination
  }

  /// Renders every target slice straight from the canonical AIFF (Swift-side, via
  /// `exportRender`), then stamps markers into the rendered files in one batched call to
  /// the engine's `inject-markers` subcommand — the engine no longer touches audio at all.
  /// Each slice gets its own local `EditedTimeline`/`AudioEditRenderPlan` (built from
  /// `removals` — the snapshot taken at the tap that passed the export gate), so a removal is
  /// rendered out rather than silently shipped.
  private func performExport(_ targets: [Slice], removals: [TimelineRemoval]) async {
    guard let destination = await exportDestination() else { return }
    exportPhase = .exporting(current: 0, total: targets.count)

    // Re-check right before touching audio — see `removalsInvalidNote`'s doc comment for
    // why this is defensive rather than routine (the BINDING PR-2 Codex contract).
    guard editedTimeline.isValid else {
      exportPhase = .failed(
        removalsInvalidNote ?? "Removed sections failed validation — export is disabled.")
      return
    }

    let scratchDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-export-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    } catch {
      exportPhase = .failed(error.localizedDescription)
      return
    }

    do {
      let rendered = try await renderTargets(
        targets, removals: removals, scratchDir: scratchDir)
      if Task.isCancelled {
        await removeWorkDir(scratchDir)
        exportPhase = .failed(cancelMessage(copied: 0, total: targets.count))
        return
      }
      try await engine.injectMarkers(rendered.injectionFiles)
      await finishExport(
        targets: targets, outputsByID: rendered.outputsByID,
        scratchDir: scratchDir, destination: destination)
    } catch is CancellationError {
      await removeWorkDir(scratchDir)
      exportPhase = .failed(cancelMessage(copied: 0, total: targets.count))
    } catch {
      await removeWorkDir(scratchDir)
      exportPhase = .failed(error.localizedDescription)
    }
  }

  /// One render pass's output: each target's rendered file, plus the SAME-order marker
  /// list `injectMarkers` will stamp into those files.
  private struct RenderedTargets {
    var outputsByID: [Slice.ID: URL]
    var injectionFiles: [MarkerInjectionFile]
  }

  /// Renders each target slice from the canonical AIFF into `scratchDir`. Each slice gets its
  /// own local `EditedTimeline`/`AudioEditRenderPlan` built from `removals` — the snapshot
  /// `startExport` took at the gating moment, NOT a fresh read of `timelineRemovals`, so the
  /// exported audio is exactly the timeline that enabled the export.
  private func renderTargets(
    _ targets: [Slice], removals: [TimelineRemoval], scratchDir: URL
  ) async throws -> RenderedTargets {
    let sampleRate = editPlan.source.sampleRate
    let sourceDurationSamples = editPlan.source.durationSamples
    // RAW absolute source-sample marker positions straight from the loaded plan words —
    // no global tie-nudge here. `SliceRenderPlanBuilder.markers` maps each marker into
    // slice-relative EDITED space and applies the strictly-increasing nudge itself.
    let sourceMarkers = editPlan.words.map { word in
      RenderMarker(
        position: word.startSample ?? Int(word.start * Double(sampleRate)), name: word.text)
    }

    var outputsByID: [Slice.ID: URL] = [:]
    var injectionFiles: [MarkerInjectionFile] = []
    for (offset, slice) in targets.enumerated() {
      try Task.checkCancellation()
      // The bounds check the Python `run_render` used to do (start >= 0, end > start,
      // end <= frame count). A stale or hand-edited slice would otherwise trap forming the
      // range, or read past the canonical file's end deep inside the renderer.
      guard slice.startSample >= 0, slice.startSample < slice.endSample,
        slice.endSample <= sourceDurationSamples
      else {
        throw ExportRenderError.invalidSliceRange(
          name: slice.name, start: slice.startSample, end: slice.endSample,
          duration: sourceDurationSamples)
      }
      exportPhase = .exporting(current: offset + 1, total: targets.count)
      let sliceRange = slice.startSample..<slice.endSample
      let plan = SliceRenderPlanBuilder.plan(sliceRange: sliceRange, removals: removals)
      let outputURL = scratchDir.appendingPathComponent("\(slice.id.uuidString).aiff")
      let job = ExportRenderJob(
        canonicalAudioURL: canonicalAudioURL, plan: plan.plan,
        editedDurationSamples: plan.editedDurationSamples, sampleRate: sampleRate,
        sourceDurationSamples: sourceDurationSamples, outputURL: outputURL)
      try await exportRender.renderSlice(job)
      outputsByID[slice.id] = outputURL
      let markers = SliceRenderPlanBuilder.markers(
        sourceMarkers, sliceRange: sliceRange, localTimeline: plan.localTimeline)
      injectionFiles.append(MarkerInjectionFile(url: outputURL, markers: markers))
    }
    return RenderedTargets(outputsByID: outputsByID, injectionFiles: injectionFiles)
  }

  /// Copies the rendered files to `destination` and sets the terminal `exportPhase` —
  /// success, a copy failure, a mid-copy cancel, or (defensively) a count mismatch.
  private func finishExport(
    targets: [Slice], outputsByID: [Slice.ID: URL],
    scratchDir: URL, destination: URL
  ) async {
    // Copy off the main actor — copying many/large AIFFs (or to a slow/network
    // folder) must not freeze the UI or block the cancel control.
    let stem = sourceURL.deletingPathExtension().lastPathComponent
    let outcome = await Self.copyRenderedSlices(
      stem: stem, targets: targets, renderedByID: outputsByID, destination: destination)
    await removeWorkDir(scratchDir)

    if outcome.cancelled || Task.isCancelled {
      // A cancel landing during the final copy also lands here, so the cancel
      // button can never report success.
      exportPhase = .failed(cancelMessage(copied: outcome.copied.count, total: targets.count))
    } else if let message = outcome.errorMessage {
      exportPhase = .failed(message)
    } else if outcome.copied.count != targets.count {
      // Defense-in-depth: `outputsByID` is built 1:1 with `targets` above, so this
      // shouldn't be reachable — but report a short result rather than claim success.
      exportPhase = .failed("Rendered \(outcome.copied.count) of \(targets.count) slices.")
    } else {
      workspace.reveal(outcome.copied)
      exportPhase = .done(count: outcome.copied.count)
    }
  }

  private func resolvedDestination() async -> URL? {
    if let destinationURL { return destinationURL }
    guard let chosen = await workspace.chooseDirectory() else { return nil }
    destinationURL = chosen
    return chosen
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
  /// Previewing a boundary edit made inside the slice-detail edit modal. Treated like
  /// `.draftPreview`: no slice-row highlight, and the main transcript must not follow while the
  /// modal previews.
  case sliceEdit

  /// True while a saved slice is the playing context — drives the slice-row "playing" highlight.
  var isSlice: Bool {
    if case .slice = self { return true }
    return false
  }

  /// The listen contexts — a straight Play (`free`) or slice playback — that drive the
  /// transcript's current-word follow (auto-scroll). A boundary preview or audition must NOT
  /// yank the transcript from where the user scrolled, so it does not follow.
  var followsTranscript: Bool {
    switch self {
    case .free, .slice: return true
    case .draftPreview, .audition, .sliceEdit: return false
    }
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
  var isPlaying: Bool
  var playButtonLabel: String
  var isActive: Bool
  var canFineTune: Bool
  /// False when the slice's audio is entirely inside a removed section — there is
  /// nothing left to export, so the row shows `removedLabel` instead of an export button.
  var canExport: Bool
  var removedLabel: String
  var removedHelp: String
}

/// The identity of a fine-tune edit session — the active slice, or a live transcript
/// selection. When this changes the view asks the model to reconcile the open session.
struct FineTuneSessionKey: Equatable {
  var activeSliceID: Slice.ID?
  var activeSliceRange: Range<Int>?
  var selection: Range<Int>?
}

/// Transient state for an in-progress waveform marquee drag. `anchorSample` is the fixed edge in
/// source samples (captured once, so a mid-drag zoom/resize can't move it); `currentX` is the live
/// dragged edge in view coordinates. For a Shift-extend, `existingAnchorSample` holds the pre-drag
/// selection anchor (in source samples) that the extend must preserve.
private struct WaveformAreaSelectDrag {
  var anchorSample: Int
  var currentX: CGFloat
  var existingAnchorSample: Int?
}
