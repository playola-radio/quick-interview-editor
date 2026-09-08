import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct TranscriptResizeTeardownTests {

  private func editor(slices: IdentifiedArrayOf<Slice> = []) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL,
      editPlan: Fixtures.editPlan(),
      initialDocument: EditorDocumentState(slices: slices))
  }

  private func clip(_ id: UUID, wordIDs: [Word.ID]) -> Slice {
    Slice(
      id: id, name: "A story", startSample: 54772, endSample: 74176,
      wordIDs: wordIDs, snippet: "So a")
  }

  @Test func cancelDuringClipDragLeavesDocumentAndDraftClean() {
    let clipID = Fixtures.uuid(1)
    let model = editor(slices: [clip(clipID, wordIDs: [1, 2])])
    let before = model.slices

    model.transcriptResizeBegan(.clip(clipID), .end)
    model.transcriptResizeDragged(toWord: 4)
    model.transcriptResizeCancelled()

    expectNoDifference(model.slices, before)
    expectNoDifference(model.transcriptResizeDraft, nil)

    // A subsequent normal commit still works (state machine not wedged by the cancel):
    model.transcriptResizeBegan(.clip(clipID), .end)
    model.transcriptResizeDragged(toWord: 3)
    model.transcriptResizeEnded()
    expectNoDifference(model.slices[id: clipID]?.wordIDs, [1, 2, 3])
  }

  @Test func cancelDuringSelectionDragRestoresOriginalSelection() {
    let model = editor()
    model.selectWords(anchorID: 2, focusID: 3)
    expectNoDifference(model.selectedWordIDs, [2, 3])

    model.transcriptResizeBegan(.selection, .start)
    model.transcriptResizeDragged(toWord: 1)
    expectNoDifference(model.selectedWordIDs, [1, 2, 3])
    model.transcriptResizeCancelled()

    expectNoDifference(model.selectedWordIDs, [2, 3])
    expectNoDifference(model.selectionEditingEdge, nil)
  }

  @Test func draggedWithNoActiveDraftIsNoop() {
    let model = editor()
    model.transcriptResizeDragged(toWord: 1)
    expectNoDifference(model.transcriptResizeDraft, nil)
  }

  @Test func minOneWordEnforcedThroughStateMachine() {
    let clipID = Fixtures.uuid(1)
    let model = editor(slices: [clip(clipID, wordIDs: [2, 3])])

    model.transcriptResizeBegan(.clip(clipID), .start)
    model.transcriptResizeDragged(toWord: 5)  // start dragged past the clip's own end word
    model.transcriptResizeEnded()

    expectNoDifference(model.slices[id: clipID]?.wordIDs, [3])
  }
}
