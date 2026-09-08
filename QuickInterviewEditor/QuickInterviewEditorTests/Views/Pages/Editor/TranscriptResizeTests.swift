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

  /// Shift-click extends from the resized selection's canonical sample anchor, never the
  /// transcript gesture's stale pre-resize word anchor.
  @Test func selectionResizeUpdatesShiftExtendAnchor() {
    let model = editor()
    model.transcript.selectWords(anchorID: 1, focusID: 4)
    model.transcriptResizeBegan(.selection, .start)
    model.transcriptResizeDragged(toWord: 3)
    model.transcriptResizeEnded()
    expectNoDifference(model.selectedWordIDs, [3, 4])

    model.transcript.wordClicked(6, extending: true)

    expectNoDifference(model.selectedWordIDs, [3, 4, 5, 6])
    expectNoDifference(model.audioSelection, 77704..<150072)
  }

  /// Regression for Codex phase-3 P2 #1: every sibling document-mutation entry point in
  /// `EditorModel` guards on `!isExporting` (removal, crossfade, cut-suggestion edits, slice
  /// edits). A clip resize commit was missing that guard, so releasing mid-export could mutate
  /// the document while its AIFFs render from the old bounds.
  @Test func clipResizeCommitBlockedDuringExport() {
    let clipID = Fixtures.uuid(1)
    let model = editor(slices: [clip(clipID, wordIDs: [1, 2])])
    let before = model.slices

    model.transcriptResizeBegan(.clip(clipID), .end)
    model.exportPhase = .exporting(current: 0, total: 1)
    model.transcriptResizeDragged(toWord: 4)
    model.transcriptResizeEnded()

    expectNoDifference(model.slices, before)
    expectNoDifference(model.transcriptResizeDraft, nil)
  }

  /// Regression for Codex phase-3 P2 #2: cancel must restore the EXACT pre-drag `audioSelection`,
  /// not a whole-word-snapped approximation. A freeform range 60_000..<80_000 spans partially
  /// into word 1 (54772..<64474) and word 3 (77704..<98916) and fully covers word 2
  /// (70648..<74176), so it selects words [1, 2, 3] without being aligned to any word boundary.
  /// The live drag legitimately snaps the selection to whole-word bounds (product decision D1),
  /// but an ABORT must leave the user's original freeform selection untouched.
  @Test func selectionResizeCancelRestoresExactFreeformRange() {
    let model = editor()
    model.selectSourceRange(60_000..<80_000, snapPlayhead: false)
    expectNoDifference(model.selectedWordIDs, [1, 2, 3])
    let original = model.audioSelection

    model.transcriptResizeBegan(.selection, .end)
    model.transcriptResizeDragged(toWord: 5)
    expectNoDifference(model.audioSelection != original, true)

    model.transcriptResizeCancelled()
    expectNoDifference(model.audioSelection, original)
    expectNoDifference(model.transcriptResizeDraft, nil)
  }

  /// Regression for Codex phase-3 (perf-loop) P2 #1: dragging a freeform selection's edge to a word
  /// that leaves the covered word RUN unchanged must still snap the sample range to whole-word
  /// bounds (D1). The perf dedup keys on the target word only; it must not additionally skip on an
  /// unchanged run, or a freeform selection whose end already sits inside word 3 never snaps when
  /// the user drags the end handle but stays on word 3. Freeform 60_000..<80_000 covers words
  /// [1, 2, 3]; the end-drag to word 3 must snap it to sourceRange([1, 2, 3]) = 54772..<98916.
  @Test func selectionResizeSnapsFreeformRangeWhenWordRunUnchanged() {
    let model = editor()
    model.selectSourceRange(60_000..<80_000, snapPlayhead: false)
    expectNoDifference(model.selectedWordIDs, [1, 2, 3])

    model.transcriptResizeBegan(.selection, .end)
    model.transcriptResizeDragged(toWord: 3)

    expectNoDifference(model.selectedWordIDs, [1, 2, 3])
    expectNoDifference(model.audioSelection, 54772..<98916)
  }

  // MARK: - FIX A: guard `began` against a dirty slice edit or export

  private func selectWords(_ transcript: TranscriptPageModel, _ first: Int, _ last: Int) {
    transcript.transcriptDragBegan(
      atUTF16Offset: transcript.document.wordRanges[first].range.location)
    transcript.transcriptDragged(
      toUTF16Offset: transcript.document.wordRanges[last].range.location)
  }

  /// Reuses the exact `EditorFineTuneTests` setup for making `hasUncommittedSliceEdit == true`:
  /// add a real slice, open its fine-tune session, then nudge a cut point so it's dirty.
  private func makeDirtySliceEdit(_ model: EditorModel) -> Slice.ID {
    selectWords(model.transcript, 0, 3)
    model.addSliceTapped()
    let id = model.slices[0].id
    model.sliceSelected(id)
    model.cutOutNudged(byMs: 10)
    return id
  }

  /// Regression for Codex challenge P1#4: a clip resize must not be able to begin while the SAME
  /// slice has an uncommitted fine-tune draft, or the transcript resize commit and the later
  /// fine-tune Save would silently clobber each other.
  @Test func clipResizeBlockedWhileSliceEditUncommitted() {
    let model = editor()
    let clipID = makeDirtySliceEdit(model)
    expectNoDifference(model.hasUncommittedSliceEdit, true)
    let before = model.slices

    let accepted = model.transcriptResizeBegan(.clip(clipID), .end)
    expectNoDifference(accepted, false)
    expectNoDifference(model.transcriptResizeDraft, nil)

    model.transcriptResizeDragged(toWord: 4)
    model.transcriptResizeEnded()
    expectNoDifference(model.slices, before)
  }

  /// Regression for Codex challenge P2#5: `began` (not just the commit) must refuse a clip/
  /// suggestion resize during export, so a resize preview can't live-update over the audio that's
  /// currently rendering.
  @Test func clipResizeBlockedDuringExportAtBegan() {
    let clipID = Fixtures.uuid(1)
    let model = editor(slices: [clip(clipID, wordIDs: [1, 2])])
    let before = model.slices

    model.exportPhase = .exporting(current: 0, total: 1)
    let accepted = model.transcriptResizeBegan(.clip(clipID), .end)
    expectNoDifference(accepted, false)
    expectNoDifference(model.transcriptResizeDraft, nil)

    model.transcriptResizeDragged(toWord: 4)
    model.transcriptResizeEnded()
    expectNoDifference(model.slices, before)
  }

  @Test func clipResizeRejectsDraftWithMissingWordBound() {
    let clipID = Fixtures.uuid(1)
    var plan = Fixtures.editPlan()
    plan.words[3].startSample = nil
    let model = EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL,
      editPlan: plan,
      initialDocument: EditorDocumentState(slices: [clip(clipID, wordIDs: [1, 2])]))
    let before = model.slices

    expectNoDifference(model.transcriptResizeBegan(.clip(clipID), .end), true)
    model.transcriptResizeDragged(toWord: 4)
    model.transcriptResizeEnded()

    expectNoDifference(model.slices, before)
    expectNoDifference(model.transcriptResizeDraft, nil)
  }

  @Test func clipResizeRejectsDraftWithInvertedWordBound() {
    let clipID = Fixtures.uuid(1)
    var plan = Fixtures.editPlan()
    plan.words[3].startSample = 120_000
    plan.words[3].endSample = 119_000
    let model = EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL,
      editPlan: plan,
      initialDocument: EditorDocumentState(slices: [clip(clipID, wordIDs: [1, 2])]))
    let before = model.slices

    expectNoDifference(model.transcriptResizeBegan(.clip(clipID), .end), true)
    model.transcriptResizeDragged(toWord: 4)
    model.transcriptResizeEnded()

    expectNoDifference(model.slices, before)
    expectNoDifference(model.transcriptResizeDraft, nil)
  }

  // MARK: - FIX D: selection-resize cancel restores the Shift-extend anchor

  /// Regression for Codex challenge P2#8: cancel restores `audioSelection`, but the transcript's
  /// private gesture anchor (invalidated by the drag's `applyEdgeEdit`) must also be restored, or
  /// a subsequent Shift-click loses its extend pivot even though the visible selection looks
  /// unchanged. Mirrors `selectionResizeInvalidatesTranscriptShiftExtendAnchor`, inverted: cancel
  /// RESTORES the anchor instead of leaving it invalidated.
  @Test func selectionResizeCancelRestoresShiftExtendAnchor() {
    let model = editor()
    model.transcript.selectWords(anchorID: 3, focusID: 4)
    expectNoDifference(model.selectedWordIDs, [3, 4])

    model.transcriptResizeBegan(.selection, .end)
    model.transcriptResizeDragged(toWord: 6)
    model.transcriptResizeCancelled()
    expectNoDifference(model.selectedWordIDs, [3, 4])

    // A Shift-click on a word beyond the resized-then-cancelled span should extend from the
    // RESTORED anchor (word 3), not start a fresh single-word selection.
    model.transcript.wordClicked(6, extending: true)
    expectNoDifference(model.selectedWordIDs, [3, 4, 5, 6])
  }

  // MARK: - Perf: intra-word drag dedup

  /// The drag path dedups consecutive ticks that resolve to the same word (the overlay fires one per
  /// mouse-move, but resizes snap to whole words, so intra-word ticks are wasted re-renders). The
  /// dedup key must reset at `began`, or a fresh drag whose FIRST target equals the previous drag's
  /// LAST target would be silently swallowed and the resize would do nothing.
  @Test func resizeDragDedupResetsBetweenDrags() {
    let model = editor()
    model.selectWords(anchorID: 3, focusID: 4)

    model.transcriptResizeBegan(.selection, .end)
    model.transcriptResizeDragged(toWord: 5)
    expectNoDifference(model.selectedWordIDs, [3, 4, 5])
    model.transcriptResizeEnded()

    // A new drag whose first tick targets word 5 again — the same word the prior drag ended on.
    model.selectWords(anchorID: 3, focusID: 4)
    expectNoDifference(model.selectedWordIDs, [3, 4])
    model.transcriptResizeBegan(.selection, .end)
    model.transcriptResizeDragged(toWord: 5)

    // Not swallowed by stale dedup state: the resize applies.
    expectNoDifference(model.selectedWordIDs, [3, 4, 5])
  }
}
