import CustomDump
import Dependencies
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

  private func click(
    _ model: EditorModel, word: Int = 3, count: Int = 1, extending: Bool = false, time: Double = 1
  ) {
    let offset = model.transcript.document.wordRanges.first { $0.wordID == word }!.range.location
    model.transcript.transcriptClicked(
      atUTF16Offset: offset, extending: extending, clickCount: count,
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

  @Test func clickInsideClipCollapsesFreeformToClickedWord() {
    let model = editor()
    model.slices = [Fixtures.slice(start: 70_648, end: 119_202)]
    model.selectSourceRange(78_000..<90_000, snapPlayhead: false)
    click(model)
    expectNoDifference(model.selection.freeformRange, model.sourceRange(ofWord: 3))
    #expect(model.selection.objectID == nil)
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

  @Test func clickOnWordSelectsItButTrailingSeparatorClears() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    let words = model.transcript.document.wordRanges
    let inside = words.first { $0.wordID == 3 }!.range.location
    model.transcript.transcriptClicked(atUTF16Offset: inside)
    expectNoDifference(model.selection.freeformRange, model.sourceRange(ofWord: 3))
    #expect(model.selection.objectID == nil)
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

  // New model: a drag begun on a word inside a clip selects that WORD, never the clip object.
  @Test func dragBeganInsideClipSelectsWord() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    model.transcript.transcriptDragBegan(atUTF16Offset: wordOffset(model, word: 3))
    expectNoDifference(model.selection.freeformRange, model.sourceRange(ofWord: 3))
    #expect(model.selection.objectID == nil)
  }

  // A drag across a clip paints the word range it covers, never engaging the clip.
  @Test func dragAcrossClipPaintsWordRange() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    model.transcript.transcriptDragBegan(atUTF16Offset: wordOffset(model, word: 2))
    model.transcript.transcriptDragged(toUTF16Offset: wordOffset(model, word: 4))
    let expected =
      model.sourceRange(ofWord: 2)!.lowerBound..<model.sourceRange(ofWord: 4)!.upperBound
    expectNoDifference(model.selection.freeformRange, expected)
    #expect(model.selection.objectID == nil)
  }

  // Regression: dragging an unclipped word still selects that word directly.
  @Test func dragBeganOnUnclippedWordSelectsWord() {
    let model = editor()
    model.transcript.transcriptDragBegan(atUTF16Offset: wordOffset(model, word: 3))
    expectNoDifference(model.selection.freeformRange, model.sourceRange(ofWord: 3))
  }

  // New model: a single click inside a clip selects the WORD, never the clip object.
  @Test func clickInsideClipSelectsWordNotClip() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    click(model)
    expectNoDifference(model.selection.freeformRange, model.sourceRange(ofWord: 3))
    #expect(model.selection.objectID == nil)
    expectNoDifference(model.editSlice, nil)
    expectNoDifference(model.sidebarReveal, nil)
  }

  // New model: clicking a word covered by stacked clips selects the word and never opens the
  // overlap chooser (stacked disambiguation is deferred to visual layering, not hit-test logic).
  @Test func clickInsideStackedClipsSelectsWordWithoutChooser() {
    let model = editor()
    let first = Fixtures.slice(id: Fixtures.uuid(1), start: 70_648, end: 119_202)
    let second = Fixtures.slice(id: Fixtures.uuid(2), start: 70_648, end: 119_202)
    model.slices = [first, second]
    click(model)
    expectNoDifference(model.selection.freeformRange, model.sourceRange(ofWord: 3))
    #expect(model.selection.objectID == nil)
    #expect(model.transcript.overlap.candidates.isEmpty)
  }

  // New model: double-clicking a word inside a clip opens THAT clip's editor, not a freeform draft.
  @Test func doubleClickOnWordInsideClipOpensThatClip() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    click(model)
    click(model, count: 2, time: 1.1)
    expectNoDifference(model.editSlice?.sliceID, clip.id)
    #expect(model.editSlice?.target == .savedClip(clip.id))
  }

  // A Shift-click extends the selection; it must not prime the double-click-open capture, so a
  // plain click on the same word within the interval does NOT open the covering clip.
  @Test func shiftClickDoesNotPrimeDoubleClickOpen() {
    let model = editor()
    let clip = Fixtures.slice(start: 70_648, end: 119_202)
    model.slices = [clip]
    click(model, extending: true)
    click(model, count: 2, time: 1.1)
    #expect(model.editSlice == nil)
  }

  // Stacked clips: double-click opens the foreground (first) covering clip deterministically.
  @Test func doubleClickInsideStackedClipsOpensForegroundClip() {
    let model = editor()
    let first = Fixtures.slice(id: Fixtures.uuid(1), start: 70_648, end: 119_202)
    let second = Fixtures.slice(id: Fixtures.uuid(2), start: 70_648, end: 119_202)
    model.slices = [first, second]
    click(model)
    click(model, count: 2, time: 1.1)
    expectNoDifference(model.editSlice?.sliceID, first.id)
  }

  // A word covered by a pending suggestion opens that suggestion's draft on double-click, matching
  // the pre-gate behavior — not a one-word freeform draft.
  @Test func doubleClickOnSuggestionOpensSuggestionDraft() {
    let model = editor()
    let candidate = suggestion(model)
    model.documentCutSuggestions = [candidate]
    model.cutSuggestions.showsSuggestionBands = true
    click(model)
    click(model, count: 2, time: 1.1)
    expectNoDifference(model.editSlice?.target, .suggestionDraft(candidate))
  }

  // A word covered by no clip falls back to a freeform draft on double-click.
  @Test func doubleClickOnUnclippedWordOpensFreeformDraft() {
    withDependencies {
      $0.uuid = .incrementing
    } operation: {
      let model = editor()
      click(model)
      click(model, count: 2, time: 1.1)
      #expect(model.editSlice?.target.isDraft == true)
      #expect(model.editSlice?.target != .savedClip(Fixtures.uuid(1)))
    }
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
