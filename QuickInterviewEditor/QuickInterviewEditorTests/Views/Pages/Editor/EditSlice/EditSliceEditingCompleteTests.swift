import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditSliceEditingCompleteTests {
  private func makeModel(editingComplete: Bool = false) -> (EditSliceModel, Slice) {
    let plan = Fixtures.editPlan()
    let slice = Slice(
      id: UUID(), name: "Slice 1",
      startSample: 10_000, endSample: 40_000,
      wordIDs: [], snippet: "", editingComplete: editingComplete)
    return (EditSliceModel(slice: slice, editPlan: plan), slice)
  }

  @Test func editingCompleteLabelDoesNotChangeWithState() {
    let (completeModel, _) = makeModel(editingComplete: true)
    let (inProgressModel, _) = makeModel(editingComplete: false)

    expectNoDifference(completeModel.editingComplete, true)
    expectNoDifference(completeModel.editingCompleteLabel, "Editing Complete")
    expectNoDifference(completeModel.editingCompleteSystemImage, "checkmark.circle.fill")
    expectNoDifference(inProgressModel.editingComplete, false)
    expectNoDifference(inProgressModel.editingCompleteLabel, "Editing Complete")
    expectNoDifference(inProgressModel.editingCompleteSystemImage, "circle")
  }

  @Test func togglingAppliesImmediatelyViaCallback() {
    let (model, _) = makeModel(editingComplete: false)
    var received: [Bool] = []
    model.onSetEditingComplete = { received.append($0) }

    model.editingCompleteToggled()
    expectNoDifference(model.editingComplete, true)
    expectNoDifference(received, [true])

    model.editingCompleteToggled()
    expectNoDifference(model.editingComplete, false)
    expectNoDifference(received, [true, false])
  }
}
