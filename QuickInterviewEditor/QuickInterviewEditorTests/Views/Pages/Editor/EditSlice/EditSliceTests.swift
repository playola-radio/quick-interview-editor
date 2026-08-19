import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditSliceTests {
  private func makeModel() -> (EditSliceModel, Slice) {
    let plan = Fixtures.editPlan()
    let slice = Slice(
      id: UUID(), name: "Slice 1",
      startSample: 10_000, endSample: 40_000,
      wordIDs: [], snippet: "", warnings: [])
    return (EditSliceModel(slice: slice, editPlan: plan), slice)
  }

  @Test func openingBeginsSessionOnCommittedRange() {
    let (model, slice) = makeModel()
    expectNoDifference(model.fineTune.committedRange, slice.startSample..<slice.endSample)
    expectNoDifference(model.fineTune.draftRange, slice.startSample..<slice.endSample)
    #expect(model.canSave == false)  // no change yet
  }

  @Test func draggingMutatesDraftOnly_savingCommitsOnce() {
    let (model, _) = makeModel()
    var committed: [Range<Int>] = []
    model.onCommit = { committed.append($0) }

    model.fineTune.nudgeCutIn(byMs: 10)  // move the draft
    #expect(model.canSave == true)
    let draft = model.fineTune.draftRange

    model.saveTapped()

    expectNoDifference(committed, [draft].compactMap { $0 })
  }

  @Test func cancelDoesNotCommit_andDismisses() {
    let (model, _) = makeModel()
    var committed = 0
    var dismissed = 0
    model.onCommit = { _ in committed += 1 }
    model.onDismiss = { dismissed += 1 }

    model.fineTune.nudgeCutOut(byMs: -10)
    model.cancelTapped()

    #expect(committed == 0)
    #expect(dismissed == 1)
  }

  @Test func scopedTranscriptContainsExactlyTheSliceWords() {
    let plan = Fixtures.editPlan()
    let sliceWordIDs = Array(plan.words.prefix(3).map(\.id))
    let slice = Slice(
      id: UUID(), name: "S", startSample: 0, endSample: 20_000,
      wordIDs: sliceWordIDs, snippet: "", warnings: [])
    let model = EditSliceModel(slice: slice, editPlan: plan)

    expectNoDifference(
      model.transcript.document.wordRanges.map(\.wordID), sliceWordIDs)
  }

  @Test func overviewWindowIsTheCommittedSliceRange() {
    let plan = Fixtures.editPlan()
    let slice = Slice(
      id: UUID(), name: "S", startSample: 5_000, endSample: 25_000,
      wordIDs: [], snippet: "", warnings: [])
    let model = EditSliceModel(slice: slice, editPlan: plan)
    #expect(model.overviewWindow == 5_000..<25_000)
  }

  @Test func playTappedPlaysTheDraftRange() async {
    let (model, slice) = makeModel()
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }

    await model.playPauseTapped()

    expectNoDifference(played, [slice.startSample..<slice.endSample])
  }

  @Test func playTappedUsesTheLiveDraftAfterNudging() async {
    let (model, _) = makeModel()
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }
    model.fineTune.nudgeCutIn(byMs: 20)
    let draft = model.fineTune.draftRange

    await model.playPauseTapped()

    expectNoDifference(played, [draft].compactMap { $0 })
  }

  @Test func playStartsFromThePlayheadWhenTheCursorIsInsideTheSlice() async {
    let (model, slice) = makeModel()
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }
    model.playheadSample = slice.startSample + 5_000  // cursor parked mid-slice

    await model.playPauseTapped()

    expectNoDifference(played, [(slice.startSample + 5_000)..<slice.endSample])
  }

  @Test func playFallsBackToTheCutInWhenTheCursorIsOutsideTheSlice() async {
    let (model, slice) = makeModel()
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }
    model.playheadSample = slice.endSample + 10_000  // cursor past the slice

    await model.playPauseTapped()

    expectNoDifference(played, [slice.startSample..<slice.endSample])
  }

  @Test func seekWhilePlayingReAnchorsPlaybackToTheClick() async {
    let model = laneModel()  // slice 10_000..<20_000, spp 100, start 0
    var played: [Range<Int>] = []
    var sought: [Int] = []
    model.onPlay = { played.append($0) }
    model.onSeek = { sought.append($0) }
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.waveformSeeked(toX: 150)  // sample 15_000, inside the slice

    expectNoDifference(played, [15_000..<20_000])  // keeps playing from the click to the cut-out
    #expect(sought.isEmpty)  // it re-anchors, it does not merely reposition
  }

  @Test func seekAtTheCutOutWhilePlayingStopsInsteadOfLeavingPlaybackRunning() async {
    let model = laneModel()  // slice 10_000..<20_000, spp 100, start 0
    var played: [Range<Int>] = []
    var sought: [Int] = []
    var stops = 0
    model.onPlay = { played.append($0) }
    model.onSeek = { sought.append($0) }
    model.onStop = { stops += 1 }
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.waveformSeeked(toX: 1000)  // clamps to the cut-out (20_000)

    #expect(stops == 1)  // stops rather than leaving playback running past the click
    expectNoDifference(sought, [20_000])  // parks the cursor at the cut-out
    #expect(played.isEmpty)  // does not re-anchor to an empty range
  }

  @Test func rulerDragWhilePlayingRepositionsCursorWithoutReAnchoring() async {
    let model = laneModel()  // slice 10_000..<20_000, spp 100, start 0
    var played: [Range<Int>] = []
    var sought: [Int] = []
    model.onPlay = { played.append($0) }
    model.onSeek = { sought.append($0) }
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.waveformDragged(toX: 150)  // sample 15_000

    expectNoDifference(sought, [15_000])  // cursor-only — a ruler scrub never restarts playback
    #expect(played.isEmpty)
  }

  @Test func seekWhilePausedRepositionsWithoutReplaying() async {
    let model = laneModel()  // slice 10_000..<20_000, spp 100, start 0
    var played: [Range<Int>] = []
    var sought: [Int] = []
    model.onPlay = { played.append($0) }
    model.onSeek = { sought.append($0) }
    // not playing (paused/stopped)

    await model.waveformSeeked(toX: 150)  // sample 15_000

    expectNoDifference(sought, [15_000])  // just moves the cursor
    #expect(played.isEmpty)  // no playback started
  }

  @Test func playTappedWhilePlayingPauses() async {
    let (model, _) = makeModel()
    var pauses = 0
    model.onPause = { pauses += 1 }
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.playPauseTapped()

    #expect(pauses == 1)
  }

  @Test func updatePlaybackReflectsPlayheadAndDrivesScopedTranscript() {
    let (model, _) = makeModel()
    model.updatePlayback(sample: 15_000, isPlaying: true)
    #expect(model.playheadSample == 15_000)
    #expect(model.isPlaying == true)
  }

  // MARK: - FIX 1: isPlaying resets on Pause/Stop (the modal's play/pause button no longer wedges)

  @Test func pauseTappedResetsIsPlaying() async {
    let (model, _) = makeModel()
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.playPauseTapped()  // isPlaying, so this pauses

    #expect(model.isPlaying == false)
  }

  @Test func stopTappedResetsIsPlaying() async {
    let (model, _) = makeModel()
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.stopTapped()

    #expect(model.isPlaying == false)
  }

  @Test func stopTappedDelegatesToOnStop() async {
    let (model, _) = makeModel()
    var stops = 0
    model.onStop = { stops += 1 }
    model.updatePlayback(sample: 12_000, isPlaying: true)

    await model.stopTapped()

    #expect(stops == 1)
    #expect(model.isPlaying == false)
  }

  @Test func seekTappedForwardsTheRequestedSampleToOnSeek() async {
    let (model, _) = makeModel()
    var sought: [Int] = []
    model.onSeek = { sought.append($0) }

    await model.seekTapped(toSample: 23_456)

    expectNoDifference(sought, [23_456])
  }

  /// The parent publishes a natural finish back through `updatePlayback`; the modal must reflect
  /// it as stopped. Guards the FIX 1/4 regression where `isPlaying` was set true AFTER `onPlay`
  /// (which returns only once playback has ended), leaving the button stuck on "Pause".
  @Test func parentPublishingAStoppedTickClearsIsPlaying() {
    let (model, _) = makeModel()
    model.updatePlayback(sample: 12_000, isPlaying: true)
    #expect(model.isPlaying == true)

    model.updatePlayback(sample: 12_000, isPlaying: false)

    #expect(model.isPlaying == false)
  }

  @Test func playTappedFromStoppedSetsIsPlayingAndPlaysTheDraftRange() async {
    let (model, slice) = makeModel()
    var played: [Range<Int>] = []
    model.onPlay = { played.append($0) }

    await model.playPauseTapped()  // not playing, so this plays

    #expect(model.isPlaying == true)
    expectNoDifference(played, [slice.startSample..<slice.endSample])
  }

  // MARK: - Waveform lane (the sheet's own WaveformModel; nav-only, insets still edit)

  /// A model whose lane is seeded and laid out with predictable geometry (no focus-fit), so
  /// view-x ↔ sample mapping is exact: window 10_000..<20_000, spp 100, visibleStart 0.
  private func laneModel() -> EditSliceModel {
    let plan = Fixtures.editPlan()
    let slice = Slice(
      id: UUID(), name: "S", startSample: 10_000, endSample: 20_000,
      wordIDs: [], snippet: "", warnings: [])
    let model = EditSliceModel(slice: slice, editPlan: plan)
    model.waveform.totalSamples = 100_000
    model.waveform.viewportResized(width: 1000)  // fit spp 100, visibleStart 0
    return model
  }

  @Test func highlightRangeTracksTheLiveDraftRange() {
    let (model, slice) = makeModel()
    expectNoDifference(model.waveformHighlightRange, slice.startSample..<slice.endSample)
    model.fineTune.nudgeCutIn(byMs: 20)
    expectNoDifference(model.waveformHighlightRange, model.fineTune.draftRange)
  }

  @Test func waveformSeekedMapsXToSampleAndForwardsToOnSeek() async {
    let model = laneModel()  // window 10_000..<20_000, spp 100, start 0
    var sought: [Int] = []
    model.onSeek = { sought.append($0) }

    await model.waveformSeeked(toX: 150)  // 150 px * 100 spp = sample 15_000

    expectNoDifference(sought, [15_000])
  }

  @Test func waveformSeekedClampsInsideTheSliceBeingEdited() async {
    let model = laneModel()  // window 10_000..<20_000
    var sought: [Int] = []
    model.onSeek = { sought.append($0) }

    await model.waveformSeeked(toX: 50)  // sample 5_000, before the slice -> clamps to lower
    await model.waveformSeeked(toX: 500)  // sample 50_000, past the slice -> clamps to upper

    expectNoDifference(sought, [10_000, 20_000])
  }

  @Test func waveformSeekedIsANoOpWithoutUsableGeometry() async {
    let (model, _) = makeModel()  // lane never seeded/laid out
    var sought: [Int] = []
    model.onSeek = { sought.append($0) }

    await model.waveformSeeked(toX: 150)

    #expect(sought.isEmpty)
  }

  @Test func zoomButtonsForwardToTheLane() {
    let model = laneModel()  // fit spp 100
    model.zoomInTapped()
    expectNoDifference(model.waveform.samplesPerPixel, 50)
    model.zoomOutTapped()
    expectNoDifference(model.waveform.samplesPerPixel, 100)
  }

  @Test func zoomFitTogglesAgainstTheSlice() {
    let model = laneModel()  // slice 10_000..<20_000, spp 100
    model.zoomInTapped()  // spp 50, so a fit is a visible change
    model.zoomFitTapped()  // fit the whole slice (10_000..<20_000, 10_000 wide) -> spp 10
    expectNoDifference(model.waveform.samplesPerPixel, 10)
    model.zoomFitTapped()  // same slice -> restore the pre-fit zoom
    expectNoDifference(model.waveform.samplesPerPixel, 50)
  }

  // MARK: - FIX 2: updatePlayback highlights the current word in the scoped transcript

  @Test func updatePlaybackHighlightsTheCurrentWordInTheScopedTranscript() {
    let plan = Fixtures.editPlan()
    let sliceWordIDs = Array(plan.words.prefix(3).map(\.id))
    let slice = Slice(
      id: UUID(), name: "S", startSample: 0, endSample: 20_000,
      wordIDs: sliceWordIDs, snippet: "", warnings: [])
    let model = EditSliceModel(slice: slice, editPlan: plan)
    let targetWord = plan.words.first { $0.id == sliceWordIDs[1] }!
    let sampleInsideWord = targetWord.startSample!

    model.updatePlayback(sample: sampleInsideWord, isPlaying: true)

    expectNoDifference(model.transcript.currentWordID, targetWord.id)
  }
}
