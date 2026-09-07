import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct TranscriptResizeTests {

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

  @Test func selectionResizeUpdatesSelectionLive() {
    let model = editor()
    model.selectWords(anchorID: 3, focusID: 4)
    expectNoDifference(model.selectedWordIDs, [3, 4])

    model.transcriptResizeBegan(.selection, .start)
    model.transcriptResizeDragged(toWord: 1)
    expectNoDifference(model.selectedWordIDs, [1, 2, 3, 4])

    model.transcriptResizeEnded()
    expectNoDifference(model.transcriptResizeDraft, nil)
    expectNoDifference(model.selectedWordIDs, [1, 2, 3, 4])
  }

  @Test func clipResizeDoesNotTouchSlicesUntilMouseUp() {
    let clipID = Fixtures.uuid(1)
    let model = editor(slices: [clip(clipID, wordIDs: [1, 2])])
    let before = model.slices

    model.transcriptResizeBegan(.clip(clipID), .end)
    model.transcriptResizeDragged(toWord: 4)

    expectNoDifference(model.slices, before)
    let previewed = model.transcriptResizeItems.first { $0.identity == .clip(clipID) }
    expectNoDifference(previewed?.wordIDs, [1, 2, 3, 4])
    let band = model.clipBands.first { $0.id == clipID }
    expectNoDifference(band?.wordIDs, [1, 2, 3, 4])
  }

  @Test func clipResizeCommitsOnceOnEnd() async {
    let clipID = Fixtures.uuid(1)
    let model = editor(slices: [clip(clipID, wordIDs: [1, 2])])

    model.transcriptResizeBegan(.clip(clipID), .end)
    model.transcriptResizeDragged(toWord: 4)
    model.transcriptResizeEnded()

    expectNoDifference(model.slices[id: clipID]?.wordIDs, [1, 2, 3, 4])
    expectNoDifference(model.transcriptResizeDraft, nil)

    await model.undoTapped()
    expectNoDifference(model.slices[id: clipID]?.wordIDs, [1, 2])
  }

  @Test func clipResizeCancelledDropsDraft() {
    let clipID = Fixtures.uuid(1)
    let model = editor(slices: [clip(clipID, wordIDs: [1, 2])])
    let before = model.slices

    model.transcriptResizeBegan(.clip(clipID), .end)
    model.transcriptResizeDragged(toWord: 4)
    model.transcriptResizeCancelled()

    expectNoDifference(model.slices, before)
    expectNoDifference(model.transcriptResizeDraft, nil)
  }

  @Test func selectionResizeEndPinsAnchorToFixedStartEdge() {
    let model = editor()
    model.selectWords(anchorID: 3, focusID: 4)
    expectNoDifference(model.selectedWordIDs, [3, 4])
    let originalStartBound = model.selectionAnchorSample

    model.transcriptResizeBegan(.selection, .end)
    model.transcriptResizeDragged(toWord: 5)

    expectNoDifference(model.selectedWordIDs, [3, 4, 5])
    expectNoDifference(model.audioSelection, 77704..<135960)
    expectNoDifference(model.selectionAnchorSample, originalStartBound)
    expectNoDifference(model.selectionAnchorSample, 77704)
  }

  @Test func selectionResizeStartFollowsEditedEdgeAnchor() {
    let model = editor()
    model.selectWords(anchorID: 3, focusID: 4)
    expectNoDifference(model.selectedWordIDs, [3, 4])
    expectNoDifference(model.selectionAnchorSample, 77704)

    model.transcriptResizeBegan(.selection, .start)
    model.transcriptResizeDragged(toWord: 1)

    expectNoDifference(model.selectedWordIDs, [1, 2, 3, 4])
    expectNoDifference(model.audioSelection, 54772..<119202)
    expectNoDifference(model.selectionAnchorSample, 54772)
  }

  /// Regression for the bug FIX 1 closes: a transcript-driven selection resize must invalidate the
  /// transcript's own private toggle/extend anchor (as `applyEdgeEdit` does), or a later Shift-click
  /// on an unrelated word silently resurrects the pre-resize anchor and extends a span from it
  /// instead of starting a fresh single-word selection. Routed through the PUBLIC transcript
  /// gesture entry points (`selectWords`/`wordClicked`) rather than `selectionAnchorID`/
  /// `selectionFocusID` directly, since those are `private` on `TranscriptPageModel`.
  @Test func selectionResizeInvalidatesTranscriptShiftExtendAnchor() {
    let model = editor()
    // A real transcript drag-select over words 1...2: sets both the transcript's private anchor
    // (word 1) and `audioSelection` via the `onSelectionIntent` funnel.
    model.transcript.selectWords(anchorID: 1, focusID: 2)
    expectNoDifference(model.selectedWordIDs, [1, 2])

    // Resize the END edge outward, past word 2, to word 4.
    model.transcriptResizeBegan(.selection, .end)
    model.transcriptResizeDragged(toWord: 4)
    model.transcriptResizeEnded()
    expectNoDifference(model.selectedWordIDs, [1, 2, 3, 4])

    // A subsequent Shift-click on an unrelated word (6, non-adjacent to word 1).
    model.transcript.wordClicked(6, extending: true)

    // Fixed: the transcript anchor was invalidated during the resize, so this Shift-click starts a
    // fresh single-word selection of word 6 alone — NOT a stale span from word 1 to word 6.
    expectNoDifference(model.selectedWordIDs, [6])
    expectNoDifference(model.audioSelection, 139488..<150072)
  }
}
