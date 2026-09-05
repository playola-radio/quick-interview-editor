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
    #expect(seen.count >= 1)

    // The status flip is the last-recorded change, so a single undo reverts the acceptance.
    await model.undoTapped()
    expectNoDifference(model.documentCutSuggestions[id: suggestion.id]?.status, .pending)
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
