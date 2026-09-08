import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

/// The editor side of the cut-suggestion boundary (PR 2): the child panel emits intents and
/// `EditorModel` funnels them through `mutateDocument`, so accept/reject are undoable and every
/// change dirties, while a background analysis pass stores candidates without touching undo.
@MainActor
struct EditorSuggestionFlowTests {

  private let fingerprint = "fp-flow"

  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan,
      sourceFingerprint: fingerprint)
  }

  /// A suggestion stamped so the accept-time staleness gate treats it as fresh for this editor.
  private func freshSuggestion(_ id: UUID, plan: EditPlan) -> CutSuggestion {
    var suggestion = Fixtures.cutSuggestion(id: id, wordIDs: [10, 11, 12, 13, 14, 15, 16])
    suggestion.provenance = CutSuggestion.Provenance(
      model: "claude-sonnet-5", promptVersion: "v2", productSpecVersion: "v1",
      transcriptHash: plan.transcriptHash, sourceFingerprint: fingerprint, diarizationHash: nil)
    return suggestion
  }

  @Test func backgroundPassStoresSuggestionsAndDirtiesButLeavesCanUndoFalse() {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    let first = freshSuggestion(Fixtures.uuid(1), plan: plan)
    let second = freshSuggestion(Fixtures.uuid(2), plan: plan)
    model.cutSuggestions.onSuggestionsProduced?([first, second])

    expectNoDifference(model.documentCutSuggestions.count, 2)
    expectNoDifference(seen.count, 1)
    #expect(!model.canUndo)
  }

  @Test func acceptingASuggestionLandsASliceFlipsStatusIsUndoableAndFires() async {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.cutSuggestions.onSuggestionsProduced?([suggestion])
    #expect(!model.canUndo)

    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    model.cutSuggestions.acceptTapped(suggestion.id)

    expectNoDifference(model.slices[id: suggestion.id]?.wordIDs, [10, 11, 12, 13, 14, 15, 16])
    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.status, .accepted)
    #expect(model.canUndo)
    // Accept lands the slice AND the status flip in ONE transaction — one callback, one entry.
    expectNoDifference(seen.count, 1)

    // A single undo reverts the WHOLE acceptance: the slice goes and the status returns to
    // pending together, so the transcript is never left with a half-accepted suggestion.
    await model.undoTapped()
    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.status, .pending)
    #expect(model.slices[id: suggestion.id] == nil)
  }

  @Test func suggestionsProducedAfterAnEditSurviveUndoAndRedoOfThatEdit() async {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    // An undoable edit lands FIRST, while no suggestions exist — so its undo snapshot predates
    // them. This is the ordering the old sidecar could never break, since suggestions lived
    // outside undo entirely.
    model.mutateDocument { $0.slices.append(Fixtures.slice(id: Fixtures.uuid(9))) }

    // Then a background pass stores suggestions non-undoably.
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.cutSuggestions.onSuggestionsProduced?([suggestion])
    expectNoDifference(model.documentCutSuggestions.count, 1)

    // Undoing the slice must NOT rewind to the pre-suggestion snapshot and erase them.
    await model.undoTapped()
    expectNoDifference(model.slices.count, 0)
    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.id, suggestion.id)

    // Redo restores the slice and still keeps the suggestions.
    await model.redoTapped()
    expectNoDifference(model.slices.count, 1)
    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.id, suggestion.id)
  }

  @Test func rejectingASuggestionFlipsStatusAndIsUndoable() async {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.cutSuggestions.onSuggestionsProduced?([suggestion])

    model.cutSuggestions.rejectTapped(suggestion.id)

    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.status, .rejected)
    #expect(model.canUndo)

    await model.undoTapped()
    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.status, .pending)
  }

  @Test func editingASuggestionTitleCoalescesTypingIntoOneUndoableAction() async {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.cutSuggestions.onSuggestionsProduced?([suggestion])

    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    model.cutSuggestions.titleFocusChanged(suggestion.id, isFocused: true)
    model.cutSuggestions.titleChanged(suggestion.id, to: "R")
    model.cutSuggestions.titleChanged(suggestion.id, to: "Renamed")
    model.cutSuggestions.titleChanged(suggestion.id, to: "Renamed cut")

    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.title, "Renamed cut")
    expectNoDifference(seen.count, 3)
    expectNoDifference(model.history.undo.count, 0)
    #expect(!model.canUndo)

    model.cutSuggestions.titleFocusChanged(suggestion.id, isFocused: false)

    expectNoDifference(model.history.undo.count, 1)
    #expect(model.canUndo)

    await model.undoTapped()
    expectNoDifference(
      model.documentCutSuggestions[id: suggestion.id]?.title, suggestion.title)
  }

  @Test func acceptingAfterEditingTheTitleNamesTheSliceFromTheEditedTitle() {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.cutSuggestions.onSuggestionsProduced?([suggestion])

    model.cutSuggestions.titleFocusChanged(suggestion.id, isFocused: true)
    model.cutSuggestions.titleChanged(suggestion.id, to: "My custom")
    model.cutSuggestions.titleChanged(suggestion.id, to: "My custom clip name")
    model.cutSuggestions.acceptTapped(suggestion.id)

    expectNoDifference(model.slices[id: suggestion.id]?.name, "My custom clip name")
    expectNoDifference(model.history.undo.count, 2)
  }

  @Test func speakerOverridesFlowThroughTheDocumentAndAreUndoable() async {
    let model = editor()
    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    model.cutSuggestions.onSpeakerOverridesChanged?(2, ["0": "Host"])

    expectNoDifference(model.documentState.speakerCountOverride, 2)
    expectNoDifference(model.documentState.speakerDisplayNames, ["0": "Host"])
    expectNoDifference(seen.count, 1)
    #expect(model.canUndo)

    await model.undoTapped()
    expectNoDifference(model.documentState.speakerCountOverride, nil)
    expectNoDifference(model.documentState.speakerDisplayNames, [:])
  }

  @Test func pendingSuggestionsSurfaceAsTranscriptClipBands() {
    let plan = Fixtures.editPlan()
    let model = editor(plan)
    let suggestion = freshSuggestion(Fixtures.uuid(1), plan: plan)
    model.cutSuggestions.onSuggestionsProduced?([suggestion])

    let suggestedBands = model.clipBands.filter { $0.kind == .suggested }
    expectNoDifference(suggestedBands.map(\.id), [suggestion.id])
  }
}
