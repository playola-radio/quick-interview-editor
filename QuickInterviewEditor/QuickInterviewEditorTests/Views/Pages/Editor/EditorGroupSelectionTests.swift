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
    expectNoDifference(model.selectedWordIDs, object.wordIDs)
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
