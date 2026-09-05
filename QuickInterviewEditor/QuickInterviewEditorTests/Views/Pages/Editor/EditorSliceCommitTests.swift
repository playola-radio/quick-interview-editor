import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

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
    // wordIDs recomputed from the range by the spec's overlap rule, not left at the old set:
    expectNoDifference(updated?.wordIDs, wordIDs(anyOverlap: draft, words: model.editPlan.words))
  }

  /// Editing a clip must use the same overlap membership rule as creating it, so a word included
  /// on create (any overlap) is never silently dropped by an Edit → Save that leaves the range
  /// unchanged. Regression: the edit-recompute used the legacy midpoint rule, so a word overlapping
  /// the clip by under 50% survived create but vanished on save.
  @Test func editingWithoutMovingBoundariesPreservesPartialOverlapMembership() {
    let model = editor()
    let words = model.editPlan.words
    // A range from mid-word[1] to mid-word[3]: word[1] and word[3] overlap by under half (their
    // midpoints fall OUTSIDE the range), so the midpoint rule would exclude them while overlap
    // includes all three. This is exactly the create/edit divergence.
    func mid(_ word: Word) -> Int {
      word.startSample! + (word.endSample! - word.startSample!) / 2
    }
    let range = (mid(words[1]) + 1)..<mid(words[3])
    model.selectSourceRange(range, snapPlayhead: false)
    model.addSliceTapped()
    let slice = model.slices[0]
    let onCreate = slice.wordIDs
    #expect(onCreate.contains(words[1].id))
    #expect(onCreate.contains(words[3].id))

    model.commitSliceEdit(id: slice.id, range: range)

    expectNoDifference(model.slices[id: slice.id]?.wordIDs, onCreate)
  }

  @Test func commitSliceEditRecordsExactlyOneUndoEntry() {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.sliceSelected(slice.id)
    model.cutOutNudged(byMs: 10)
    let draft = model.fineTune.draftRange!
    let depthBefore = model.documentUndo.undo.count

    model.commitSliceEdit(id: slice.id, range: draft)

    expectNoDifference(model.documentUndo.undo.count, depthBefore + 1)
  }

  @Test func sliceEditTransportContextDoesNotHighlightSliceOrFollowTranscript() {
    #expect(!TransportContext.sliceEdit.isSlice)
    #expect(!TransportContext.sliceEdit.followsTranscript)
  }
}
