import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorCutSuggestionTests {

  private func editor() -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: Fixtures.editPlan())
  }

  private func slice(_ id: UUID) -> Slice {
    Slice(
      id: id, name: "A story", startSample: 44_100, endSample: 88_200,
      wordIDs: [10, 11, 12], snippet: "a story")
  }

  @Test func acceptingASuggestionSliceAddsItToTheEditor() {
    let model = editor()
    let id = Fixtures.uuid(1)
    model.acceptCutSuggestionSlice(slice(id))
    expectNoDifference(model.slices.count, 1)
    expectNoDifference(model.slices[id: id]?.name, "A story")
  }

  @Test func acceptingASuggestionTargetsItForScrolling() {
    let model = editor()
    let id = Fixtures.uuid(1)
    model.acceptCutSuggestionSlice(slice(id))
    expectNoDifference(model.sliceScrollTarget, id)
  }

  @Test func acceptingIsIdempotentByID() {
    let model = editor()
    let id = Fixtures.uuid(1)
    model.acceptCutSuggestionSlice(slice(id))
    model.acceptCutSuggestionSlice(slice(id))
    expectNoDifference(model.slices.count, 1)
  }

  @Test func acceptedSuggestionSliceIsUndoable() async {
    let model = editor()
    let id = Fixtures.uuid(1)
    model.acceptCutSuggestionSlice(slice(id))
    #expect(model.canUndo)
    await model.undoTapped()
    expectNoDifference(model.slices.count, 0)
  }

  @Test func acceptWiringFromChildModelLandsASlice() {
    // The editor wires its child cut-suggestions model's onAcceptSlice to itself.
    let model = editor()
    model.cutSuggestions.onAcceptSlice?(slice(Fixtures.uuid(7)))
    expectNoDifference(model.slices[id: Fixtures.uuid(7)]?.name, "A story")
  }
}
