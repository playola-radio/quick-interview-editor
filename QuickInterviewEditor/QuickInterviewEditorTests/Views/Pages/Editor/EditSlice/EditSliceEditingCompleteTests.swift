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

  @Test func seedsEditingCompleteFromSlice() {
    let (model, _) = makeModel(editingComplete: true)

    expectNoDifference(model.editingComplete, true)
    expectNoDifference(model.editingCompleteLabel, "Mark as still editing")
    expectNoDifference(model.editingCompleteSystemImage, "checkmark.circle.fill")
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
