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
  /// The sheet's OWN waveform lane model — the same ``WaveformModel`` the main editor drives, so the
  /// sheet gets identical zoom/scroll/ruler behavior. It is NOT the parent's instance (that one is
  /// bound to the main editor's viewport); `EditorModel` seeds this one from the parent's already
  /// decoded pyramid via ``WaveformModel/adopt(waveform:totalSamples:sampleRate:focusWindow:)`` so
  /// nothing is re-decoded. Boundary editing stays on the fine-tune insets; the lane is navigation.
  let waveform = WaveformModel()

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
    super.init()
    fineTune.begin(target: .slice(slice.id), range: slice.startSample..<slice.endSample)
  }

  // MARK: - Properties
  var onCommit: (Range<Int>) -> Void = { _ in }
  var onDismiss: () -> Void = {}
  var onPlay: (Range<Int>) async -> Void = { _ in }
  var onPause: () async -> Void = {}
  var onStop: () async -> Void = {}
  var onSeek: (Int) async -> Void = { _ in }
  var isPlaying = false
  var playheadSample: Int?

  // MARK: - Display Text
  let saveLabel = "Save cut"
  let cancelLabel = "Cancel"
  let stopLabel = "Stop"

  // MARK: - View Helpers
  var canSave: Bool { fineTune.hasUnsavedChange }
  var playPauseLabel: String { isPlaying ? "Pause" : "Play" }
  var playButtonSystemImage: String { isPlaying ? "pause.fill" : "play.fill" }

  /// The live draft kept range, drawn as the lane's highlight band so the kept region reads clearly
  /// against the discarded head/tail. Recomputed on every drag/nudge.
  var waveformHighlightRange: Range<Int>? { fineTune.draftRange }

  var canZoomIn: Bool { waveform.canZoomIn }
  var canZoomOut: Bool { waveform.canZoomOut }
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

  /// A ruler click/drag or a body click on the lane moves the playhead. Maps the view-x to a plan
  /// sample via the lane's own geometry, clamped into the slice. While playing it re-anchors — audio
  /// keeps going from the click to the cut-out (Logic parity); paused or stopped it just repositions
  /// the cursor so the next Play starts there. No-ops until the lane geometry is usable (mirrors the
  /// main editor's guard against storing a garbage cursor mid-decode).
  func waveformSeeked(toX positionX: CGFloat) async {
    guard waveform.hasUsableGeometry else { return }
    let sample = min(
      max(waveform.xToSample(positionX), overviewWindow.lowerBound), overviewWindow.upperBound)
    if isPlaying, let slice = slicePlaybackRange, sample < slice.upperBound {
      await onPlay(max(sample, slice.lowerBound)..<slice.upperBound)
    } else {
      await seekTapped(toSample: sample)
    }
  }

  func zoomInTapped() { waveform.zoomInTapped() }
  func zoomOutTapped() { waveform.zoomOutTapped() }
  /// Logic's `Z`: fit the whole slice (the lane's pinned extent) on the first press, restore the
  /// prior zoom on the next. Uses the committed slice window, not the live draft, so it always
  /// frames exactly what the pinned lane can show.
  func zoomFitTapped() { waveform.zoomFitToggled(selection: overviewWindow) }

  /// Called by EditorModel's position loop while `.sliceEdit` is the transport context.
  func updatePlayback(sample: Int?, isPlaying: Bool) {
    playheadSample = sample
    self.isPlaying = isPlaying
    transcript.playheadChanged(sample: sample, isPlaying: isPlaying)
    transcript.currentWordChanged(toSample: sample)
  }
}
