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

  @Test func overviewColumnsAskTheProviderForTheOverviewWindow() {
    let plan = Fixtures.editPlan()
    let slice = Slice(
      id: UUID(), name: "S", startSample: 5_000, endSample: 25_000,
      wordIDs: [], snippet: "", warnings: [])
    let model = EditSliceModel(slice: slice, editPlan: plan)
    var asked: [Range<Int>] = []
    model.columnsProvider = { window, _ in
      asked.append(window)
      return []
    }

    _ = model.overviewColumns(pixelWidth: 600)

    expectNoDifference(asked, [5_000..<25_000])
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

  // MARK: - Overview geometry (model owns sample↔fraction mapping; the view only scales by width)

  private func geometryModel() -> EditSliceModel {
    let plan = Fixtures.editPlan()
    let slice = Slice(
      id: UUID(), name: "S", startSample: 10_000, endSample: 20_000,
      wordIDs: [], snippet: "", warnings: [])
    return EditSliceModel(slice: slice, editPlan: plan)
  }

  @Test func overviewPlayheadFractionMapsTheCursorAcrossTheWindow() {
    let model = geometryModel()  // window 10_000..<20_000
    model.playheadSample = 15_000
    expectNoDifference(model.overviewPlayheadFraction, 0.5)
    model.playheadSample = 20_000  // upper bound is inclusive
    expectNoDifference(model.overviewPlayheadFraction, 1.0)
    model.playheadSample = 5_000  // before the slice → hidden
    #expect(model.overviewPlayheadFraction == nil)
  }

  @Test func overviewSeekSampleMapsAFractionBackToASampleAndClamps() {
    let model = geometryModel()  // window 10_000..<20_000
    expectNoDifference(model.overviewSeekSample(atFraction: 0), 10_000)
    expectNoDifference(model.overviewSeekSample(atFraction: 0.5), 15_000)
    expectNoDifference(model.overviewSeekSample(atFraction: 1), 20_000)
    expectNoDifference(model.overviewSeekSample(atFraction: 2), 20_000)  // clamped past the edge
  }

  @Test func overviewCutFractionsTrackTheLiveDraftRange() {
    let model = geometryModel()  // draft starts equal to the committed window
    expectNoDifference(model.overviewCutInFraction, 0)
    expectNoDifference(model.overviewCutOutFraction, 1)

    model.fineTune.nudgeCutIn(byMs: 20)  // pull the cut-in inward

    #expect((model.overviewCutInFraction ?? 0) > 0)
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
