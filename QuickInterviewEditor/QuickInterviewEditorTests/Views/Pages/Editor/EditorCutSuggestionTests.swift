import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorCutSuggestionTests {

  private func editor() -> EditorModel {
    let plan = Fixtures.editPlan()
    let fingerprint = "fp-accept"
    let candidates = [Fixtures.uuid(1), Fixtures.uuid(7)].map { id in
      var candidate = Fixtures.cutSuggestion(id: id, title: "A story", wordIDs: [10, 11, 12])
      candidate.provenance.transcriptHash = plan.transcriptHash
      candidate.provenance.sourceFingerprint = fingerprint
      return candidate
    }
    return EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan, sourceFingerprint: fingerprint,
      initialDocument: EditorDocumentState(
        cutSuggestions: IdentifiedArray(uniqueElements: candidates)))
  }

  private func slice(_ id: UUID) -> Slice {
    Slice(
      id: id, name: "A story", startSample: 44_100, endSample: 88_200,
      wordIDs: [10, 11, 12], snippet: "a story")
  }

  @Test func acceptingASuggestionSliceAddsItToTheEditor() {
    let model = editor()
    let id = Fixtures.uuid(1)
    model.acceptCutSuggestion(slice(id), id: id)
    expectNoDifference(model.slices.count, 1)
    expectNoDifference(model.slices[id: id]?.name, "A story")
  }

  @Test func acceptingASuggestionTargetsItForScrolling() {
    let model = editor()
    let id = Fixtures.uuid(1)
    model.acceptCutSuggestion(slice(id), id: id)
    expectNoDifference(model.sliceScrollTarget, id)
  }

  @Test func acceptingIsIdempotentByID() {
    let model = editor()
    let id = Fixtures.uuid(1)
    model.acceptCutSuggestion(slice(id), id: id)
    model.acceptCutSuggestion(slice(id), id: id)
    expectNoDifference(model.slices.count, 1)
  }

  @Test func acceptedSuggestionSliceIsUndoable() async {
    let model = editor()
    let id = Fixtures.uuid(1)
    model.acceptCutSuggestion(slice(id), id: id)
    #expect(model.canUndo)
    await model.undoTapped()
    expectNoDifference(model.slices.count, 0)
  }

  @Test func acceptWiringFromChildModelLandsASlice() {
    // The editor wires its child cut-suggestions model's onAccept to itself.
    let model = editor()
    let id = Fixtures.uuid(7)
    model.cutSuggestions.onAccept?(slice(id), id)
    expectNoDifference(model.slices[id: id]?.name, "A story")
  }
}
