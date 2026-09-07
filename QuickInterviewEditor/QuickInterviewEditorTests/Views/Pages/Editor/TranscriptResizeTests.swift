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
}
