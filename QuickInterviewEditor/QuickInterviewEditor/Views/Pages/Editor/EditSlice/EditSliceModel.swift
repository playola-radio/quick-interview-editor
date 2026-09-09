import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class EditSliceModel: ViewModel, Identifiable {

  // MARK: - Initialization
  let target: ClipEditTarget
  var sliceID: Slice.ID { target.resultingClipID }
  private let editPlan: EditPlan
  let fineTune: FineTuneModel
  let title: String
  let overviewWindow: Range<Int>
  let transcript: TranscriptPageModel
  /// The sheet's OWN source-pure ``WaveformModel`` — the parent's already-decoded pyramid, adopted
  /// so nothing is re-decoded. It is NOT the parent's instance (that one is bound to the main
  /// editor's viewport). It stays source-pure: the fine-tune insets and the amplitude-zoom button
  /// read it directly. The navigable lane renders on ``editedWaveform`` instead.
  let waveform: WaveformModel
  var editingComplete: Bool
  /// The collapsed (EDITED) lane the sheet renders and hit-tests, pinned to this slice's edited
  /// extent so you cannot scroll or zoom past its boundaries. It shares ``waveform``'s source
  /// pyramid and carries the parent's ``EditedTimeline`` (seeded and kept in sync by `EditorModel`;
  /// identity here until the parent supplies real removals), so a removal inside the slice collapses
  /// on this lane exactly as it does on the main timeline.
  let editedWaveform: EditedWaveformAdapter

  convenience init(slice: Slice, editPlan: EditPlan) {
    self.init(
      target: .savedClip(slice.id), title: slice.name,
      range: slice.startSample..<slice.endSample, editPlan: editPlan,
      scopedWordIDs: slice.wordIDs)
    editingComplete = slice.editingComplete
  }

  init(
    target: ClipEditTarget, title: String, range: Range<Int>, editPlan: EditPlan,
    scopedWordIDs: [Word.ID]? = nil
  ) {
    self.target = target
    self.title = title
    self.editPlan = editPlan
    editingComplete = false
    fineTune = FineTuneModel(
      sampleRate: editPlan.source.sampleRate,
      durationSamples: editPlan.source.durationSamples,
      silences: editPlan.silences)
    overviewWindow = range
    let sliceWordIDSet = Set(scopedWordIDs ?? wordIDs(anyOverlap: range, words: editPlan.words))
    let scopedWords = editPlan.words.filter { sliceWordIDSet.contains($0.id) }
    let scopedPlan = EditPlan(
      schemaVersion: editPlan.schemaVersion,
      source: editPlan.source,
      words: scopedWords,
      silences: editPlan.silences,
      segments: editPlan.segments,
      transcriptSegments: editPlan.transcriptSegments)
    transcript = TranscriptPageModel(editPlan: scopedPlan)
    let waveformModel = WaveformModel()
    waveform = waveformModel
    editedWaveform = EditedWaveformAdapter(
      source: waveformModel,
      timeline: EditedTimeline(
        sourceDurationSamples: editPlan.source.durationSamples, removals: []))
    super.init()
    fineTune.begin(
      target: target.isDraft ? .pendingSelection : .slice(target.resultingClipID), range: range)
    editedWaveform.setNavigableEditedRange(pinnedEditedRange)
    wireTranscriptSelection()
  }

  // MARK: - Properties
  var onCommit: (Range<Int>) -> ClipEditCommitResult = { _ in
    .failed("Saving is unavailable. Try opening this edit again.")
  }
  var onInvalidatePreview: () -> Void = {}
  private(set) var commitError: String?
  private(set) var invalidationReason: String?
  private(set) var didCommit = false
  private var draftHistory = UndoStack<Range<Int>>()
  private(set) var boundaryGestureStart: Range<Int>?
  private var ignoresBoundaryGestureUpdates = false
  var onDismiss: () -> Void = {}
  /// Applies an editing-complete toggle immediately (no Save dependency), routed to the
  /// parent's `setSliceEditingComplete`.
  var onSetEditingComplete: (Bool) -> Void = { _ in }
  var onPlay: (Range<Int>) async -> Void = { _ in }
  var onPause: () async -> Void = {}
  var onStop: () async -> Void = {}
  var onSeek: (Int) async -> Void = { _ in }
  /// Removes a SOURCE range from the shared timeline (routed to the parent's `removeSourceRange`
  /// merge funnel, so a marquee crossing an existing removal merges into one larger removal exactly
  /// as on the main timeline).
  var onRemoveSection: (Range<Int>) async -> Void = { _ in }
  /// Restores a removal by id (routed to the parent's `restoreRemoval`).
  var onRestore: (TimelineRemoval.ID) -> Void = { _ in }
  /// Commits a stretched crossfade length through the parent's `updateCrossfade` funnel as one undo
  /// step. The sheet supplies the slice-local length it can actually play.
  var onStretchCrossfade: (TimelineRemoval.ID, Int) -> Void = { _, _ in }
  /// The removal's current STORED crossfade length (from the parent's document), which can exceed the
  /// seam's slice-local rendered length. A stretch retains it as the document baseline so a stale
  /// drag cannot overwrite a concurrent change and a no-op drag never collapses latent fade intent.
  var currentCrossfadeLength: (TimelineRemoval.ID) -> Int? = { _ in nil }
  /// Whether the parent will accept a crossfade edit right now (it refuses mid-export, when the
  /// removal set is frozen). Asked before a stretch starts, so the sheet never previews a drag the
  /// parent's `updateCrossfade` funnel would discard on release — the main lane's begin-time refusal.
  var canEditCrossfade: () -> Bool = { true }
  /// Commits a cut-point move through the parent's `updateRemovalRange` funnel as one undo step: the
  /// moved `removedRange` only — moving a cut never rewrites the stored fade duration, so the move is
  /// non-destructive: the fade renders as short as fits near the edge and the full stored length
  /// returns when the cut pulls back out. The sheet drafts against its own lane and hands the clamped
  /// range here; the parent fans the result back via `syncTimeline`.
  var onMoveCutPoint: (TimelineRemoval.ID, Range<Int>) -> Void = { _, _ in }
  /// Clamps a proposed cut-point range against the parent's GLOBAL timeline (neighbor removals, the
  /// opposite cut, non-empty). The sheet intersects the result with the slice window
  /// (``sliceLocalClampedRemovalRange``). Returns `proposed` unchanged by default (unwired parent).
  var clampCutPointRange: (TimelineRemoval.ID, Range<Int>) -> Range<Int> = { _, proposed in
    proposed
  }
  /// The parent document's STORED removals (the whole global set, with un-clamped fade lengths). The
  /// cut-point preview builds its timeline from THESE — exactly as the parent's commit does — so the
  /// live bowtie and the released commit land on identical geometry (no jump). The lane's own
  /// ``editedWaveform`` carries EFFECTIVE (already geometry-clamped) fades, so previewing from it lets a
  /// crowded neighbor's rendered fade stay stuck below its stored length while the commit expands it
  /// back, shifting every downstream seam on release. Returns an empty set by default (unwired parent),
  /// which falls the preview back to the lane's effective removals.
  var currentStoredRemovals: () -> [TimelineRemoval] = { [] }
  /// Undo / redo the shared document (routed to the parent's `undoTapped`/`redoTapped`). A modal
  /// removal is a document edit on the parent's undo stack, so ⌘Z inside the sheet rewinds it — the
  /// sheet's own key monitor forwards ⌘Z/⌘⇧Z here because the main window's undo shortcut is not in
  /// the sheet's responder chain while the sheet is key.
  var onUndo: () async -> Void = {}
  var onRedo: () async -> Void = {}
  var isPlaying = false
  var playheadSample: Int?

  // MARK: - Marquee removal selection
  /// The interior span the user marquee-dragged on the collapsed lane, a SOURCE range clamped to the
  /// slice. Drawn as the lane highlight while set; Remove acts on it. Mutually exclusive with a seam
  /// selection. Cleared once the removal is applied (the timeline collapses it away).
  private(set) var waveformSelection: Range<Int>?
  /// The seam (existing removal) the user context-clicked, for Restore. Mutually exclusive with
  /// `waveformSelection`.
  var selectedSeamID: TimelineRemoval.ID?
  @ObservationIgnored private var marqueeAnchorSample: Int?
  @ObservationIgnored private var marqueeCurrentX: CGFloat?

  // MARK: - Crossfade stretch (edge drag)
  /// The live edge-drag stretch on this sheet's lane; previews the bowtie via `seamOverlays` and
  /// commits through the parent on release, clamped to what this slice can play.
  private(set) var crossfadeStretchDraft: CrossfadeStretchDraft?
  @ObservationIgnored private var crossfadeStretchInitialRenderedLength: Int?

  // MARK: - Crossfade cut-point drag (⌥-drag the outside waveform)
  /// The live ⌥-drag of a cut point on this sheet's lane. Unlike the stretch (overlay-only), a cut-
  /// point move changes the removal RANGE, which reflows the slice's edited footprint — not
  /// representable as a bowtie-width tweak — so this drag reflows the lane live like the main editor,
  /// with the navigable pin and viewport frozen at drag begin so the reflow can't feed back on the
  /// drag math or fight the pin. Commits once on release through the parent's `updateRemovalRange`.
  private(set) var crossfadeCutPointDraft: CrossfadeCutPointDraft?

  // MARK: - Display Text
  let saveLabel = "Save cut"
  let cancelLabel = "Cancel"
  let stopLabel = "Stop"
  let removeSectionLabel = "Remove Section"
  let restoreRemovedAudioLabel = "Restore Removed Audio"

  // MARK: - View Helpers
  var canMutateDocument: Bool { !target.isDraft }
  var canUndoDraft: Bool { target.isDraft && draftHistory.canUndo }
  var canRedoDraft: Bool { target.isDraft && draftHistory.canRedo }
  var canSave: Bool {
    guard !didCommit, invalidationReason == nil, let range = fineTune.draftRange,
      fineTune.isValidDraftRange(range), !wordIDs(anyOverlap: range, words: editPlan.words).isEmpty
    else { return false }
    return target.isDraft || fineTune.hasUnsavedChange
  }

  func invalidate(_ reason: String) {
    guard invalidationReason == nil else { return }
    invalidationReason = reason
    commitError = reason
    invalidateDraftPreview()
  }
  var playPauseLabel: String { isPlaying ? "Pause" : "Play" }
  var playButtonSystemImage: String { isPlaying ? "pause.fill" : "play.fill" }
  let editingCompleteLabel = "Editing Complete"
  var editingCompleteSystemImage: String { editingComplete ? "checkmark.circle.fill" : "circle" }

  /// What the lane highlights: the live marquee removal selection when the user is picking an interior
  /// span to cut, otherwise the draft kept range (so the kept region reads clearly against the
  /// discarded head/tail). A SOURCE range — the lane maps it through the timeline via
  /// ``EditedWaveformAdapter/laneSpan(forSource:)``.
  var waveformHighlightRange: Range<Int>? { waveformSelection ?? fineTune.draftRange }

  /// Whether the Remove control acts on anything — a marquee selection exists.
  var canRemoveSelection: Bool { canMutateDocument && waveformSelection != nil }

  // MARK: - Seam overlays
  /// The bowtie spans the lane draws at each seam, mapped to the collapsed lane's view coordinates.
  /// The lane runs in GLOBAL coordinates (it adopts the whole-file pyramid and the parent's global
  /// timeline), but every seam draws at the position and length THIS slice actually plays. Slice-
  /// local positions are translated onto the lane at the live slice's first surviving sample, so an
  /// earlier locally clamped fade shifts every later seam exactly as playback and export do. A fade
  /// may never pull audio from outside the slice's cut points, so a latent fade stored longer than
  /// the slice-local handle renders shorter here, and a seam crossing/touching a slice edge collapses
  /// to a hard cut (length 0). During a drag the current local handle clamps only the displayed draft;
  /// the stored draft remains intact for release comparisons. The view only binds; it never derives
  /// geometry.
  var seamOverlays: [SeamOverlay] {
    guard let localTimeline = sliceLocalTimeline else { return [] }
    return localTimeline.seams.compactMap { localSeam in
      guard let seam = laneSeam(for: localSeam) else { return nil }
      let draftOrStoredLength =
        crossfadeStretchDraft.flatMap { $0.id == seam.id ? $0.length : nil }
        ?? localSeam.crossfadeLength
      let length = min(
        draftOrStoredLength,
        localTimeline.maxCrossfadeLength(forSeamID: seam.id) ?? 0)
      guard let span = editedWaveform.spanForSeam(seam, previewLength: length) else { return nil }
      // Stretch handles only on INTERIOR seams — those the slice renders with a real fade. A
      // boundary seam (a removal crossing or touching a slice edge) plays as a hard cut here, so it
      // gets no handle: a drag would author a fade this slice never plays.
      let handles =
        canMutateDocument && isInteriorSeam(seam)
        ? editedWaveform.seamHandleXs(seam, previewLength: length)
        : (leading: nil, trailing: nil)
      return SeamOverlay(
        id: seam.id, span: span, isSelected: seam.id == selectedSeamID,
        leadingHandleX: handles.leading, trailingHandleX: handles.trailing)
    }
  }

  /// Whether the seam's removal lies strictly inside the slice's LIVE cut (the draft while editing),
  /// per the renderer's own rule (`SliceRenderPlanBuilder.isInterior`), so a stretch here is honest:
  /// the slice plays/exports the fade being authored.
  private func isInteriorSeam(_ seam: TimelineSeam) -> Bool {
    guard let slice = slicePlaybackRange,
      let removal = editedWaveform.timeline.removals.first(where: { $0.id == seam.id })
    else { return false }
    return SliceRenderPlanBuilder.isInterior(removal.removedRange, in: slice)
  }

  private func laneSeam(for localSeam: TimelineSeam) -> TimelineSeam? {
    guard let slice = slicePlaybackRange,
      let origin = editedWaveform.timeline.sourceToEdited(slice.lowerBound, bias: .rightEdge)
    else { return nil }
    var seam = localSeam
    seam.sourceCut += slice.lowerBound
    seam.editedCrossfadeStart += origin
    return seam
  }

  private static let seamHitTolerance: CGFloat = 4

  /// The removal id whose drawn bowtie the view-x lands on, or nil. Hit-tests the slice-local
  /// overlays rather than the parent's wider global bowties; nearest center wins when widened
  /// targets overlap.
  func seamID(atX positionX: CGFloat) -> TimelineRemoval.ID? {
    var best: (id: TimelineRemoval.ID, distance: CGFloat)?
    for overlay in seamOverlays {
      let span = overlay.span
      guard positionX >= span.positionX - Self.seamHitTolerance,
        positionX <= span.positionX + span.width + Self.seamHitTolerance
      else { continue }
      let distance = abs(positionX - (span.positionX + span.width / 2))
      if best == nil || distance < best!.distance {
        best = (overlay.id, distance)
      }
    }
    return best?.id
  }

  /// The right-click menu for a lane position: Restore when the x hits a seam (also selects it), else
  /// Remove Section when a marquee selection exists, else empty. Mirrors the main editor's
  /// `seamContextMenuItems` and adds the modal's Remove entry.
  func waveformContextMenuItems(atX positionX: CGFloat) -> [WaveformMenuItem] {
    guard canMutateDocument else { return [] }
    if let id = seamID(atX: positionX) {
      selectSeam(id)
      return [
        WaveformMenuItem(title: restoreRemovedAudioLabel) { [weak self] in self?.onRestore(id) }
      ]
    }
    if canRemoveSelection {
      return [
        WaveformMenuItem(title: removeSectionLabel) { [weak self] in
          Task { await self?.removeSelectionTapped() }
        }
      ]
    }
    return []
  }

  /// The persistent cursor mapped onto the lane's EDITED axis (the lane renders the collapsed
  /// slice). Stored as a SOURCE sample; a position inside a removed span resolves to the seam
  /// (post-cut) via `.rightEdge`, the edited moment that audio first becomes audible.
  var laneCursorSample: Int? {
    guard let sample = playheadSample else { return nil }
    let timeline = editedWaveform.timeline
    return timeline.sourceToEdited(sample, bias: .rightEdge)
      ?? min(max(0, sample), timeline.editedDurationSamples)
  }

  /// The playback cursor mapped into each fixed inset window, in inset-x — the yellow playhead line
  /// on the red Cut-in / Cut-out insets, mirroring ``FineTuneModel/cutInLineX``. Nil when there is no
  /// cursor or it falls outside the window: the inset never scrolls, so an off-window cursor simply
  /// isn't drawn (matching the lane playhead's off-viewport nil). The cursor is a SOURCE sample and
  /// the inset windows are SOURCE-sample ranges, so no timeline mapping is needed.
  var cutInPlayheadX: CGFloat? { insetPlayheadX(in: fineTune.cutInWindow) }
  var cutOutPlayheadX: CGFloat? { insetPlayheadX(in: fineTune.cutOutWindow) }

  private func insetPlayheadX(in window: Range<Int>?) -> CGFloat? {
    guard let sample = playheadSample, let window, window.contains(sample) else { return nil }
    return fineTune.insetX(forSample: sample, in: window)
  }

  /// The slice's collapsed extent on the EDITED axis — what the pinned lane may show. The EDITED
  /// footprint of the slice's surviving (kept) SOURCE audio; identity (no removals) makes it the
  /// slice window verbatim. Using the footprint rather than bracketing the two endpoints with
  /// `sourceToEdited` biases keeps the pin correct when a removal covers a slice boundary or the
  /// whole slice — an empty footprint pins an empty lane (`hasUsableGeometry` false) instead of
  /// falling back to the whole project. Recomputed whenever the timeline changes so a re-pin follows
  /// a sync.
  private var pinnedEditedRange: Range<Int> {
    editedWaveform.timeline.editedFootprint(ofSource: overviewWindow) ?? 0..<0
  }

  var canZoomIn: Bool { editedWaveform.canZoomIn }
  var canZoomOut: Bool { editedWaveform.canZoomOut }
  var zoomInLabel: String { waveform.zoomInLabel }
  var zoomOutLabel: String { waveform.zoomOutLabel }

  /// The slice's current playable bounds — the live draft while editing, the committed cut otherwise.
  private var slicePlaybackRange: Range<Int>? { fineTune.draftRange ?? fineTune.committedRange }

  /// The slice-LOCAL timeline: the parent's removals clipped to the live cut and rebased to
  /// slice-relative samples (`SliceRenderPlanBuilder.localTimeline`, the same view slice playback and
  /// export build). This is the honest lens on what THIS slice actually plays — a fade may never pull
  /// audio from outside the slice's cut points — so the stretch clamp (``crossfadeStretched(toLength:)``,
  /// ``crossfadeStretchEnded``) and the drawn bowtie lengths (``seamOverlays``) read their ceiling
  /// here, not from the parent's global timeline. Removal ids survive the rebase, so seam-id lookups
  /// line up with the global lane. Nil when the slice has no live playable range.
  private var sliceLocalTimeline: EditedTimeline? {
    guard let slice = slicePlaybackRange else { return nil }
    return SliceRenderPlanBuilder.localTimeline(
      sliceRange: slice, removals: editedWaveform.timeline.removals)
  }

  /// The largest crossfade seam `id` can take on THIS slice — its slice-local handle. For an interior
  /// seam the slice can only shrink the available audio, so this is always <= the global handle and
  /// `min(global, local)` reduces to local; the sheet clamps to this alone. 0 when the slice has no
  /// live range or the seam has no handle on a clipped side.
  private func sliceLocalMaxCrossfade(forSeamID id: TimelineRemoval.ID) -> Int {
    sliceLocalTimeline?.maxCrossfadeLength(forSeamID: id) ?? 0
  }

  /// What Play plays: from the playhead to the slice's cut-out (Logic parity — Play always starts at
  /// the playhead). When the cursor sits outside the slice (before the cut-in or at/after the
  /// cut-out) it falls back to the cut-in, so Play always previews something.
  private var playFromCursorRange: Range<Int>? {
    guard let slice = slicePlaybackRange, slice.lowerBound < slice.upperBound else { return nil }
    if let cursor = playheadSample, slice.contains(cursor) { return cursor..<slice.upperBound }
    return slice.lowerBound..<slice.upperBound
  }

  func cutInColumns() -> [WaveformColumn] {
    fineTune.cutInWindow.map { waveform.columns(in: $0, pixelWidth: fineTune.insetWidthPixels) }
      ?? []
  }
  func cutOutColumns() -> [WaveformColumn] {
    fineTune.cutOutWindow.map { waveform.columns(in: $0, pixelWidth: fineTune.insetWidthPixels) }
      ?? []
  }

  // MARK: - User Actions
  func saveTapped() {
    guard canSave, let draft = fineTune.draftRange else { return }
    boundaryGestureEnded()
    switch onCommit(draft) {
    case .committed:
      didCommit = true
      commitError = nil
      onDismiss()
    case .failed(let message):
      commitError = message
    }
  }

  func cancelTapped() {
    fineTune.resetDraft()
    onDismiss()
  }

  /// Flips the completion flag and applies it immediately — there is no Save dependency for
  /// this toggle, so Cancel does not revert it.
  func editingCompleteToggled() {
    guard canMutateDocument else { return }
    editingComplete.toggle()
    onSetEditingComplete(editingComplete)
  }

  func cutInDragged(toInsetX positionX: CGFloat) {
    guard !ignoresBoundaryGestureUpdates else { return }
    fineTune.dragCutIn(toInsetX: positionX)
  }
  func cutOutDragged(toInsetX positionX: CGFloat) {
    guard !ignoresBoundaryGestureUpdates else { return }
    fineTune.dragCutOut(toInsetX: positionX)
  }
  // The nudge direction and step live on the model, so the view forwards a named action rather
  // than deciding the sign/magnitude of the delta itself.
  func cutInNudgedBack() { recordDraftNudge { fineTune.nudgeCutIn(byMs: -fineTune.nudgeMs) } }
  func cutInNudgedForward() { recordDraftNudge { fineTune.nudgeCutIn(byMs: fineTune.nudgeMs) } }
  func cutOutNudgedBack() { recordDraftNudge { fineTune.nudgeCutOut(byMs: -fineTune.nudgeMs) } }
  func cutOutNudgedForward() { recordDraftNudge { fineTune.nudgeCutOut(byMs: fineTune.nudgeMs) } }

  /// Bumped at the start of every transport-mutating user action (Play/Pause, Stop, the audition
  /// hotkeys, a waveform seek). `stopTapped`'s `onStop` and `playPauseTapped`'s pause-branch
  /// `onPause` both suspend, and a newer action can start and finish entirely while one of those is
  /// still in flight (e.g. `[` toggles an audition off — suspending in `stopTapped`'s `onStop` — then
  /// `]` starts a new audition before the old continuation resumes). Capturing the generation before
  /// the await and checking it after lets that stale continuation detect it lost the race and skip
  /// overwriting the newer state. Mirrors `EditorModel`'s `cursorMoveGeneration` guard.
  @ObservationIgnored private var transportActionGeneration = 0

  func playPauseTapped() async {
    transportActionGeneration += 1
    activeAudition = nil
    if isPlaying {
      let generation = transportActionGeneration
      await onPause()
      guard generation == transportActionGeneration else { return }
      isPlaying = false
    } else {
      await startPlaybackFromCursor()
    }
  }

  /// Space in the sheet — unified with the main window's transport toggle: Play when stopped, Stop
  /// (which returns the playhead to where playback began, via the parent's `onStop`) when playing.
  /// Unlike ``playPauseTapped`` it never pauses in place, so the sheet's spacebar matches the main
  /// editor rather than leaving the cursor mid-clip. An active audition counts as playing, so Space
  /// stops it too.
  func playStopTapped() async {
    if isPlaying {
      await stopTapped()
    } else {
      transportActionGeneration += 1
      activeAudition = nil
      await startPlaybackFromCursor()
    }
  }

  /// Starts a fresh play from the playhead to the slice's cut-out. Reflects "playing" NOW, not after
  /// `onPlay` returns: the parent's play await stays suspended until playback truly ends
  /// (stop/finish/supersede), so toggling after the await would lag the whole playback. Live ticks
  /// and the parent's stop-publish keep `isPlaying` honest from here (a natural finish is published
  /// back via `updatePlayback`).
  private func startPlaybackFromCursor() async {
    guard let range = playFromCursorRange else { return }
    isPlaying = true
    await onPlay(range)
  }

  func stopTapped() async {
    transportActionGeneration += 1
    let generation = transportActionGeneration
    await onStop()
    guard generation == transportActionGeneration else { return }
    isPlaying = false
    activeAudition = nil
  }

  func seekTapped(toSample sample: Int) async { await onSeek(sample) }

  /// Return jumps the playhead to the clip's beginning — the live cut-in (the draft while editing,
  /// otherwise the committed cut). The original slice edge is never used. Paused or stopped it just
  /// repositions the cursor; while playing it re-anchors so audio restarts from the cut-in (Logic
  /// parity with a lane seek). A no-op when the slice has no playable range.
  func returnToStartTapped() async {
    guard let slice = slicePlaybackRange, slice.lowerBound < slice.upperBound else { return }
    if isPlaying {
      await onPlay(slice.lowerBound..<slice.upperBound)
    } else {
      await seekTapped(toSample: slice.lowerBound)
    }
  }

  /// ⌘Z / ⌘⇧Z inside the sheet — rewinds/replays the shared document (a modal removal is a document
  /// edit). Forwarded from ``SliceEditKeyMonitor`` because the main editor's undo shortcut lives in a
  /// window that is not key while the sheet is up. The parent's own guards decide whether anything
  /// happens, so these are safe no-ops when there is nothing to undo/redo.
  func undoTapped() async {
    guard target.isDraft else {
      await onUndo()
      return
    }
    cancelBoundaryGesture(ignoringRemainingUpdates: true)
    guard let current = fineTune.draftRange, let previous = draftHistory.undo(current: current)
    else { return }
    invalidateDraftPreview()
    fineTune.restoreDraftRange(previous)
  }

  func redoTapped() async {
    guard target.isDraft else {
      await onRedo()
      return
    }
    cancelBoundaryGesture(ignoringRemainingUpdates: true)
    guard let current = fineTune.draftRange, let next = draftHistory.redo(current: current)
    else { return }
    invalidateDraftPreview()
    fineTune.restoreDraftRange(next)
  }

  func boundaryGestureBegan() {
    guard target.isDraft, boundaryGestureStart == nil, !ignoresBoundaryGestureUpdates else {
      return
    }
    boundaryGestureStart = fineTune.draftRange
  }

  func boundaryGestureEnded() {
    ignoresBoundaryGestureUpdates = false
    guard let before = boundaryGestureStart else { return }
    boundaryGestureStart = nil
    if let after = fineTune.draftRange { draftHistory.record(before: before, after: after) }
  }

  func boundaryGestureCancelled() {
    ignoresBoundaryGestureUpdates = false
    cancelBoundaryGesture(ignoringRemainingUpdates: false)
  }

  private func cancelBoundaryGesture(ignoringRemainingUpdates: Bool) {
    guard let before = boundaryGestureStart else { return }
    ignoresBoundaryGestureUpdates = ignoringRemainingUpdates
    boundaryGestureStart = nil
    invalidateDraftPreview()
    fineTune.restoreDraftRange(before)
  }

  private func recordDraftNudge(_ action: () -> Void) {
    boundaryGestureEnded()
    let before = fineTune.draftRange
    action()
    if target.isDraft, let before, let after = fineTune.draftRange {
      draftHistory.record(before: before, after: after)
    }
  }

  private func invalidateDraftPreview() {
    transportActionGeneration += 1
    activeAudition = nil
    isPlaying = false
    onInvalidatePreview()
  }

  // MARK: - Audition
  enum AuditionMode: Equatable {
    case cutIn
    case cutOut
  }

  let auditionPreRollSeconds = 2.0
  let auditionPanelCaption = "To preview:"
  let auditionInButtonTitle = "▶ In"
  let auditionInHotkey = "["
  let auditionOutButtonTitle = "▶ Out"
  let auditionOutHotkey = "]"

  private(set) var activeAudition: AuditionMode?

  /// Samples of pre-roll for the out-cut audition, from the slice's sample rate.
  private var auditionPreRollSamples: Int {
    max(0, Int(auditionPreRollSeconds * Double(fineTune.sampleRate)))
  }

  var isAuditioningIn: Bool { activeAudition == .cutIn }
  var isAuditioningOut: Bool { activeAudition == .cutOut }
  var auditionStatusText: String? {
    switch activeAudition {
    case .cutIn: return "Auditioning in-cut — Space to stop"
    case .cutOut: return "Auditioning out-cut — Space to stop"
    case nil: return nil
    }
  }

  /// In-cut: play the whole draft (falls back to the committed range) through the transport. A
  /// toggle: tapping while it's the active audition stops it; tapping the other edge switches
  /// (supersedes) without an explicit stop.
  func auditionInTapped() async {
    transportActionGeneration += 1
    if activeAudition == .cutIn {
      await stopTapped()
      return
    }
    guard let range = slicePlaybackRange, range.lowerBound < range.upperBound else { return }
    activeAudition = .cutIn
    // Reflect "playing" NOW, not after `onPlay` returns — see `playPauseTapped`'s note: the
    // await stays suspended until playback truly ends.
    isPlaying = true
    await onPlay(range)
  }

  /// Out-cut: play a pre-roll ending exactly at the range's out-point, through the transport. A
  /// toggle, mirroring `auditionInTapped`. The pre-roll is clamped to the range's own start.
  func auditionOutTapped() async {
    transportActionGeneration += 1
    if activeAudition == .cutOut {
      await stopTapped()
      return
    }
    guard let range = slicePlaybackRange else { return }
    let start = max(range.lowerBound, range.upperBound - auditionPreRollSamples)
    guard start < range.upperBound else { return }
    activeAudition = .cutOut
    isPlaying = true
    await onPlay(start..<range.upperBound)
  }

  // MARK: - Transcript word selection
  /// The anchor sample a Shift-extend pivots from — the anchor word's far-from-focus edge, set when a
  /// fresh transcript selection is made (Logic's "anchor stays put, focus moves").
  @ObservationIgnored private var transcriptSelectionAnchorSample: Int?

  /// Words the scoped transcript highlights — those overlapping the live removal selection. Pushed
  /// into `transcript` by the view, mirroring the main editor's `selectedWordIDs`.
  var selectedWordIDs: Set<Word.ID> {
    waveformSelection.map { Set(wordIDs(anyOverlap: $0, words: editPlan.words)) } ?? []
  }

  /// Words struck through in the scoped transcript — those whose whole span a synced removal covers.
  /// Derived from the lane's timeline so a parent removal / undo / redo updates it with no bookkeeping.
  var removedWordIDs: Set<Word.ID> {
    Set(
      editedWaveform.timeline.removals.flatMap {
        wordIDs(fullyContainedIn: $0.removedRange, words: editPlan.words)
      })
  }

  /// Wires the scoped transcript's selection gestures to the removal selection. The scoped transcript
  /// holds only this slice's words (no clips), so a word intent maps straight to its source range —
  /// clamped to the slice window — and becomes the same `waveformSelection` the marquee, Remove
  /// button, and ⌫ already act on. Deletion funnels through the parent's `removeSourceRange`, so the
  /// main transcript, the main audio, and the clip stay in sync. One-directional, like the main editor.
  private func wireTranscriptSelection() {
    transcript.onSelectionIntent = { [weak self] intent in
      guard let self else { return }
      switch intent {
      case .words(let anchor, let focus): selectTranscriptWords(anchorID: anchor, focusID: focus)
      case .word(let id, extending: true): extendTranscriptSelection(toWord: id)
      case .word(let id, extending: false): selectTranscriptWords(anchorID: id, focusID: id)
      case .clear: clearTranscriptSelection()
      }
    }
  }

  private func selectTranscriptWords(anchorID: Word.ID, focusID: Word.ID) {
    guard canMutateDocument, let anchorWord = sourceRange(ofWord: anchorID),
      let focusWord = sourceRange(ofWord: focusID)
    else { return }
    let lower = clampedToWindow(min(anchorWord.lowerBound, focusWord.lowerBound))
    let upper = clampedToWindow(max(anchorWord.upperBound, focusWord.upperBound))
    guard lower < upper else { return }
    selectedSeamID = nil
    transcriptSelectionAnchorSample =
      anchorWord.lowerBound <= focusWord.lowerBound ? anchorWord.lowerBound : anchorWord.upperBound
    waveformSelection = lower..<upper
  }

  private func extendTranscriptSelection(toWord id: Word.ID) {
    guard canMutateDocument, let word = sourceRange(ofWord: id) else { return }
    let anchor = transcriptSelectionAnchorSample ?? waveformSelection?.lowerBound ?? word.lowerBound
    let lower = clampedToWindow(min(anchor, word.lowerBound))
    let upper = clampedToWindow(max(anchor, word.upperBound))
    guard lower < upper else { return }
    selectedSeamID = nil
    waveformSelection = lower..<upper
  }

  private func clearTranscriptSelection() {
    guard canMutateDocument else { return }
    waveformSelection = nil
    transcriptSelectionAnchorSample = nil
  }

  /// The exact source range of one word, or nil if it has no monotonic sample bounds.
  private func sourceRange(ofWord id: Word.ID) -> Range<Int>? {
    guard let word = editPlan.words.first(where: { $0.id == id }),
      let start = word.startSample, let end = word.endSample, start < end
    else { return nil }
    return start..<end
  }

  // MARK: - Marquee removal
  /// A body drag on the collapsed lane starts a Logic-style marquee for an interior removal. Clears
  /// any seam selection so the two never coexist. A no-op until the lane geometry is usable.
  func waveformAreaSelectBegan(atX startX: CGFloat, extending: Bool) {
    guard canMutateDocument else { return }
    guard editedWaveform.hasUsableGeometry else { return }
    selectedSeamID = nil
    marqueeAnchorSample = clampedToWindow(editedWaveform.xToSourceSample(startX))
    marqueeCurrentX = startX
    updateMarqueeSelection()
  }

  func waveformAreaSelectChanged(toX positionX: CGFloat) {
    guard marqueeAnchorSample != nil else { return }
    marqueeCurrentX = positionX
    updateMarqueeSelection()
  }

  /// Release: commits the dragged span as the removal selection (already written live), then ends the
  /// drag. A degenerate drag leaves a 1-sample span (never empty), matching the main editor.
  func waveformAreaSelectEnded(toX positionX: CGFloat) {
    guard marqueeAnchorSample != nil else { return }
    marqueeCurrentX = positionX
    updateMarqueeSelection()
    marqueeAnchorSample = nil
    marqueeCurrentX = nil
  }

  /// Removes the current marquee selection through the parent's merge funnel, then clears it. The
  /// timeline re-sync (parent → `syncTimeline`) collapses the removed span on this lane.
  func removeSelectionTapped() async {
    guard canMutateDocument else { return }
    guard let range = waveformSelection else { return }
    await onRemoveSection(range)
    waveformSelection = nil
  }

  /// ⌫ parity with the main editor's `handleRemoveSectionKey`: a selected seam restores its removal;
  /// otherwise the marquee selection is removed through the parent merge funnel. No-ops when neither
  /// is present (the key monitor consumes ⌫ regardless, like ⌘Z, so it never beeps in the sheet).
  func removeSectionKeyPressed() async {
    guard canMutateDocument else { return }
    if let seamID = selectedSeamID {
      onRestore(seamID)
      return
    }
    await removeSelectionTapped()
  }

  // MARK: - Crossfade stretch
  /// Begins an edge-drag stretch of seam `id` on the sheet's lane: selects it and seeds the draft
  /// with the slice-local rendered length while retaining the stored document length as its stale-
  /// write baseline. A no-op for a seam not on this lane and for a boundary seam, which the lane
  /// offers no handle for (`seamOverlays`). No transport teardown is needed here, unlike the main
  /// editor: the sheet's preview only widens the bowtie overlay and never reflows the lane's timeline.
  func crossfadeStretchBegan(id: TimelineRemoval.ID) {
    guard canMutateDocument else { return }
    guard canEditCrossfade(), let length = currentCrossfadeLength(id),
      let seam = editedWaveform.timeline.seams.first(where: { $0.id == id }),
      let renderedLength = sliceLocalTimeline?.seams.first(where: { $0.id == id })?.crossfadeLength,
      isInteriorSeam(seam)
    else { return }
    selectSeam(id)
    crossfadeStretchInitialRenderedLength = renderedLength
    crossfadeStretchDraft = CrossfadeStretchDraft(
      id: id, length: renderedLength, committedLength: length)
  }

  /// A stretch drag to view-x on the sheet's lane: map x → edited sample and derive the symmetric
  /// length from the dragged edge's distance to the seam center. Geometry wrapper over the tested
  /// core, using this sheet's own lane geometry — the mirror of the main editor's same-named method.
  func crossfadeStretched(_ edge: CrossfadeEdge, toX positionX: CGFloat) {
    guard let draft = crossfadeStretchDraft,
      let localSeam = sliceLocalTimeline?.seams.first(where: { $0.id == draft.id }),
      let seam = laneSeam(for: localSeam)
    else { return }
    let editedSample = editedWaveform.xToEditedSample(positionX)
    // Symmetric length from the dragged edge and the exact doubled center, so odd lengths are
    // reachable (a truncated center forces even proposals) — mirrors the main editor.
    let doubled = seam.editedCrossfadeDoubledCenter
    let length =
      edge == .leading
      ? doubled - 2 * editedSample
      : 2 * editedSample - doubled
    crossfadeStretched(toLength: length)
  }

  /// Geometry-free core: clamp the proposed length to `[0, slice-local handle]` — the ceiling THIS
  /// slice can play (``sliceLocalMaxCrossfade``), which for an interior seam is <= the global handle
  /// the main editor clamps to. Unlike PR #68's cross-surface parity, the sheet must never author a
  /// fade longer than the slice actually plays, so when audio outside the slice would widen the
  /// global handle the sheet clamps shorter than the main editor. No document mutation; the commit is
  /// on release.
  func crossfadeStretched(toLength proposed: Int) {
    guard var draft = crossfadeStretchDraft else { return }
    let maxLength = sliceLocalMaxCrossfade(forSeamID: draft.id)
    draft.length = max(0, min(proposed, maxLength))
    crossfadeStretchDraft = draft
  }

  /// Release: commit the drafted length through the parent's `updateCrossfade` funnel (one undo
  /// step) and clear the draft. A drag that netted no visible change against its initial slice-local
  /// length pushes no entry. Re-validates what `crossfadeStretchBegan` checked, because
  /// both can change while the mouse is down without a fan reaching `syncTimeline`: the stored
  /// length (an undo restoring a latent, clamped-away length leaves the rendered timeline equal, so
  /// the parent never fans) and the seam's interior status (the key monitor stays live during a
  /// drag, so a nudge can move the cut onto the seam). Either way the drag's intent is stale — it
  /// would overwrite a restored value, or author a fade this slice plays as a hard cut — so it
  /// commits nothing. The length is re-clamped to the seam's CURRENT handle too: a re-fan that
  /// restored a neighbouring removal shrinks the handle without touching this removal's stored
  /// length, so the draft survives holding a length the lane can no longer show. A drag that never
  /// moved remains at its initial rendered length and commits nothing, preserving any longer latent
  /// fade stored in the document.
  func crossfadeStretchEnded() {
    guard canMutateDocument else { return }
    guard let draft = crossfadeStretchDraft else { return }
    let initialRenderedLength = crossfadeStretchInitialRenderedLength
    crossfadeStretchDraft = nil
    crossfadeStretchInitialRenderedLength = nil
    guard let initialRenderedLength, draft.length != initialRenderedLength,
      let current = currentCrossfadeLength(draft.id), current == draft.committedLength,
      let seam = editedWaveform.timeline.seams.first(where: { $0.id == draft.id }),
      isInteriorSeam(seam)
    else { return }
    let length = min(draft.length, sliceLocalMaxCrossfade(forSeamID: draft.id))
    guard length != current else { return }
    onStretchCrossfade(draft.id, length)
  }

  /// Aborts an in-flight stretch without committing — for a drag torn down before mouse-up (sheet
  /// dismissed, lane removed), when `crossfadeStretchEnded` can never run. The sheet's drag mutates
  /// only the draft (its preview is derived from it in `seamOverlays`; the lane's timeline and
  /// viewport are untouched, unlike the main editor's live reflow), so dropping the draft restores
  /// the committed bowtie and handles. A no-op if no drag is live.
  func crossfadeStretchCancelled() {
    guard crossfadeStretchDraft != nil else { return }
    crossfadeStretchDraft = nil
    crossfadeStretchInitialRenderedLength = nil
  }

  // MARK: - Crossfade cut-point drag
  /// Begins a ⌥-drag of seam `id`'s `edge` on the sheet's lane: selects it and seeds the draft with
  /// the committed range, the seam's STORED fade length pinned — the document's `lengthSamples`, NOT
  /// the clamped effective length, so moving a cut NEVER rewrites the stored duration. When this slice
  /// (or global geometry) can render only a shorter fade the stored length is preserved and the slice
  /// just draws/plays it shorter; pull the cut back out and the full fade returns (non-destructive) —
  /// and the viewport geometry + press position frozen for stable drag math against a live-reflowing
  /// lane. A no-op when the parent refuses crossfade edits (mid-export), for a seam not on this lane, or
  /// for a boundary seam (one crossing/touching a slice edge) — it plays as a hard cut here, so moving
  /// its cut would author a fade this slice never plays; the lane offers it no ⌥ grab zone either. No
  /// transport teardown: the sheet's transport is owned by the parent, which stops it on the change.
  func crossfadeCutPointDragBegan(
    id: TimelineRemoval.ID, edge: RemovalBoundary, atX posX: CGFloat
  ) {
    guard canMutateDocument else { return }
    guard canEditCrossfade(), let storedLength = currentCrossfadeLength(id),
      let seam = editedWaveform.timeline.seams.first(where: { $0.id == id }),
      isInteriorSeam(seam),
      let removal = editedWaveform.timeline.removals.first(where: { $0.id == id })
    else { return }
    selectSeam(id)
    let dragStartEdited = WaveformViewport.xToSample(
      posX, visibleStartSample: editedWaveform.visibleStartSample,
      samplesPerPixel: editedWaveform.samplesPerPixel)
    crossfadeCutPointDraft = CrossfadeCutPointDraft(
      id: id, edge: edge, committedRange: removal.removedRange, draftedRange: removal.removedRange,
      frozenCrossfadeLength: storedLength,
      frozenCommittedTimeline: editedWaveform.timeline,
      dragStartEditedSample: dragStartEdited,
      frozenVisibleStart: editedWaveform.visibleStartSample,
      frozenSamplesPerPixel: editedWaveform.samplesPerPixel)
  }

  /// A cut-point drag to view-x: map x → edited sample against the FROZEN viewport, derive the source
  /// delta, apply it to the moving bound (`committed − delta`), clamp to the slice, hold the draft, and
  /// reflow the preview timeline live. The viewport re-anchors by the seam's edited-position delta
  /// exactly like the main editor so the CROSSFADE stays pinned to its start-of-drag screen position
  /// and the moving side slides under it (a right-cut leaves the seam put → no shift → only the right
  /// slides). When the slice fully fits the pinned lane the shift naturally clamps away, so the seam
  /// simply reflows in place. The document stays untouched — commit is on release.
  func crossfadeCutPointDragged(toX posX: CGFloat) {
    guard var draft = crossfadeCutPointDraft else { return }
    let editedNow = WaveformViewport.xToSample(
      posX, visibleStartSample: draft.frozenVisibleStart,
      samplesPerPixel: draft.frozenSamplesPerPixel)
    let delta = editedNow - draft.dragStartEditedSample
    // Build a CONSTRUCTIBLE range: a `Range` literal traps when lower exceeds upper, and a large drag
    // can push the moving cut past the fixed one. Cap the moving bound against the opposite bound here;
    // `sliceLocalClampedRemovalRange` then applies the neighbor/slice clamp and the non-empty guarantee.
    let proposed: Range<Int>
    switch draft.edge {
    case .lower:
      let proposedCL = min(draft.committedRange.lowerBound - delta, draft.committedRange.upperBound)
      proposed = proposedCL..<draft.committedRange.upperBound
    case .upper:
      let proposedCR = max(draft.committedRange.upperBound - delta, draft.committedRange.lowerBound)
      proposed = draft.committedRange.lowerBound..<proposedCR
    }
    let clamped = sliceLocalClampedRemovalRange(
      id: draft.id, edge: draft.edge, proposed: proposed)
    draft.draftedRange = clamped
    crossfadeCutPointDraft = draft
    let preview = previewCutPointTimeline(
      id: draft.id, removedRange: clamped, length: draft.frozenCrossfadeLength)
    // Anchor on the seam's actual edited position (`editedCrossfadeStart`) in the preview vs. the
    // frozen committed timeline so the crossfade holds its screen position even when the effective
    // fade shrinks near the slice edge — ΔcL alone would drift there. Reduces to ΔcL at full length; a
    // right-cut leaves the seam put → shift 0. A missing seam falls back to no shift.
    let previewSeamStart =
      preview.seams.first(where: { $0.id == draft.id })?.editedCrossfadeStart
    let frozenSeamStart =
      draft.frozenCommittedTimeline.seams.first(where: { $0.id == draft.id })?.editedCrossfadeStart
    let crossfadeShift = (previewSeamStart ?? 0) - (frozenSeamStart ?? 0)
    editedWaveform.previewCutPoint(
      timeline: preview, visibleStart: draft.frozenVisibleStart + crossfadeShift)
  }

  /// Release: rewind the adapter to the pre-drag committed timeline (so the parent's fan produces a
  /// real diff instead of short-circuiting on equality) and re-pin, then commit the drafted range once
  /// through the parent. A drag that netted no range change pushes no entry. A no-op if no drag is live
  /// or the removal vanished mid-drag.
  func crossfadeCutPointDragEnded() {
    guard canMutateDocument else { return }
    guard let draft = crossfadeCutPointDraft else { return }
    crossfadeCutPointDraft = nil
    editedWaveform.timeline = draft.frozenCommittedTimeline
    editedWaveform.setNavigableEditedRange(pinnedEditedRange)
    guard let removal = editedWaveform.timeline.removals.first(where: { $0.id == draft.id }),
      draft.draftedRange != removal.removedRange
    else { return }
    onMoveCutPoint(draft.id, draft.draftedRange)
  }

  /// Aborts an in-flight cut-point drag without committing: drops the draft and restores the committed
  /// timeline / pin / viewport the live preview replaced. For a drag torn down before mouse-up (sheet
  /// dismissed, lane removed), the only other exit `crossfadeCutPointDragEnded` needs mouse-up to run.
  /// A no-op if no drag is live.
  func crossfadeCutPointDragCancelled() {
    guard let draft = crossfadeCutPointDraft else { return }
    crossfadeCutPointDraft = nil
    editedWaveform.timeline = draft.frozenCommittedTimeline
    editedWaveform.setNavigableEditedRange(pinnedEditedRange)
    editedWaveform.visibleStartSample = draft.frozenVisibleStart
    editedWaveform.samplesPerPixel = draft.frozenSamplesPerPixel
  }

  /// Clamps a proposed cut-point `removedRange` to what THIS slice allows: the parent's global
  /// neighbor-aware clamp (via `clampCutPointRange`) intersected with the slice window, so a moved cut
  /// never crosses the slice boundary or the other cut. It does NOT reserve fade room at the slice
  /// edge — the fade renders as long as it fits and its stored length is preserved, so the cut may be
  /// dragged right up to the slice edge (where the fade renders as a hard cut) instead of snapping
  /// away. Only the moving edge changes; the other is held.
  private func sliceLocalClampedRemovalRange(
    id: TimelineRemoval.ID, edge: RemovalBoundary, proposed: Range<Int>
  ) -> Range<Int> {
    let global = clampCutPointRange(id, proposed)
    guard let slice = slicePlaybackRange else { return global }
    let cL = global.lowerBound
    let cR = global.upperBound
    switch edge {
    case .lower:
      let newCL = min(max(global.lowerBound, slice.lowerBound), cR - 1)
      return newCL..<cR
    case .upper:
      let newCR = max(min(global.upperBound, slice.upperBound), cL + 1)
      return cL..<newCR
    }
  }

  /// The GLOBAL edited timeline as it will render with removal `id`'s range set to `removedRange` and
  /// its fade pinned to `length` — built the same way the parent's commit builds it, so releasing
  /// repositions nothing. Falls back to the current timeline for an unknown id.
  private func previewCutPointTimeline(
    id: TimelineRemoval.ID, removedRange: Range<Int>, length: Int
  ) -> EditedTimeline {
    // Build from the parent's STORED removals so the preview re-clamps from full stored fades exactly
    // as the commit does; the lane's own removals carry EFFECTIVE (already-clamped) fades, so a crowded
    // neighbor would render stuck-short here and jump on release. Fall back to the lane's removals when
    // the parent is unwired (isolated tests without an injected stored set).
    let stored = currentStoredRemovals()
    var removals = stored.isEmpty ? editedWaveform.timeline.removals : stored
    guard let index = removals.firstIndex(where: { $0.id == id }) else {
      return editedWaveform.timeline
    }
    removals[index].removedRange = removedRange
    removals[index].crossfade.lengthSamples = length
    return EditedTimeline(
      sourceDurationSamples: editedWaveform.timeline.sourceDurationSamples, removals: removals)
  }

  private func updateMarqueeSelection() {
    guard let anchor = marqueeAnchorSample, let currentX = marqueeCurrentX else { return }
    let clampedX = min(max(0, currentX), editedWaveform.viewportWidth)
    let focus = clampedToWindow(editedWaveform.xToSourceSample(clampedX))
    let lower = min(anchor, focus)
    // Both endpoints can land on the slice's exclusive upper bound (clampedToWindow is inclusive
    // there); the 1-sample minimum must not push the span one sample past the slice, so clamp the
    // upper into the window and expand the lower leftward when there is no room to the right.
    let upper = min(max(max(anchor, focus), lower + 1), overviewWindow.upperBound)
    waveformSelection = min(lower, upper - 1)..<upper
  }

  /// A ⌥-click on the outside audio flanking a bowtie (the cut-point layer's tap path, no drag)
  /// selects that seam — the same selection the context menu and a completed cut-point drag set. The
  /// other click-to-select path is ``waveformBodyClicked(atX:extending:)`` on the bowtie itself.
  func cutPointSeamSelected(_ id: TimelineRemoval.ID) { selectSeam(id) }

  /// A plain body click on a bowtie selects that crossfade (Logic selects a crossfade on click, exactly
  /// as the main editor's ``EditorModel/waveformClicked(atX:extending:)`` does); any other click seeks
  /// the playhead. Shift is a selection-extend gesture, so it skips the seam test and seeks. This is the
  /// sheet's click-the-X-to-select path — ``cutPointSeamSelected`` only fires from the ⌥-click flank
  /// beside the bowtie, so clicking the crossfade itself needs this to select rather than only seek.
  func waveformBodyClicked(atX positionX: CGFloat, extending: Bool) async {
    if !extending, let id = seamID(atX: positionX) {
      selectSeam(id)
      return
    }
    await waveformSeeked(toX: positionX)
  }

  private func selectSeam(_ id: TimelineRemoval.ID) {
    guard editedWaveform.timeline.seams.contains(where: { $0.id == id }) else { return }
    waveformSelection = nil
    selectedSeamID = id
  }

  private func clampedToWindow(_ sample: Int) -> Int {
    min(max(sample, overviewWindow.lowerBound), overviewWindow.upperBound)
  }

  /// A ruler click/drag or a body click on the lane moves the playhead. Maps the view-x to a plan
  /// sample via the lane's own geometry, clamped into the slice. While playing it re-anchors — audio
  /// keeps going from the click to the cut-out (Logic parity); paused or stopped it just repositions
  /// the cursor so the next Play starts there. No-ops until the lane geometry is usable (mirrors the
  /// main editor's guard against storing a garbage cursor mid-decode).
  func waveformSeeked(toX positionX: CGFloat) async {
    transportActionGeneration += 1
    activeAudition = nil
    guard editedWaveform.hasUsableGeometry else { return }
    let sample = min(
      max(editedWaveform.xToSourceSample(positionX), overviewWindow.lowerBound),
      overviewWindow.upperBound)
    guard isPlaying, let slice = slicePlaybackRange else {
      await seekTapped(toSample: sample)  // paused or stopped: just reposition the cursor
      return
    }
    if sample < slice.upperBound {
      await onPlay(max(sample, slice.lowerBound)..<slice.upperBound)  // re-anchor, keep playing
    } else {
      // Clicked at/after the cut-out while playing — nothing left to play. Stop (so the next
      // position tick can't snap the playhead back), then park the cursor at the click. `onStop`
      // suspends, so guard the generation like `stopTapped` does: a newer action (an audition, a
      // fresh seek) started mid-stop must not have its cursor yanked by this stale park.
      let generation = transportActionGeneration
      await onStop()
      guard generation == transportActionGeneration else { return }
      await seekTapped(toSample: sample)
    }
  }

  /// A continuous ruler drag repositions the cursor ONLY — it never re-anchors playback, so
  /// scrubbing the ruler doesn't restart the transport once per pointer move (that would be one
  /// exclusive `play` per event). Re-anchoring stays on the discrete body click (``waveformSeeked``).
  func waveformDragged(toX positionX: CGFloat) async {
    guard editedWaveform.hasUsableGeometry else { return }
    let sample = min(
      max(editedWaveform.xToSourceSample(positionX), overviewWindow.lowerBound),
      overviewWindow.upperBound)
    await seekTapped(toSample: sample)
  }

  func zoomInTapped() { editedWaveform.zoomInTapped() }
  func zoomOutTapped() { editedWaveform.zoomOutTapped() }
  /// Logic's `Z`: fit the whole slice (the lane's pinned extent) on the first press, restore the
  /// prior zoom on the next. Uses the committed slice window, not the live draft, so it always
  /// frames exactly what the pinned lane can show.
  func zoomFitTapped() { editedWaveform.zoomFitToggled(sourceSelection: overviewWindow) }

  /// Seeds (on open) or re-seeds (on every parent removal / undo / redo) the collapsed lane's
  /// timeline from the parent's GLOBAL ``EditedTimeline``, then re-pins to the slice's — possibly
  /// changed — edited extent. Coordinates stay GLOBAL, matching the adopted whole-file source
  /// pyramid, so no offset math is needed. The cursor is source-anchored (``laneCursorSample`` maps
  /// live through the new timeline), so nothing else needs remapping.
  func syncTimeline(_ timeline: EditedTimeline) {
    // A parent removal / undo / redo can retire the seam this sheet had selected or is stretching.
    // Reconcile both before the lane reads them, mirroring the parent's own funnel, so a stale id
    // can't restore a phantom selection (``removeSectionKeyPressed``) or preview a gone seam.
    if let selectedSeamID, !timeline.seams.contains(where: { $0.id == selectedSeamID }) {
      self.selectedSeamID = nil
    }
    // Drop a live stretch draft whose baseline no longer matches the document — its seam is gone, or
    // the removal's STORED crossfade length changed underneath it (an undo/redo reverted the very seam
    // being dragged). Compared against the stored length the draft was seeded from, not the lane's
    // clamped `crossfadeLength`: a fade stored longer than this seam can render must survive an
    // unrelated re-fan, or the drag would vanish under the pointer. Mirrors the main editor's
    // `syncEditedTimeline` guard.
    if let draft = crossfadeStretchDraft,
      !timeline.seams.contains(where: { $0.id == draft.id })
        || currentCrossfadeLength(draft.id) != draft.committedLength
    {
      crossfadeStretchDraft = nil
      crossfadeStretchInitialRenderedLength = nil
    }
    // Drop a live cut-point drag draft whose committed baseline no longer matches — the parent
    // committed a change (this seam or a neighbor, an undo/redo, a nudge, a restore) underneath the
    // drag, so the drafted range was clamped against a stale layout and must not commit. Whole-timeline
    // compare catches neighbor-only reflows, mirroring the main editor's `syncEditedTimeline`. Undo the
    // preview's viewport compensation first so the re-pin below re-clamps from the pre-drag scroll.
    if let draft = crossfadeCutPointDraft, timeline != draft.frozenCommittedTimeline {
      editedWaveform.visibleStartSample = draft.frozenVisibleStart
      crossfadeCutPointDraft = nil
    }
    editedWaveform.timeline = timeline
    editedWaveform.setNavigableEditedRange(pinnedEditedRange)
  }

  /// Called by EditorModel's position loop while `.sliceEdit` is the transport context.
  func updatePlayback(sample: Int?, isPlaying: Bool) {
    playheadSample = sample
    self.isPlaying = isPlaying
    if !isPlaying { activeAudition = nil }
    transcript.playheadChanged(sample: sample, isPlaying: isPlaying)
    transcript.currentWordChanged(toSample: sample)
  }
}
