import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class EditSliceModel: ViewModel, Identifiable {

  // MARK: - Initialization
  let sliceID: Slice.ID
  let fineTune: FineTuneModel
  let title: String
  let overviewWindow: Range<Int>
  let transcript: TranscriptPageModel
  /// The sheet's OWN source-pure ``WaveformModel`` — the parent's already-decoded pyramid, adopted
  /// so nothing is re-decoded. It is NOT the parent's instance (that one is bound to the main
  /// editor's viewport). It stays source-pure: the fine-tune insets and the amplitude-zoom button
  /// read it directly. The navigable lane renders on ``editedWaveform`` instead.
  let waveform: WaveformModel
  /// The collapsed (EDITED) lane the sheet renders and hit-tests, pinned to this slice's edited
  /// extent so you cannot scroll or zoom past its boundaries. It shares ``waveform``'s source
  /// pyramid and carries the parent's ``EditedTimeline`` (seeded and kept in sync by `EditorModel`;
  /// identity here until the parent supplies real removals), so a removal inside the slice collapses
  /// on this lane exactly as it does on the main timeline.
  let editedWaveform: EditedWaveformAdapter

  init(slice: Slice, editPlan: EditPlan) {
    sliceID = slice.id
    title = slice.name
    fineTune = FineTuneModel(
      sampleRate: editPlan.source.sampleRate,
      durationSamples: editPlan.source.durationSamples,
      silences: editPlan.silences)
    overviewWindow = slice.startSample..<slice.endSample
    let sliceWordIDSet = Set(slice.wordIDs)
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
    fineTune.begin(target: .slice(slice.id), range: slice.startSample..<slice.endSample)
    editedWaveform.setNavigableEditedRange(pinnedEditedRange)
  }

  // MARK: - Properties
  var onCommit: (Range<Int>) -> Void = { _ in }
  var onDismiss: () -> Void = {}
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

  // MARK: - Display Text
  let saveLabel = "Save cut"
  let cancelLabel = "Cancel"
  let stopLabel = "Stop"
  let removeSectionLabel = "Remove Section"
  let restoreRemovedAudioLabel = "Restore Removed Audio"

  // MARK: - View Helpers
  var canSave: Bool { fineTune.hasUnsavedChange }
  var playPauseLabel: String { isPlaying ? "Pause" : "Play" }
  var playButtonSystemImage: String { isPlaying ? "pause.fill" : "play.fill" }

  /// What the lane highlights: the live marquee removal selection when the user is picking an interior
  /// span to cut, otherwise the draft kept range (so the kept region reads clearly against the
  /// discarded head/tail). A SOURCE range — the lane maps it through the timeline via
  /// ``EditedWaveformAdapter/laneSpan(forSource:)``.
  var waveformHighlightRange: Range<Int>? { waveformSelection ?? fineTune.draftRange }

  /// Whether the Remove control acts on anything — a marquee selection exists.
  var canRemoveSelection: Bool { waveformSelection != nil }

  // MARK: - Seam overlays
  /// The bowtie spans the lane draws at each seam, mapped to the collapsed lane's view coordinates —
  /// identical derivation to the main editor's `seamOverlays`, reading the shared timeline the parent
  /// keeps synced. The view only binds; it never derives geometry.
  var seamOverlays: [SeamOverlay] {
    editedWaveform.timeline.seams.compactMap { seam in
      guard let span = editedWaveform.spanForSeam(seam) else { return nil }
      return SeamOverlay(id: seam.id, span: span, isSelected: seam.id == selectedSeamID)
    }
  }

  private static let seamHitTolerance: CGFloat = 4

  /// The removal id whose bowtie the view-x lands on, or nil — same hit-test as the main editor
  /// (nearest bowtie center wins when widened targets overlap).
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

  /// The right-click menu for a lane position: Restore when the x hits a seam (also selects it), else
  /// Remove Section when a marquee selection exists, else empty. Mirrors the main editor's
  /// `seamContextMenuItems` and adds the modal's Remove entry.
  func waveformContextMenuItems(atX positionX: CGFloat) -> [WaveformMenuItem] {
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
    guard let draft = fineTune.draftRange, fineTune.hasUnsavedChange else {
      onDismiss()
      return
    }
    onCommit(draft)
    onDismiss()
  }

  func cancelTapped() {
    fineTune.resetDraft()
    onDismiss()
  }

  func cutInDragged(toInsetX positionX: CGFloat) { fineTune.dragCutIn(toInsetX: positionX) }
  func cutOutDragged(toInsetX positionX: CGFloat) { fineTune.dragCutOut(toInsetX: positionX) }
  // The nudge direction and step live on the model, so the view forwards a named action rather
  // than deciding the sign/magnitude of the delta itself.
  func cutInNudgedBack() { fineTune.nudgeCutIn(byMs: -fineTune.nudgeMs) }
  func cutInNudgedForward() { fineTune.nudgeCutIn(byMs: fineTune.nudgeMs) }
  func cutOutNudgedBack() { fineTune.nudgeCutOut(byMs: -fineTune.nudgeMs) }
  func cutOutNudgedForward() { fineTune.nudgeCutOut(byMs: fineTune.nudgeMs) }

  func playPauseTapped() async {
    if isPlaying {
      await onPause()
      isPlaying = false
    } else {
      guard let range = playFromCursorRange else { return }
      // Reflect "playing" NOW, not after `onPlay` returns: the parent's play await stays suspended
      // until playback truly ends (stop/finish/supersede), so toggling after the await would lag the
      // whole playback. Live ticks and the parent's stop-publish keep `isPlaying` honest from here (a
      // natural finish is published back via `updatePlayback`).
      isPlaying = true
      await onPlay(range)
    }
  }

  func stopTapped() async {
    await onStop()
    isPlaying = false
  }

  func seekTapped(toSample sample: Int) async { await onSeek(sample) }

  /// ⌘Z / ⌘⇧Z inside the sheet — rewinds/replays the shared document (a modal removal is a document
  /// edit). Forwarded from ``SliceEditKeyMonitor`` because the main editor's undo shortcut lives in a
  /// window that is not key while the sheet is up. The parent's own guards decide whether anything
  /// happens, so these are safe no-ops when there is nothing to undo/redo.
  func undoTapped() async { await onUndo() }
  func redoTapped() async { await onRedo() }

  // MARK: - Marquee removal
  /// A body drag on the collapsed lane starts a Logic-style marquee for an interior removal. Clears
  /// any seam selection so the two never coexist. A no-op until the lane geometry is usable.
  func waveformAreaSelectBegan(atX startX: CGFloat, extending: Bool) {
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
    guard let range = waveformSelection else { return }
    await onRemoveSection(range)
    waveformSelection = nil
  }

  /// ⌫ parity with the main editor's `handleRemoveSectionKey`: a selected seam restores its removal;
  /// otherwise the marquee selection is removed through the parent merge funnel. No-ops when neither
  /// is present (the key monitor consumes ⌫ regardless, like ⌘Z, so it never beeps in the sheet).
  func removeSectionKeyPressed() async {
    if let seamID = selectedSeamID {
      onRestore(seamID)
      return
    }
    await removeSelectionTapped()
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
      // position tick can't snap the playhead back), then park the cursor at the click.
      await onStop()
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
    editedWaveform.timeline = timeline
    editedWaveform.setNavigableEditedRange(pinnedEditedRange)
  }

  /// Called by EditorModel's position loop while `.sliceEdit` is the transport context.
  func updatePlayback(sample: Int?, isPlaying: Bool) {
    playheadSample = sample
    self.isPlaying = isPlaying
    transcript.playheadChanged(sample: sample, isPlaying: isPlaying)
    transcript.currentWordChanged(toSample: sample)
  }
}
