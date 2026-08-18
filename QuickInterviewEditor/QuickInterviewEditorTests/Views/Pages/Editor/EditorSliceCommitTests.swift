import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorSliceCommitTests {
  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan)
  }

  private func selectWords(_ transcript: TranscriptPageModel, _ first: Int, _ last: Int) {
    transcript.transcriptDragBegan(
      atUTF16Offset: transcript.document.wordRanges[first].range.location)
    transcript.transcriptDragged(
      toUTF16Offset: transcript.document.wordRanges[last].range.location)
  }

  private func addSlice(_ model: EditorModel, _ first: Int, _ last: Int) {
    selectWords(model.transcript, first, last)
    model.addSliceTapped()
  }

  @Test func commitSliceEditMovesBoundariesAndRecomputesWords() {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.sliceSelected(slice.id)
    model.cutOutNudged(byMs: 10)
    model.cutOutNudged(byMs: 10)
    let draft = model.fineTune.draftRange!
    #expect(draft != slice.startSample..<slice.endSample)

    model.commitSliceEdit(id: slice.id, range: draft)

    let updated = model.slices[id: slice.id]
    #expect(updated?.startSample == draft.lowerBound)
    #expect(updated?.endSample == draft.upperBound)
    // wordIDs recomputed from the range, not left at the old set:
    expectNoDifference(updated?.wordIDs, wordIDs(overlapping: draft, words: model.editPlan.words))
  }

  @Test func commitSliceEditRecordsExactlyOneUndoEntry() {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.sliceSelected(slice.id)
    model.cutOutNudged(byMs: 10)
    let draft = model.fineTune.draftRange!
    let depthBefore = model.sliceUndo.undo.count

    model.commitSliceEdit(id: slice.id, range: draft)

    expectNoDifference(model.sliceUndo.undo.count, depthBefore + 1)
  }

  @Test func sliceEditTransportContextDoesNotHighlightSliceOrFollowTranscript() {
    #expect(!TransportContext.sliceEdit.isSlice)
    #expect(!TransportContext.sliceEdit.followsTranscript)
  }
}
