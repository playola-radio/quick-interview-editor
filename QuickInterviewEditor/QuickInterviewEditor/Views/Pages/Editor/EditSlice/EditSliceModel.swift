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
  func cutInNudged(byMs ms: Double) { fineTune.nudgeCutIn(byMs: ms) }
  func cutOutNudged(byMs ms: Double) { fineTune.nudgeCutOut(byMs: ms) }

  func playPauseTapped() async {
    if isPlaying {
      await onPause()
      isPlaying = false
    } else if let range = fineTune.draftRange ?? fineTune.committedRange {
      await onPlay(range)
      isPlaying = true
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
