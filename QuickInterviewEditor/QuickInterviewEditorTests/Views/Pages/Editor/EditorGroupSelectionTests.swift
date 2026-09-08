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
