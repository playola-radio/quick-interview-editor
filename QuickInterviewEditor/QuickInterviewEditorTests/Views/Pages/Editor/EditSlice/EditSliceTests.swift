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
}
