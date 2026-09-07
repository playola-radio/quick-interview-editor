import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorEditingCompleteTests {
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

  @Test func setSliceEditingCompleteMarksTheSlice() {
    let model = editor()
    addSlice(model, 0, 3)
    let id = model.slices[0].id

    expectDifference(model.slices) {
      model.setSliceEditingComplete(id, to: true)
    } changes: {
      $0[0].editingComplete = true
    }
  }

  @Test func setSliceEditingCompleteIsUndoableAndRedoable() async {
    let model = editor()
    addSlice(model, 0, 3)
    let id = model.slices[0].id

    model.setSliceEditingComplete(id, to: true)
    expectNoDifference(model.slices[id: id]?.editingComplete, true)

    await model.undoTapped()
    expectNoDifference(model.slices[id: id]?.editingComplete, false)

    await model.redoTapped()
    expectNoDifference(model.slices[id: id]?.editingComplete, true)
  }

  @Test func sliceRowsSurfaceCompletionStateAndLabels() {
    let model = editor()
    addSlice(model, 0, 3)
    addSlice(model, 4, 6)
    let completeID = model.slices[0].id
    let inProgressID = model.slices[1].id
    model.setSliceEditingComplete(completeID, to: true)

    let completeRow = model.sliceRows[id: completeID]
    expectNoDifference(completeRow?.editingComplete, true)
    expectNoDifference(completeRow?.completionSystemImage, "checkmark.circle.fill")
    expectNoDifference(completeRow?.completionLabel, "Editing Complete")

    let inProgressRow = model.sliceRows[id: inProgressID]
    expectNoDifference(inProgressRow?.editingComplete, false)
    expectNoDifference(inProgressRow?.completionSystemImage, "circle")
    expectNoDifference(inProgressRow?.completionLabel, "Editing Complete")
  }

  @Test func visibleSliceRowsFilterByCompletion() {
    let model = editor()
    addSlice(model, 0, 3)
    addSlice(model, 4, 6)
    let completeID = model.slices[0].id
    let inProgressID = model.slices[1].id
    model.setSliceEditingComplete(completeID, to: true)

    model.sliceFilter = .all
    expectNoDifference(model.visibleSliceRows.map(\.id), [completeID, inProgressID])

    model.sliceFilter = .inProgress
    expectNoDifference(model.visibleSliceRows.map(\.id), [inProgressID])

    model.sliceFilter = .complete
    expectNoDifference(model.visibleSliceRows.map(\.id), [completeID])
  }

  @Test func undoingASheetEditingCompleteToggleReSyncsTheOpenSheet() async {
    let model = editor()
    addSlice(model, 0, 3)
    let id = model.slices[0].id
    model.editSliceTapped(id)
    let sheet = model.editSlice
    #expect(sheet != nil)

    sheet?.editingCompleteToggled()
    expectNoDifference(model.slices[id: id]?.editingComplete, true)
    expectNoDifference(sheet?.editingComplete, true)

    // ⌘Z forwarded from the open sheet reverts the flag on the document; the sheet's boundaries
    // are unchanged so it stays open, and its seeded flag must track the revert instead of going
    // stale (else it shows the wrong icon and the next toggle sends a no-op value).
    await model.undoTapped()

    expectNoDifference(model.slices[id: id]?.editingComplete, false)
    expectNoDifference(model.editSlice?.editingComplete, false)
  }

  @Test func movingVisibleRowsWhileFilteredReordersOnlyVisibleSlices() {
    let model = editor()
    addSlice(model, 0, 1)
    addSlice(model, 2, 3)
    addSlice(model, 4, 5)
    addSlice(model, 6, 7)
    let ids = model.slices.map(\.id)
    model.setSliceEditingComplete(ids[0], to: true)
    model.setSliceEditingComplete(ids[2], to: true)

    model.sliceFilter = .inProgress
    expectNoDifference(model.visibleSliceRows.map(\.id), [ids[1], ids[3]])

    // The panel emits offsets indexed into the visible rows, so dragging visible row 1
    // above visible row 0 must reorder only the in-progress clips and leave the hidden
    // complete clips in their absolute slots.
    model.moveSlices(fromOffsets: IndexSet(integer: 1), toOffset: 0)

    expectNoDifference(model.slices.map(\.id), [ids[0], ids[3], ids[2], ids[1]])
  }

  @Test func movingWithAllFilterReordersTheFullCollection() {
    let model = editor()
    addSlice(model, 0, 1)
    addSlice(model, 2, 3)
    addSlice(model, 4, 5)
    let ids = model.slices.map(\.id)

    model.moveSlices(fromOffsets: IndexSet(integer: 0), toOffset: 3)

    expectNoDifference(model.slices.map(\.id), [ids[1], ids[2], ids[0]])
  }

  @Test func movingWithAnOutOfRangeSourceOffsetIsANoOp() {
    let model = editor()
    addSlice(model, 0, 1)
    addSlice(model, 2, 3)
    addSlice(model, 4, 5)
    let ids = model.slices.map(\.id)

    // SwiftUI's `onMove` never emits an out-of-range offset, but the reorder helper must stay
    // total: a stray offset past the end leaves the order untouched rather than trapping.
    model.moveSlices(fromOffsets: IndexSet(integer: 3), toOffset: 0)

    expectNoDifference(model.slices.map(\.id), ids)
  }

  @Test func sliceListEmptyMessageReflectsFilterVsNoSlices() {
    let model = editor()
    expectNoDifference(model.sliceListEmptyMessage, model.emptyStateMessage)

    addSlice(model, 0, 3)
    model.sliceFilter = .complete

    #expect(model.sliceListEmptyMessage != model.emptyStateMessage)
    #expect(!model.sliceListEmptyMessage.isEmpty)
  }
}
