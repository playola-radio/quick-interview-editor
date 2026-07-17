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

  @Test func changingSelectionResetsAPendingDraft() {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[2].id)
    model.syncEditSession()
    model.cutOutNudged(byMs: 10)  // unsaved pending draft on selection A
    #expect(model.fineTune.hasUnsavedChange)

    // The user picks different words before saving — the pending draft must re-anchor to the
    // new selection, not silently save the old range.
    model.transcript.wordTapped(model.transcript.words[4].id)
    model.transcript.wordTapped(model.transcript.words[6].id)
    model.syncEditSession()
    #expect(!model.fineTune.hasUnsavedChange)  // the stale draft was dropped
    let newSelection = model.transcript.selectedSampleRange!
    expectNoDifference(model.fineTune.committedRange, newSelection)

    model.cutOutNudged(byMs: -10)  // tune the NEW selection
    let draft = model.fineTune.draftRange!
    expectNoDifference(draft.lowerBound, newSelection.lowerBound)  // anchored to the new range
    model.commitEditTapped()
    let added = model.slices.last!
    expectNoDifference(added.startSample..<added.endSample, draft)  // saved the new range, not A
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

  @Test func aFreshTranscriptSelectionRetargetsThePaneToPending() {
    let model = editor()
    addSlice(model, 0, 1)
    let slice = model.slices[0]
    model.sliceSelected(slice.id)
    expectNoDifference(model.fineTuneTarget, .slice(slice.id))

    // Selecting new words is a new-slice intent: it takes over the pane and releases the slice,
    // so the user isn't stuck editing the old slice forever.
    model.transcript.wordTapped(model.transcript.words[4].id)
    model.transcript.wordTapped(model.transcript.words[6].id)
    model.syncEditSession()
    expectNoDifference(model.fineTuneTarget, .pendingSelection)
    expectNoDifference(model.activeSliceID, nil)
    expectNoDifference(model.fineTune.committedRange, model.transcript.selectedSampleRange)
  }

  @Test func aSelectionDoesNotDropAnUnsavedSliceEditUntilResolved() {
    let model = editor()
    addSlice(model, 0, 3)
    let slice = model.slices[0]
    model.sliceSelected(slice.id)
    model.cutOutNudged(byMs: 10)  // unsaved slice edit
    let draft = model.fineTune.draftRange

    // A selection arriving mid-edit is held off — the slice draft is preserved.
    model.transcript.wordTapped(model.transcript.words[5].id)
    model.transcript.wordTapped(model.transcript.words[7].id)
    model.syncEditSession()
    expectNoDifference(model.fineTune.target, .slice(slice.id))
    expectNoDifference(model.fineTune.draftRange, draft)

    // Once cancelled, the waiting selection takes over the pane.
    model.cancelEditTapped()
    expectNoDifference(model.fineTune.target, .pendingSelection)
    expectNoDifference(model.activeSliceID, nil)
  }

  @Test func switchingSlicesIsBlockedWhileAnEditIsUnsaved() {
    let model = editor()
    addSlice(model, 0, 1)
    addSlice(model, 2, 3)
    let first = model.slices[0]
    let second = model.slices[1]

    model.sliceSelected(first.id)
    model.cutOutNudged(byMs: 10)
    let draft = model.fineTune.draftRange
    // Clicking another slice's fine-tune button must not silently drop the unsaved edit.
    model.sliceSelected(second.id)
    expectNoDifference(model.activeSliceID, first.id)
    expectNoDifference(model.fineTune.draftRange, draft)

    // Once the edit is resolved, switching works.
    model.cancelEditTapped()
    model.sliceSelected(second.id)
    expectNoDifference(model.activeSliceID, second.id)
  }

  @Test func switchingToASliceIsBlockedWhileAPendingDraftIsUnsaved() {
    let model = editor()
    addSlice(model, 0, 1)  // a slice we might switch to
    let existing = model.slices[0]

    // Tune a pending selection without saving.
    model.transcript.wordTapped(model.transcript.words[4].id)
    model.transcript.wordTapped(model.transcript.words[6].id)
    model.syncEditSession()
    model.cutOutNudged(byMs: 10)
    #expect(model.fineTune.hasUnsavedChange)
    let draft = model.fineTune.draftRange

    // Clicking a slice's fine-tune button must not silently discard the pending tuning.
    model.sliceSelected(existing.id)
    expectNoDifference(model.fineTune.target, .pendingSelection)
    expectNoDifference(model.fineTune.draftRange, draft)
    expectNoDifference(model.activeSliceID, nil)

    // Once resolved, switching works.
    model.cancelEditTapped()
    model.sliceSelected(existing.id)
    expectNoDifference(model.activeSliceID, existing.id)
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

  @Test func addSliceIsDisabledWhileAPendingDraftIsTuned() {
    let model = editor()
    model.transcript.wordTapped(model.transcript.words[0].id)
    model.transcript.wordTapped(model.transcript.words[2].id)
    model.syncEditSession()
    #expect(model.canAddSlice)  // selection made, nothing tuned yet

    model.cutOutNudged(byMs: 10)  // tune the pending selection
    #expect(!model.canAddSlice)  // plain Add slice would discard the tuning → disabled
    model.addSliceTapped()  // action-level guard: no-op
    expectNoDifference(model.slices.count, 0)

    // Save cut adds the tuned range instead.
    let draft = model.fineTune.draftRange!
    model.commitEditTapped()
    expectNoDifference(model.slices.count, 1)
    expectNoDifference(model.slices[0].startSample..<model.slices[0].endSample, draft)
  }

  // MARK: - Preview edit

  @Test func previewButtonTogglesToStopWhilePreviewing() async {
    let model = editor()
    expectNoDifference(model.previewButtonLabel, model.fineTune.previewEditLabel)
    model.isPreviewingDraft = true
    expectNoDifference(model.previewButtonLabel, model.fineTune.previewStopLabel)

    let stopped = LockIsolated(false)
    await withDependencies {
      $0.audioPlayer.stop = { stopped.setValue(true) }
    } operation: {
      await model.previewToggleTapped()  // toggles to stop while previewing
    }
    #expect(stopped.value)
    #expect(!model.isPreviewingDraft)
  }

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
