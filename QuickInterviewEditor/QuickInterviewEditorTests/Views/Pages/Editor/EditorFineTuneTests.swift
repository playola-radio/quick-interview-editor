import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorFineTuneTests {
  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan)
  }

  private func addSlice(_ model: EditorModel, _ first: Int, _ last: Int) {
    model.transcript.wordTapped(model.transcript.words[first].id)
    model.transcript.wordTapped(model.transcript.words[last].id)
    model.addSliceTapped()
  }

  // MARK: - Session open / overlay

  @Test func selectingSliceOpensSessionAnchoredToItsRange() {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.sliceSelected(slice.id)
    expectNoDifference(model.activeSliceID, slice.id)
    expectNoDifference(model.fineTune.target, .slice(slice.id))
    expectNoDifference(model.fineTune.committedRange, slice.startSample..<slice.endSample)
    // Before any drag the overlay is the committed range; after a nudge it follows the draft.
    expectNoDifference(model.activeEditingRange, slice.startSample..<slice.endSample)
    model.cutOutNudged(byMs: 10)
    expectNoDifference(model.activeEditingRange, model.fineTune.draftRange)
    #expect(model.activeEditingRange != slice.startSample..<slice.endSample)
  }

  @Test func pendingSelectionBindsPaneWithoutAnActiveSlice() {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[2].id)
    expectNoDifference(model.fineTuneTarget, .pendingSelection)
    #expect(model.showsFineTunePane)
    model.syncEditSession()
    expectNoDifference(model.fineTune.committedRange, model.transcript.selectedSampleRange)
  }

  // MARK: - Commit = one undo entry, re-derived membership

  @Test func commitEditIsOneUndoEntryAndRederivesWords() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    let originalRange = slice.startSample..<slice.endSample

    model.sliceSelected(slice.id)
    // A whole "drag": several draft updates, then a single commit.
    model.cutOutNudged(byMs: 10)
    model.cutOutNudged(byMs: 10)
    model.cutOutNudged(byMs: 10)
    let draft = model.fineTune.draftRange!
    #expect(draft != originalRange)

    model.commitEditTapped()
    let committed = model.slices[id: slice.id]!
    expectNoDifference(committed.startSample..<committed.endSample, draft)
    // Word membership + snippet are re-derived from the new range, not the stale selection.
    expectNoDifference(committed.wordIDs, wordIDs(overlapping: draft, words: model.editPlan.words))
    #expect(!committed.snippet.isEmpty)

    // Exactly one undo entry for the whole drag: undoing restores the original cut in one step.
    #expect(model.canUndo)
    await model.undoTapped()
    let restored = model.slices[id: slice.id]!
    expectNoDifference(restored.startSample..<restored.endSample, originalRange)
    expectNoDifference(model.slices.count, 1)  // the add was not undone
  }

  @Test func commitPendingSelectionAddsSliceFromDraft() {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[2].id)
    model.syncEditSession()
    model.cutOutNudged(byMs: -10)
    let draft = model.fineTune.draftRange!

    model.commitEditTapped()
    expectNoDifference(model.slices.count, 1)
    let added = model.slices[0]
    expectNoDifference(added.startSample..<added.endSample, draft)
    expectNoDifference(added.wordIDs, wordIDs(overlapping: draft, words: model.editPlan.words))
    #expect(!model.transcript.hasSelection)  // selection cleared, pane closes
  }

  @Test func commitWithNoChangeDoesNothing() {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.sliceSelected(slice.id)
    #expect(model.canUndo)  // add is undoable; no unsaved edit yet
    let before = model.slices
    model.commitEditTapped()  // draft == committed → no-op
    expectNoDifference(model.slices, before)
  }

  // MARK: - Cancel restores

  @Test func cancelEditDropsDraftAndKeepsPaneOpen() {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.sliceSelected(slice.id)
    model.cutOutNudged(byMs: 10)
    #expect(model.hasUncommittedSliceEdit)

    model.cancelEditTapped()
    #expect(!model.hasUncommittedSliceEdit)
    expectNoDifference(model.fineTune.draftRange, slice.startSample..<slice.endSample)
    expectNoDifference(model.slices[id: slice.id], slice)  // untouched
    expectNoDifference(model.activeSliceID, slice.id)  // pane stays open
  }

  // MARK: - Gating

  @Test func uncommittedSliceEditGatesExportAndUndoRedo() {
    let model = editor()
    addSlice(model, 0, 3)
    addSlice(model, 4, 5)
    #expect(model.canExportAll)
    #expect(model.canUndo)

    model.sliceSelected(model.slices[0].id)
    model.cutOutNudged(byMs: 10)
    #expect(model.hasUncommittedSliceEdit)
    #expect(!model.canExportAll)
    #expect(!model.canExportSlice)
    #expect(!model.canUndo)
    #expect(!model.canRedo)

    model.cancelEditTapped()
    #expect(model.canExportAll)
    #expect(model.canUndo)
  }

  @Test func pendingSelectionDraftDoesNotGateExport() {
    let model = editor()
    addSlice(model, 0, 1)  // an exportable slice exists
    #expect(model.canExportAll)
    // Open a pending draft on a different selection and change it.
    model.transcript.wordTapped(model.transcript.words[4].id)
    model.transcript.wordTapped(model.transcript.words[6].id)
    model.syncEditSession()
    model.cutOutNudged(byMs: 10)
    #expect(model.fineTune.hasUnsavedChange)
    #expect(!model.hasUncommittedSliceEdit)  // pending is a new slice, not a mutation
    #expect(model.canExportAll)  // export of existing slices still allowed
  }

  // MARK: - Active-slice lifecycle (reconcile seam)

  @Test func deletingActiveSliceClearsSessionViaReconcile() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.sliceSelected(slice.id)
    model.cutOutNudged(byMs: 10)  // an open draft on the active slice

    await model.deleteSlice(slice.id)
    expectNoDifference(model.activeSliceID, nil)
    expectNoDifference(model.fineTune.target, nil)
    expectNoDifference(model.fineTune.draftRange, nil)
    expectNoDifference(model.fineTune.committedRange, nil)
  }

  @Test func undoRemovingActiveSliceClearsSession() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.sliceSelected(slice.id)  // no unsaved edit → undo of the add is allowed
    await model.undoTapped()  // removes the added (active) slice
    expectNoDifference(model.slices, [])
    expectNoDifference(model.activeSliceID, nil)
    expectNoDifference(model.fineTune.target, nil)
  }

  @Test func undoingAnActiveSliceEditReanchorsTheSession() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    let originalRange = slice.startSample..<slice.endSample

    model.sliceSelected(slice.id)
    model.cutOutNudged(byMs: 10)
    let edited = model.fineTune.draftRange!
    model.commitEditTapped()  // slice now at `edited`; committed baseline advanced
    expectNoDifference(model.fineTune.committedRange, edited)

    let keyBeforeUndo = model.fineTuneSessionKey
    await model.undoTapped()  // slice restored to `originalRange`, active slice unchanged
    // The session re-anchors at the MODEL level via reconcile — no view round-trip needed…
    expectNoDifference(model.fineTune.committedRange, originalRange)
    expectNoDifference(model.fineTune.draftRange, originalRange)
    // …and the session key also changed, so the view's onChange path stays consistent.
    #expect(model.fineTuneSessionKey != keyBeforeUndo)
  }

  @Test func undoAndExportAreBlockedWhileASliceEditIsUncommitted() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.sliceSelected(slice.id)
    model.cutOutNudged(byMs: 10)  // uncommitted existing-slice edit
    let before = model.slices

    // Direct action calls (menu/keyboard bypassing the disabled buttons) must no-op.
    await model.undoTapped()
    await model.redoTapped()
    model.exportAllTapped()
    model.exportSliceTapped(slice.id)
    expectNoDifference(model.slices, before)  // nothing rewound
    expectNoDifference(model.exportPhase, .idle)  // nothing exported
    #expect(model.exportTask == nil)
    #expect(model.fineTune.hasUnsavedChange)  // the draft is untouched
  }

  @Test func reorderingSurvivesActiveSession() {
    let model = editor()
    addSlice(model, 0, 1)
    addSlice(model, 2, 3)
    let first = model.slices[0]
    model.sliceSelected(first.id)
    model.moveSlices(fromOffsets: IndexSet(integer: 0), toOffset: 2)
    // Active slice is ID-based, so it survives a reorder.
    expectNoDifference(model.activeSliceID, first.id)
    #expect(model.fineTune.target == .slice(first.id))
  }

  // MARK: - Preview edit

  @Test func previewEditPlaysDraftRange() async {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.sliceSelected(slice.id)
    model.cutOutNudged(byMs: 10)
    let draft = model.fineTune.draftRange!
    let recorded = LockIsolated<Range<Int>?>(nil)

    await withDependencies {
      $0.audioPlayer.play = { _, range, _ in recorded.setValue(range) }
    } operation: {
      await model.previewEditTapped()
    }
    expectNoDifference(recorded.value, draft)  // preview plays the DRAFT, not the committed range
    expectNoDifference(model.playingSliceID, nil)  // distinct from panel playback
    #expect(!model.isPreviewingDraft)
  }
}
