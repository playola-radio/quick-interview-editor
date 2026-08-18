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
  var columnsProvider: (Range<Int>, CGFloat) -> [WaveformColumn] = { _, _ in [] }
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

  func overviewColumns(pixelWidth: CGFloat) -> [WaveformColumn] {
    columnsProvider(overviewWindow, pixelWidth)
  }
  func cutInColumns() -> [WaveformColumn] {
    fineTune.cutInWindow.map { columnsProvider($0, fineTune.insetWidthPixels) } ?? []
  }
  func cutOutColumns() -> [WaveformColumn] {
    fineTune.cutOutWindow.map { columnsProvider($0, fineTune.insetWidthPixels) } ?? []
  }

  // MARK: - Overview geometry
  // The model owns every sample↔position decision; the overview view only multiplies these
  // 0...1 fractions by its pixel width. Keeping the math here (not in the view) matches the
  // "views hold zero logic" rule and lets these be tested without a rendered geometry.

  /// The playhead's position as a fraction (0...1) of the overview window, or `nil` when the
  /// cursor sits outside the slice. Inclusive of the upper bound: the transport rests the cursor
  /// at `range.upperBound` on a natural finish (and a right-edge seek resolves there too), so a
  /// half-open check would wrongly hide the line exactly at the slice's end.
  var overviewPlayheadFraction: Double? {
    guard let sample = playheadSample,
      (overviewWindow.lowerBound...overviewWindow.upperBound).contains(sample)
    else { return nil }
    return overviewFraction(ofSample: sample)
  }

  /// The live draft Cut-in boundary as a fraction (0...1) of the overview window — recomputed on
  /// every drag/nudge so the overview shows where the cut currently sits.
  var overviewCutInFraction: Double? {
    fineTune.draftRange.map { overviewFraction(ofSample: $0.lowerBound) }
  }
  /// The live draft Cut-out boundary as a fraction (0...1) of the overview window.
  var overviewCutOutFraction: Double? {
    fineTune.draftRange.map { overviewFraction(ofSample: $0.upperBound) }
  }

  /// Maps a horizontal fraction (0...1) of the overview back to a sample, for tap-to-seek.
  func overviewSeekSample(atFraction fraction: Double) -> Int {
    let clamped = min(max(fraction, 0), 1)
    return overviewWindow.lowerBound + Int(clamped * Double(overviewWindow.count))
  }

  private func overviewFraction(ofSample sample: Int) -> Double {
    guard overviewWindow.count > 0 else { return 0 }
    let raw = Double(sample - overviewWindow.lowerBound) / Double(overviewWindow.count)
    return min(1, max(0, raw))
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
      guard let range = fineTune.draftRange ?? fineTune.committedRange else { return }
      // Reflect "playing" NOW, not after `onPlay` returns. The parent's play await stays suspended
      // until playback truly ends (stop/finish/supersede) while the resume path returns
      // immediately, so toggling after the await would either lag the whole playback or wrongly
      // clear Play the instant a resume returns. Live ticks and the parent's stop-publish keep
      // `isPlaying` honest from here (a natural finish is published back via `updatePlayback`).
      isPlaying = true
      await onPlay(range)
    }
  }

  func stopTapped() async {
    await onStop()
    isPlaying = false
  }

  func seekTapped(toSample sample: Int) async { await onSeek(sample) }

  /// Called by EditorModel's position loop while `.sliceEdit` is the transport context.
  func updatePlayback(sample: Int?, isPlaying: Bool) {
    playheadSample = sample
    self.isPlaying = isPlaying
    transcript.playheadChanged(sample: sample, isPlaying: isPlaying)
    transcript.currentWordChanged(toSample: sample)
  }
}
