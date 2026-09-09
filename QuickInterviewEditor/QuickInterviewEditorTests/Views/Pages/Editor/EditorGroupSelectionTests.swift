import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorGroupSelectionTests {
  private func editor() -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: Fixtures.editPlan(),
      sourceFingerprint: "fp")
  }

  private func suggestion(_ model: EditorModel, id: UUID = Fixtures.uuid(2)) -> CutSuggestion {
    var value = Fixtures.cutSuggestion(id: id, wordIDs: [2, 3, 4])
    value.provenance.transcriptHash = model.editPlan.transcriptHash
    return value
  }

  private func click(_ model: EditorModel, word: Int = 3, count: Int = 1, time: Double = 1) {
    let offset = model.transcript.document.wordRanges.first { $0.wordID == word }!.range.location
    model.transcript.transcriptClicked(
      atUTF16Offset: offset, clickCount: count,
      timestamp: time, doubleClickInterval: 0.5)
  }

  @Test func deletingSuggestionRespectsSearchLock() async {
    let model = editor()
    let candidate = suggestion(model)
    model.documentCutSuggestions = [candidate]
    model.selectTranscriptObject(.suggestion(candidate.id))
    model.cutSuggestions.run.phase = .needsNumbering(runID: Fixtures.uuid(8), message: "Review")
    let before = model.documentState
    await model.deleteSelectionTapped()
    expectNoDifference(model.documentState, before)
    expectNoDifference(model.selection, .object(.suggestion(candidate.id)))
    #expect(!model.canUndo)
  }

  @Test func externalRangeChangeReordersRetainedOverlapCandidates() {
    let model = editor()
    let first = Fixtures.slice(id: Fixtures.uuid(1), start: 70_648, end: 119_202)
    let second = Fixtures.slice(id: Fixtures.uuid(2), start: 70_648, end: 119_202)
    model.slices = [first, second]
    model.selectTranscriptObject(.clip(second.id))
    click(model)
    expectNoDifference(model.transcript.overlap.candidates.first?.id, .clip(second.id))
    model.selectSourceRange(70_648..<119_202, snapPlayhead: false)
    expectNoDifference(
      model.transcript.overlap.candidates.map(\.id), [.clip(first.id), .clip(second.id)])
  }

  @Test func acceptingSelectedSuggestionPromotesIdentityAndUndoRestoresPendingSelection() async {
    let model = editor()
    let candidate = suggestion(model)
    model.documentCutSuggestions = [candidate]
    model.selectTranscriptObject(.suggestion(candidate.id))
    model.acceptSelectedSuggestionTapped()
    expectNoDifference(model.selection, .object(.clip(candidate.id)))
    #expect(model.documentCutSuggestions[id: candidate.id]?.isAccepted == true)
    let reveal = model.sidebarReveal?.token
    await model.undoTapped()
    expectNoDifference(model.selection, .object(.suggestion(candidate.id)))
    #expect(model.documentCutSuggestions[id: candidate.id]?.isPending == true)
    #expect(model.sidebarReveal?.token != reveal)
    await model.redoTapped()
    expectNoDifference(model.selection, .object(.clip(candidate.id)))
    await model.deleteSelectionTapped()
    #expect(model.documentCutSuggestions[id: candidate.id]?.isAccepted == true)
    #expect(model.visibleTranscriptObjects.isEmpty)
  }

  @Test func historicalAcceptedRowUsesExistingClipThenFreeformAfterDeletion() async {
    let model = editor()
    var candidate = suggestion(model)
    candidate.status = .accepted
    let clip = Fixtures.slice(id: candidate.id, start: 78_000, end: 110_000)
    model.documentCutSuggestions = [candidate]
    model.slices = [clip]
    model.cutSuggestionSelected(candidate)
    expectNoDifference(model.selection, .object(.clip(clip.id)))
    expectNoDifference(model.audioSelection, 78_000..<110_000)
    await model.deleteSelectionTapped()
    model.cutSuggestionSelected(candidate)
    expectNoDifference(model.audioSelection, 70_648..<119_202)
    #expect(model.selection.freeformRange != nil)
    #expect(model.slices.isEmpty)
  }

  @Test func independentEditorsDoNotShareSelectionOrHistory() async {
    let first = editor()
    let second = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    first.slices = [clip]
    second.slices = [clip]
    first.selectTranscriptObject(.clip(clip.id))
    await first.deleteSelectionTapped()
    #expect(second.slices.count == 1)
    #expect(second.selection == .none)
    #expect(!second.canUndo)
    await first.undoTapped()
    expectNoDifference(first.selection, .object(.clip(clip.id)))
    #expect(second.selection == .none)
  }

  @Test func hidingBandsRemovesSuggestionFromOpenChooser() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    model.documentCutSuggestions = [suggestion(model)]
    click(model)
    model.transcript.overlap.present()
    #expect(model.transcript.overlap.candidates.count == 2)
    model.cutSuggestions.showsSuggestionBands = false
    expectNoDifference(model.transcript.overlap.candidates.map(\.id), [.clip(clip.id)])
    #expect(!model.transcript.overlap.isPresented)
  }

  @Test func freeformAndClearRemoveSidebarSelectedRing() {
    let model = editor()
    let candidate = suggestion(model)
    model.documentCutSuggestions = [candidate]
    model.selectTranscriptObject(.suggestion(candidate.id))
    expectNoDifference(model.cutSuggestions.selectedObjectID, .suggestion(candidate.id))
    model.selectSourceRange(70_648..<119_202, snapPlayhead: false)
    #expect(model.cutSuggestions.selectedObjectID == nil)
    model.selectTranscriptObject(.suggestion(candidate.id))
    model.clearSelection()
    #expect(model.cutSuggestions.selectedObjectID == nil)
  }

  @Test func chooserSelectsHiddenClipThenDoubleClickOpensIt() {
    let model = editor()
    let first = Fixtures.slice(id: Fixtures.uuid(1), start: 70_648, end: 119_202)
    let second = Fixtures.slice(id: Fixtures.uuid(2), start: 70_648, end: 119_202)
    model.slices = [first, second]
    click(model)
    expectNoDifference(
      model.transcript.overlap.candidates.map(\.id), [.clip(first.id), .clip(second.id)])
    model.transcript.overlap.present()
    model.transcript.overlap.preview(.clip(second.id))
    expectNoDifference(model.selection, .object(.clip(first.id)))
    expectNoDifference(model.visibleTranscriptObjects.first?.id, .clip(first.id))
    #expect(model.clipBands.last?.isPreviewed == true)
    model.transcript.overlap.choose(.clip(second.id))
    click(model, time: 2)
    click(model, count: 2, time: 2.1)
    expectNoDifference(model.editSlice?.sliceID, second.id)
  }

  @Test func sidebarUnhidesFiltersAndSuggestionsPreservingBothPanel() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    model.sliceFilter = .complete
    model.rightPanelTab = .both
    model.sliceRevealTapped(clip.id)
    expectNoDifference(model.sliceFilter, .all)
    expectNoDifference(model.rightPanelTab, .both)
    #expect(model.sliceRows.first?.isActive == true)
    let candidate = suggestion(model)
    model.documentCutSuggestions = [candidate]
    model.cutSuggestions.showsSuggestionBands = false
    model.cutSuggestionSelected(candidate)
    expectNoDifference(model.selection, .object(.suggestion(candidate.id)))
    #expect(model.cutSuggestions.showsSuggestionBands)
    expectNoDifference(model.rightPanelTab, .both)
  }

  @Test func deletingCandidateReconcilesChooserWithoutStalePreview() {
    let model = editor()
    let first = Fixtures.slice(id: Fixtures.uuid(1), start: 70_648, end: 119_202)
    let second = Fixtures.slice(id: Fixtures.uuid(2), start: 70_648, end: 119_202)
    model.slices = [first, second]
    click(model)
    model.transcript.overlap.present()
    model.transcript.overlap.preview(.clip(second.id))
    model.mutateDocument { $0.slices.remove(id: second.id) }
    #expect(!model.transcript.overlap.showsControl)
    #expect(model.transcript.overlap.previewID == nil)
    expectNoDifference(model.selection, .object(.clip(first.id)))
  }

  @Test func clickSelectsWholeClipAndRepeatedClickPreservesIt() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    click(model)
    expectNoDifference(model.selection, .object(.clip(clip.id)))
    let firstReveal = model.sidebarReveal?.token
    click(model, time: 2)
    expectNoDifference(model.selection, .object(.clip(clip.id)))
    #expect(model.sidebarReveal?.token != firstReveal)
    expectNoDifference(model.editSlice, nil)
  }

  @Test func explicitlyChosenLowerClipKeepsOverlapAndDoubleClickOpensIt() {
    let model = editor()
    let first = Fixtures.slice(id: Fixtures.uuid(1), start: 70_648, end: 119_202)
    let second = Fixtures.slice(id: Fixtures.uuid(2), start: 70_648, end: 119_202)
    model.slices = [first, second]
    model.selectTranscriptObject(.clip(second.id))
    click(model)
    click(model, count: 2, time: 1.1)
    expectNoDifference(model.selection, .object(.clip(second.id)))
    expectNoDifference(model.editSlice?.sliceID, second.id)
  }

  @Test func freeformHighlightWinsClickInsideOverlappingClip() {
    let model = editor()
    model.slices = [Fixtures.slice(start: 70_648, end: 119_202)]
    model.selectSourceRange(78_000..<90_000, snapPlayhead: false)
    let selected = model.selection
    click(model)
    expectNoDifference(model.selection, selected)
    expectNoDifference(model.sidebarReveal, nil)
  }

  @Test func secondClickAfterBoundsChangeDoesNotOpenReplacementRange() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    click(model)
    model.mutateDocument { $0.slices[id: clip.id]?.endSample = 130_000 }
    click(model, count: 2, time: 1.1)
    expectNoDifference(model.editSlice, nil)
  }

  @Test func interveningDragCancelsCapturedDoubleClick() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    click(model)
    let offset = model.transcript.document.wordRanges.first { $0.wordID == 3 }!.range.location
    model.transcript.transcriptDragBegan(atUTF16Offset: offset)
    model.selectTranscriptObject(.clip(clip.id))
    click(model, count: 2, time: 1.1)
    expectNoDifference(model.editSlice, nil)
  }

  @Test func hiddenSuggestionIsNotAClickTargetAndFullOverlapsRemainVisible() {
    let model = editor()
    let candidate = suggestion(model)
    model.documentCutSuggestions = [candidate]
    model.cutSuggestions.showsSuggestionBands = false
    click(model)
    #expect(model.selection.freeformRange != nil)
    model.clearSelection()
    model.cutSuggestions.showsSuggestionBands = true
    model.slices = [Fixtures.slice(start: 70_648, end: 119_202)]
    expectNoDifference(model.clipBands.count, 2)
    expectNoDifference(model.clipBands.last?.wordIDs, [2, 3, 4])
  }

  @Test func interiorSpaceSelectsGroupButTrailingSpaceDoesNot() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    let words = model.transcript.document.wordRanges
    let interior = NSMaxRange(words.first { $0.wordID == 2 }!.range)
    model.transcript.transcriptClicked(atUTF16Offset: interior)
    expectNoDifference(model.selection, .object(.clip(clip.id)))
    let trailing = NSMaxRange(words.first { $0.wordID == 4 }!.range)
    model.transcript.transcriptClicked(atUTF16Offset: trailing)
    expectNoDifference(model.selection, .none)
  }

  @Test func clipSelectionUsesActualPaddedBoundsAndOverlappingEdgeWord() throws {
    let model = editor()
    let clip = Fixtures.slice(start: 72_000, end: 120_000)
    model.slices = [clip]

    expectDifference(model.selection) {
      model.selectTranscriptObject(.clip(clip.id))
    } changes: {
      $0 = .object(.clip(clip.id))
    }

    expectNoDifference(model.audioSelection, 72_000..<120_000)
    expectNoDifference(model.selectedSourceRange, 72_000..<120_000)
    expectNoDifference(model.selectionAnchorSample, 72_000)
    let object = try #require(model.transcriptObjects.first)
    expectNoDifference(object.wordIDs, [2, 3, 4])
    expectNoDifference(object.name, clip.name)
    expectNoDifference(model.sidebarReveal?.objectID, .clip(clip.id))
    expectNoDifference(model.rightPanelTab, .slices)
  }

  @Test func objectBoundsResolveLiveAfterDocumentChange() {
    let model = editor()
    model.slices = [Fixtures.slice(start: 72_000, end: 120_000)]
    model.selectTranscriptObject(.clip(Fixtures.uuid(1)))
    model.slices[id: Fixtures.uuid(1)]?.startSample = 70_000
    expectNoDifference(model.selectedSourceRange, 70_000..<120_000)
    expectNoDifference(model.selectionAnchorSample, 70_000)
  }

  @Test func deletedObjectIdentityHasNoStaleRangeProjection() {
    let model = editor()
    model.slices = [Fixtures.slice(start: 72_000, end: 120_000)]
    model.selectTranscriptObject(.clip(Fixtures.uuid(1)))
    model.slices.removeAll()
    expectNoDifference(model.selectedSourceRange, nil)
    expectNoDifference(model.selectionAnchorSample, nil)
    expectNoDifference(model.selectedWordIDs, [])
  }

  @Test func suggestionWithInvalidWordBoundsIsNotPartiallyProjected() {
    var plan = Fixtures.editPlan()
    plan.words[3].startSample = nil
    let model = EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan, sourceFingerprint: "fp")
    model.documentCutSuggestions = [suggestion(model)]
    expectNoDifference(model.transcriptObjects, [])
  }

  @Test func unknownObjectDoesNotChangeSelectionOrReveal() {
    let model = editor()
    model.selectSourceRange(70_000..<120_000, snapPlayhead: false)
    let selection = model.selection
    model.selectTranscriptObject(.clip(Fixtures.uuid(99)))
    expectNoDifference(model.selection, selection)
    expectNoDifference(model.sidebarReveal, nil)
  }

  @Test func objectSelectionSurvivesSessionSyncWithoutPendingDraft() {
    let model = editor()
    model.slices = [Fixtures.slice(start: 72_000, end: 120_000)]
    model.selectSourceRange(70_000..<110_000, snapPlayhead: false)
    model.syncEditSession()
    model.selectTranscriptObject(.clip(Fixtures.uuid(1)))
    model.syncEditSession()
    expectNoDifference(model.selection, .object(.clip(Fixtures.uuid(1))))
    expectNoDifference(model.fineTuneSessionKey.selection, nil)
    expectNoDifference(model.fineTuneTarget, nil)
    expectNoDifference(model.fineTune.target, nil)
  }

  @Test func objectSelectionPreservesExistingSavedEditOwnership() {
    let model = editor()
    model.slices = [
      Fixtures.slice(id: Fixtures.uuid(1), start: 72_000, end: 120_000),
      Fixtures.slice(id: Fixtures.uuid(2), start: 130_000, end: 150_000),
    ]
    model.activeSliceID = Fixtures.uuid(1)
    model.syncEditSession()
    model.selectTranscriptObject(.clip(Fixtures.uuid(2)))
    model.syncEditSession()
    expectNoDifference(model.fineTune.target, .slice(Fixtures.uuid(1)))
    expectNoDifference(model.fineTune.committedRange, 72_000..<120_000)
    expectNoDifference(model.selection, .object(.clip(Fixtures.uuid(2))))
  }

  @Test func matchingClipAndSuggestionUUIDRemainDistinctAndKeepColors() {
    let model = editor()
    let id = Fixtures.uuid(1)
    model.slices = [Fixtures.slice(id: id, start: 72_000, end: 120_000)]
    model.documentCutSuggestions = [suggestion(model, id: id)]
    let objects = model.transcriptObjects
    expectNoDifference(objects.map(\.id), [.clip(id), .suggestion(id)])
    expectNoDifference(objects.map(\.colorIndex), [0, 1])
    model.selectTranscriptObject(.suggestion(id))
    expectNoDifference(model.selection.objectID, .suggestion(id))
    expectNoDifference(model.selectedSourceRange, 70_648..<119_202)
    expectNoDifference(model.sidebarReveal?.objectID, .suggestion(id))
    expectNoDifference(model.rightPanelTab, .suggestions)
    expectNoDifference(model.transcriptObjects, objects)
  }

  @Test func repeatedSelectionRequestsAnotherSidebarReveal() throws {
    let model = editor()
    model.slices = [Fixtures.slice(start: 72_000, end: 120_000)]
    model.selectTranscriptObject(.clip(Fixtures.uuid(1)))
    let first = try #require(model.sidebarReveal)
    model.selectTranscriptObject(.clip(Fixtures.uuid(1)))
    expectNoDifference(model.selection, .object(.clip(Fixtures.uuid(1))))
    #expect(model.sidebarReveal?.token != first.token)
  }

  @Test func objectSelectionInvalidatesPreviousTranscriptAnchor() {
    let model = editor()
    model.slices = [Fixtures.slice(start: 100_000, end: 120_000)]
    model.transcript.wordClicked(2, extending: false)
    model.selectTranscriptObject(.clip(Fixtures.uuid(1)))
    model.transcript.wordClicked(2, extending: false)
    expectNoDifference(model.selection.freeformRange, 70_648..<74_176)
  }

  @Test func suggestionWithAnyMissingWordDoesNotSilentlyNarrow() {
    let model = editor()
    var candidate = suggestion(model)
    candidate.wordIDs = [2, 3, 999_999]
    model.documentCutSuggestions = [candidate]
    model.selectTranscriptObject(.suggestion(candidate.id))
    expectNoDifference(model.transcriptObjects, [])
    expectNoDifference(model.selection, .none)
  }

  @Test func suggestionHitMembershipIncludesPartiallyOverlappingNeighbor() throws {
    var plan = Fixtures.editPlan()
    let neighbor = try #require(plan.words.firstIndex { $0.id == 5 })
    plan.words[neighbor].startSample = 118_000
    let model = EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan, sourceFingerprint: "fp")
    model.documentCutSuggestions = [suggestion(model)]
    model.selectTranscriptObject(.suggestion(Fixtures.uuid(2)))
    let object = try #require(model.selectedTranscriptObject)
    expectNoDifference(object.wordIDs, [2, 3, 4, 5])
    expectNoDifference(model.selectedWordIDs, [])
    expectNoDifference(Set(model.clipBands.first?.wordIDs ?? []), object.wordIDs)
    expectNoDifference(
      objectsCovering(5, objects: model.transcriptObjects, selected: object.id), [object])
  }

  @Test func staleAndCompletedSuggestionsAreNotSelectableObjects() {
    let model = editor()
    var stale = suggestion(model)
    stale.provenance.sourceFingerprint = "another source"
    var completed = suggestion(model, id: Fixtures.uuid(3))
    completed.status = .accepted
    var changedTranscript = suggestion(model, id: Fixtures.uuid(4))
    changedTranscript.provenance.transcriptHash = "another transcript"
    model.documentCutSuggestions = [stale, completed, changedTranscript]
    expectNoDifference(model.transcriptObjects, [])
  }

  private func wordOffset(_ model: EditorModel, word: Int) -> Int {
    model.transcript.document.wordRanges.first { $0.wordID == word }!.range.location
  }

  // Two-step: a drag over a clip the user has not engaged selects the clip first.
  @Test func dragBeganOnUnselectedClipWordSelectsClip() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    model.transcript.transcriptDragBegan(atUTF16Offset: wordOffset(model, word: 3))
    expectNoDifference(model.selection, .object(.clip(clip.id)))
  }

  // Selecting the clip invalidates the drag anchor, so continuing the drag paints nothing.
  @Test func dragOverUnselectedClipDoesNotPaintFreeform() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    model.transcript.transcriptDragBegan(atUTF16Offset: wordOffset(model, word: 2))
    model.transcript.transcriptDragged(toUTF16Offset: wordOffset(model, word: 4))
    expectNoDifference(model.selection, .object(.clip(clip.id)))
  }

  // Once the clip is engaged, a drag inside it selects that word (freeform range).
  @Test func dragBeganInsideEngagedClipSelectsWord() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    model.selectTranscriptObject(.clip(clip.id))
    model.transcript.transcriptDragBegan(atUTF16Offset: wordOffset(model, word: 3))
    expectNoDifference(model.selection.freeformRange, model.sourceRange(ofWord: 3))
  }

  // A drag across the engaged clip paints the word range it covers.
  @Test func dragAcrossEngagedClipPaintsWordRange() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    model.selectTranscriptObject(.clip(clip.id))
    model.transcript.transcriptDragBegan(atUTF16Offset: wordOffset(model, word: 2))
    model.transcript.transcriptDragged(toUTF16Offset: wordOffset(model, word: 4))
    let expected =
      model.sourceRange(ofWord: 2)!.lowerBound..<model.sourceRange(ofWord: 4)!.upperBound
    expectNoDifference(model.selection.freeformRange, expected)
  }

  // Regression: dragging an unclipped word still selects that word directly.
  @Test func dragBeganOnUnclippedWordSelectsWord() {
    let model = editor()
    model.transcript.transcriptDragBegan(atUTF16Offset: wordOffset(model, word: 3))
    expectNoDifference(model.selection.freeformRange, model.sourceRange(ofWord: 3))
  }

  @Test func rangeAndSeamFacadesReplaceObjectSelection() {
    let model = editor()
    model.slices = [Fixtures.slice(start: 72_000, end: 120_000)]
    model.selectTranscriptObject(.clip(Fixtures.uuid(1)))
    model.audioSelection = 80_000..<90_000
    expectNoDifference(model.selection, .range(80_000..<90_000, anchor: 72_000))
    model.selectedSeamID = Fixtures.uuid(2)
    expectNoDifference(model.selection, .seam(Fixtures.uuid(2)))
    expectNoDifference(model.audioSelection, nil)
    expectNoDifference(model.selectionAnchorSample, nil)
  }
}
