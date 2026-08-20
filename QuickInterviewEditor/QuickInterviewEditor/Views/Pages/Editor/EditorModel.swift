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
}

@MainActor
@Observable
final class EditorModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.audioPlayer) var audioPlayer
  @ObservationIgnored @Dependency(\.engine) var engine
  @ObservationIgnored @Dependency(\.workspace) var workspace
  @ObservationIgnored @Dependency(\.continuousClock) var clock

  // MARK: - Shared State
  /// The per-file project sidecar, keyed by `sourceFingerprint` — the same store
  /// `cutSuggestions` shares, so both stay backed by one file. Only `timelineRemovals`
  /// is written through here; the sidecar's other sections are `cutSuggestions`' concern.
  @ObservationIgnored @Shared var projectState: ProjectState

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
  /// THE persistent, always-visible playhead cursor, in plan samples. Follows audio during
  /// playback and stays put when stopped/paused (never hidden). Kept a SEPARATE observed property
  /// (not folded into a transport struct) so its ~30 Hz updates don't invalidate views that read
  /// `transportPhase`/`transportContext` (the panel, the slice list).
  var playheadSample = 0 {
    didSet { syncCurrentWordToCursor() }
  }

  /// Keeps the transcript's current-word highlight on the word under the cursor, so it tracks
  /// where you ARE — playing, paused, scrubbed, ruler-moved, or stopped — never a stale
  /// last-heard word. Keeps the last word in a gap (never lose your place) and only writes on a
  /// real change so a 30 Hz cursor doesn't churn the transcript view.
  private func syncCurrentWordToCursor() {
    guard let word = wordID(atSample: playheadSample), word != transcript.currentWordID else {
      return
    }
    transcript.currentWordID = word
  }
  /// Where the transport last started playing; Stop returns the cursor here.
  var transportOriginSample: Int?
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
  private func syncEditedTimeline() {
    editedWaveform.timeline = editedTimeline
    editedWaveform.timelineChanged()
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
      selection: selectedSourceRange)
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
  /// viewport. The model owns the cursor's SOURCE sample; the adapter supplies the geometry, so
  /// the view stays logic-free.
  var playheadX: CGFloat? { editedWaveform.playheadX(forSource: playheadSample) }

  // MARK: - Seam overlays
  /// The bowtie spans the lane draws at each seam, mapped to edited view coordinates by the
  /// adapter (nil, and so dropped, for a fully-clamped or off-screen seam). A model computed
  /// prop so the view only binds — it never derives waveform geometry. Reads the adapter's
  /// already-synced `editedTimeline` (kept current by `syncEditedTimeline()` on every removal
  /// change) rather than rebuilding one, since `editedTimeline` constructs a fresh value on
  /// every read.
  var seamSpans: [WaveformSpan] {
    editedWaveform.timeline.seams.compactMap(editedWaveform.spanForSeam)
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
    guard let range = audioSelection else { return "No selection" }
    let count = wordIDs(anyOverlap: range, words: editPlan.words).count
    return "\(count) word\(count == 1 ? "" : "s") selected"
  }
  // Undo/redo restore `slices` wholesale; doing that under an open cut edit would leave the
  // draft anchored to a stale committed range, so gate on Save/Cancel first.
  var canUndo: Bool { documentUndo.canUndo && !hasUncommittedSliceEdit }
  var canRedo: Bool { documentUndo.canRedo && !hasUncommittedSliceEdit }

  var sliceCountLabel: String {
    "\(slices.count) \(slices.count == 1 ? "clip" : "clips")"
  }

  var isExporting: Bool {
    if case .exporting = exportPhase { return true }
    return false
  }
  var canExportAll: Bool {
    !slices.isEmpty && !isExporting && !hasUncommittedSliceEdit && timelineRemovals.isEmpty
  }
  var canExportSlice: Bool {
    !isExporting && !hasUncommittedSliceEdit && timelineRemovals.isEmpty
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

  /// Surfaces why export is disabled while a timeline removal is pending: cuts collapse
  /// the waveform and transcript but aren't applied to the rendered audio yet (that's
  /// PR 2), so exporting now would silently ship the removed section. `nil` when there's
  /// nothing to warn about.
  var exportBlockedByRemovalsNote: String? {
    timelineRemovals.isEmpty
      ? nil
      : "Export is paused while a removed section is pending — cuts aren't applied to exports yet (coming next)."
  }

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
        playheadSample = position.sample
        // The slice-detail edit modal owns its own scoped playhead/transcript while it's the
        // playback context, so push the live position into it here — the modal has no other way
        // to see ticks from the shared player.
        if case .sliceEdit = transportContext {
          editSlice?.updatePlayback(sample: position.sample, isPlaying: true)
        }
        // The listen contexts (a plain Play and slice playback) drive transcript auto-scroll
        // follow, so reading along works during a plain Play, not only slice playback. Preview/
        // audition update the cursor (and thus the highlight) but must not yank the transcript
        // from where the user scrolled.
        transcript.playheadChanged(
          sample: position.sample, isPlaying: transportContext.followsTranscript)
      } else {
        if transportContext.followsTranscript {
          // A false tick ends transcript follow (so the next playback reads as a rising edge) but
          // leaves the cursor and the current-word highlight where the audio stopped.
          endTranscriptFollow()
        }
        if case .sliceEdit = transportContext {
          editSlice?.updatePlayback(sample: playheadSample, isPlaying: false)
        }
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
      clearSelection()
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
      playheadSample = lower
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
  private func applyEdgeEdit(_ edge: SelectionEdge, of old: Range<Int>, to updated: Range<Int>) {
    let anchorTracksEditedEdge =
      edge == .start
      ? selectionAnchorSample == old.lowerBound
      : selectionAnchorSample == old.upperBound
    audioSelection = updated
    if anchorTracksEditedEdge {
      selectionAnchorSample = edge == .start ? updated.lowerBound : updated.upperBound
    }
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
      // Falls through (returns false) when nothing removable is selected, so the event still
      // reaches a focused slice row's List `.onDelete` — the intended arbitration between the
      // two delete targets.
      guard canRemoveSelectedSection else { return false }
      Task { await removeSelectedSectionTapped() }
    case .nudgeCutInEarlier, .nudgeCutInLater, .nudgeCutOutEarlier, .nudgeCutOutLater:
      return nudgeSelection(key)
    }
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
  /// re-accept is a no-op), routed through `mutateSlices` so it's exportable and undoable.
  /// Known limitation: undoing/deleting the slice later does not un-accept the suggestion
  /// in the sidecar — full accept/reject reconciliation is deferred.
  func acceptCutSuggestionSlice(_ slice: Slice) {
    guard slices[id: slice.id] == nil else { return }
    mutateSlices { $0.append(slice) }
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
    selectSourceRange(range, snapPlayhead: true)
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
    child.onCommit = { [weak self] range in self?.commitSliceEdit(id: id, range: range) }
    child.onPlay = { [weak self] range in
      // Logic model: Play always plays `range` from the playhead as a fresh, exclusive `.sliceEdit`
      // playback (the child derives `range` from the cursor). Pause merely freezes the cursor; the
      // next Play re-plays from it, and seeking mid-play passes a new range here to re-anchor. There
      // is no bespoke resume/drift branch — `beginTransportPlayback` supersedes any prior (playing or
      // paused) session cleanly.
      await self?.beginTransportPlayback(range: range, context: .sliceEdit)
    }
    child.onPause = { [weak self] in
      guard let self else { return }
      await transportPauseTapped()
      // Publish the frozen cursor back to the sheet so its "play from the playhead" uses the exact
      // pause point (the position loop stops ticking once paused, so it won't otherwise learn it).
      editSlice?.updatePlayback(sample: playheadSample, isPlaying: isTransportPlaying)
    }
    child.onStop = { [weak self] in
      guard let self else { return }
      await transportStopTapped()
      // Stop returns the cursor to the play origin; publish it so the sheet's next "play from the
      // playhead" starts there rather than from a stale last-tick sample.
      editSlice?.updatePlayback(sample: playheadSample, isPlaying: isTransportPlaying)
    }
    // R4: the transport always plays a whole range, never from an arbitrary point. This callback is
    // the CURSOR-ONLY path — it repositions the persistent cursor and starts nothing. A seek taken
    // WHILE playing on the waveform body does not reach here: `EditSliceModel.waveformSeeked` routes
    // that case to `onPlay`, which re-anchors playback from the click to the cut-out.
    child.onSeek = { [weak self] sample in
      guard let self else { return }
      playheadSample = sample
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
    if let origin = transportOriginSample { playheadSample = origin }
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
    let slice = Slice(
      id: UUID(),
      name: "Slice \(nextSliceNumber)",
      startSample: range.lowerBound,
      endSample: range.upperBound,
      wordIDs: wordIDs,
      snippet: displaySnippet(sliceSnippet(for: wordIDs, words: editPlan.words)),
      warnings: sliceWarnings(
        startSample: range.lowerBound, endSample: range.upperBound,
        durationSamples: editPlan.source.durationSamples, silences: editPlan.silences)
    )
    mutateSlices { $0.append(slice) }
    nextSliceNumber += 1
    transcript.clearSelectionTapped()
  }

  // MARK: - Timeline Removals
  /// The default crossfade every new removal starts with — 20 ms at the plan's sample
  /// rate. PR 2 makes it user-editable per removal.
  var defaultCrossfadeSamples: Int { Int(0.020 * Double(editPlan.source.sampleRate)) }

  /// Surfaces the interim limitation while removals exist but playback hasn't caught up:
  /// the collapsed waveform and transcript reflect the removal, but the transport still
  /// plays the original contiguous audio (no crossfade blend yet — that lands in PR 2).
  /// `nil` when there's nothing to warn about.
  var removalPlaybackNote: String? {
    timelineRemovals.isEmpty ? nil : "Playback preview does not yet blend cuts (coming next)."
  }

  /// True while a `.pendingSelection` fine-tune session's draft is still anchored to the CURRENT
  /// The SOURCE range a removal would apply to: the primary selection. Edge drag + nudge now mutate
  /// `audioSelection` directly (see `selectionNudged` / `selectionEdgeDragged`), so there is no
  /// separate fine-tune draft to prefer — the selection is already the (possibly nudged) truth.
  private var pendingRemovalSourceRange: Range<Int>? { selectedSourceRange }

  /// Whether `range` can become a removal: non-empty and not overlapping an
  /// existing removal's source span (cross-seam rejection, spec §4.7).
  func canRemove(sourceRange range: Range<Int>) -> Bool {
    guard range.lowerBound < range.upperBound else { return false }
    return !timelineRemovals.contains { $0.removedRange.overlaps(range) }
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
    guard !isExporting, let range = pendingRemovalSourceRange, canRemove(sourceRange: range)
    else {
      return
    }
    let removal = TimelineRemoval(
      id: UUID(), removedRange: range,
      crossfade: Crossfade(lengthSamples: defaultCrossfadeSamples, curve: .equalPower))
    mutateDocument { doc in
      doc.timelineRemovals.append(removal)
      doc.timelineRemovals = IdentifiedArray(
        uniqueElements: TimelineRemovals.normalize(Array(doc.timelineRemovals))
          ?? Array(doc.timelineRemovals))
    }
    transcript.clearSelectionTapped()
    fineTune.clear()
    await reconcilePlayback()
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
    // while an existing-slice edit is open, which would rewind `slices` under a live draft.
    guard !hasUncommittedSliceEdit, let restored = documentUndo.undo(current: documentState)
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
    guard !hasUncommittedSliceEdit, let restored = documentUndo.redo(current: documentState)
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
    return isTransportPaused || transportPlayableRange != nil
  }
  var canTransportPause: Bool { isTransportPlaying }
  var canTransportStop: Bool { isTransportPlaying || isTransportPaused }

  /// What a Play-from-stopped would play: from the cursor to the selection's end (if a selection
  /// is active) else end-of-audio, clamped to the file. Nil when the cursor is at/after that end,
  /// so Play is a no-op (Logic: pressing Play with the cursor past the region does nothing).
  private var transportPlayableRange: Range<Int>? {
    // Play is a straight listen-through: it runs from the cursor to the END OF THE FILE and never
    // stops at a selection boundary. A selection is for marking a clip, not for scoping playback.
    let end = editPlan.source.durationSamples
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
    playheadSample = range.lowerBound
    // A transport start authoritatively places the cursor, so it takes cursor authority too: a
    // selection snap deferred from before this Play must bail rather than stop us and snap back.
    cursorMoveGeneration &+= 1
    transportPhase = .playing(session)
    let outcome: PlaybackEnd
    do {
      // The speed rides along with the start (not a separate awaited call), so no suspension point
      // sits between `.playing(session)` and the player marking the session current — a Stop or
      // selection snap can't slip in and orphan the audio.
      outcome = try await audioPlayer.play(
        canonicalAudioURL, range, editPlan.source.sampleRate, transcript.playbackRate, session)
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
    owningSliceEdit?.updatePlayback(sample: playheadSample, isPlaying: false)
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
    guard editedWaveform.hasUsableGeometry else { return }
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
    min(max(0, editedWaveform.xToSourceSample(positionX)), editPlan.source.durationSamples)
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
    guard !isExporting, !hasUncommittedSliceEdit, timelineRemovals.isEmpty,
      let slice = slices[id: id]
    else { return }
    startExport([slice])
  }

  func exportAllTapped() {
    guard !isExporting, !hasUncommittedSliceEdit, timelineRemovals.isEmpty, !slices.isEmpty else {
      return
    }
    startExport(Array(slices))
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

  /// Re-derives a slice's word membership, snippet, and warnings for a new sample range once
  /// the cut points move. Membership is by overlap ("a word is in a clip iff any of its audio
  /// overlaps the range" — the spec's single clip-membership rule), matching how a clip is built
  /// from a freeform selection so editing a clip's boundaries can never silently drop a word that
  /// creating it included.
  private func updatedSlice(_ slice: Slice, to range: Range<Int>) -> Slice {
    var updated = slice
    updated.startSample = range.lowerBound
    updated.endSample = range.upperBound
    updated.wordIDs = wordIDs(anyOverlap: range, words: editPlan.words)
    updated.snippet = displaySnippet(sliceSnippet(for: updated.wordIDs, words: editPlan.words))
    updated.warnings = sliceWarnings(
      startSample: range.lowerBound, endSample: range.upperBound,
      durationSamples: editPlan.source.durationSamples, silences: editPlan.silences)
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
    exportTask = Task { await performExport(targets) }
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

  private func performExport(_ targets: [Slice]) async {
    guard let destination = await exportDestination() else { return }
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
/// source samples (captured once, so a mid-drag zoom/resize can't move it); `currentX` is the live
/// dragged edge in view coordinates. For a Shift-extend, `existingAnchorSample` holds the pre-drag
/// selection anchor (in source samples) that the extend must preserve.
private struct WaveformAreaSelectDrag {
  var anchorSample: Int
  var currentX: CGFloat
  var existingAnchorSample: Int?
}
