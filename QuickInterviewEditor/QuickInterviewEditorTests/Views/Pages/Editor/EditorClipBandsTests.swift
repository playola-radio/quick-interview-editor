import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorClipBandsTests {

  private func slice(_ id: UUID, wordIDs: [Word.ID]) -> Slice {
    let words = Fixtures.editPlan().words.filter { wordIDs.contains($0.id) }
    return Slice(
      id: id, name: "A story", startSample: words.compactMap(\.startSample).min()!,
      endSample: words.compactMap(\.endSample).max()!,
      wordIDs: wordIDs, snippet: "a story")
  }

  /// Builds an editor seeded with the given cut suggestions via its initial document. PR 2 made
  /// the editor's document the source of truth for bands; persistence flows out through the tab's
  /// sidecar bridge, so these band tests need no file storage at all.
  private func withEditor(
    suggestions: [CutSuggestion], _ body: (EditorModel) -> Void
  ) {
    let plan = Fixtures.editPlan()
    var suggestions = suggestions
    for index in suggestions.indices {
      suggestions[index].provenance.transcriptHash = plan.transcriptHash
    }
    let model = EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan, sourceFingerprint: "fp",
      initialDocument: EditorDocumentState(
        cutSuggestions: IdentifiedArray(uniqueElements: suggestions)))
    body(model)
  }

  @Test func noSlicesOrSuggestionsProducesNoBands() {
    withEditor(suggestions: []) { model in
      expectNoDifference(model.clipBands, [])
    }
  }

  @Test func slicesBecomeApprovedBands() {
    withEditor(suggestions: []) { model in
      model.slices = [slice(Fixtures.uuid(1), wordIDs: [10, 11, 12])]
      expectNoDifference(
        model.clipBands,
        [
          TranscriptClipBand(
            id: Fixtures.uuid(1), wordIDs: [10, 11, 12], kind: .approved, colorIndex: 0)
        ])
    }
  }

  @Test func onlyPendingSuggestionsBecomeAmberBands() {
    let pending = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [1, 2], status: .pending)
    let accepted = Fixtures.cutSuggestion(id: Fixtures.uuid(2), wordIDs: [3, 4], status: .accepted)
    let rejected = Fixtures.cutSuggestion(id: Fixtures.uuid(3), wordIDs: [5, 6], status: .rejected)
    withEditor(suggestions: [pending, accepted, rejected]) { model in
      // Accepted and rejected suggestions are not drawn as amber — only the pending one.
      expectNoDifference(
        model.clipBands,
        [
          TranscriptClipBand(
            id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .suggested, colorIndex: 0)
        ])
    }
  }

  @Test func approvedComesBeforeSuggested() {
    let pending = Fixtures.cutSuggestion(id: Fixtures.uuid(9), wordIDs: [7, 8], status: .pending)
    withEditor(suggestions: [pending]) { model in
      model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2])]
      expectNoDifference(
        model.clipBands,
        [
          TranscriptClipBand(
            id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .approved, colorIndex: 0),
          TranscriptClipBand(
            id: Fixtures.uuid(9), wordIDs: [7, 8], kind: .suggested, colorIndex: 1),
        ])
    }
  }

  /// Overlaps keep complete geometry so a lower group remains a selectable candidate.
  @Test func overlappingSuggestionKeepsItsFullBand() {
    let pending = Fixtures.cutSuggestion(
      id: Fixtures.uuid(9), wordIDs: [2, 3, 4], status: .pending)
    withEditor(suggestions: [pending]) { model in
      model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2, 3])]
      expectNoDifference(
        model.clipBands,
        [
          TranscriptClipBand(
            id: Fixtures.uuid(1), wordIDs: [1, 2, 3], kind: .approved, colorIndex: 0),
          // All suggestion words remain even under the saved clip.
          TranscriptClipBand(
            id: Fixtures.uuid(9), wordIDs: [2, 3, 4], kind: .suggested, colorIndex: 1),
        ])
    }
  }

  /// Hiding suggestions (the panel toggle) drops the suggested bands but leaves accepted slices.
  @Test func hidingSuggestionsDropsSuggestedBandsButKeepsSlices() {
    let pending = Fixtures.cutSuggestion(id: Fixtures.uuid(9), wordIDs: [7, 8], status: .pending)
    withEditor(suggestions: [pending]) { model in
      model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2])]
      model.cutSuggestions.showsSuggestionBands = false
      expectNoDifference(
        model.clipBands,
        [TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .approved, colorIndex: 0)])
    }
  }

  @Test func suggestionFullyCoveredBySlicesStillHasItsOwnBand() {
    let pending = Fixtures.cutSuggestion(id: Fixtures.uuid(9), wordIDs: [1, 2], status: .pending)
    withEditor(suggestions: [pending]) { model in
      model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2, 3])]
      expectNoDifference(
        model.clipBands,
        [
          TranscriptClipBand(
            id: Fixtures.uuid(1), wordIDs: [1, 2, 3], kind: .approved, colorIndex: 0),
          TranscriptClipBand(
            id: Fixtures.uuid(9), wordIDs: [1, 2], kind: .suggested, colorIndex: 1),
        ])
    }
  }
}
