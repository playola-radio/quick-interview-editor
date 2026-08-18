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
}
