import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorClipBandsTests {

  @Test func typeFilterKeepsListAndBandsTogetherWithoutDocumentMutation() {
    var intro = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [7, 8])
    intro.productType = .intro
    var spotlight = Fixtures.cutSuggestion(id: Fixtures.uuid(2), wordIDs: [9, 10])
    spotlight.productType = .spotlight
    withEditor(suggestions: [intro, spotlight]) { model in
      model.slices = [slice(Fixtures.uuid(3), wordIDs: [1, 2])]
      let before = model.documentState
      model.cutSuggestions.typeFilterTapped("intro")
      expectNoDifference(model.cutSuggestions.suggestions.map(\.id), [spotlight.id])
      expectNoDifference(model.clipBands.map(\.id), [Fixtures.uuid(3), spotlight.id])
      expectNoDifference(model.documentState, before)
      #expect(!model.canUndo)
    }
  }

  private func slice(_ id: UUID, wordIDs: [Word.ID]) -> Slice {
    Slice(
      id: id, name: "A story", startSample: 0, endSample: 100,
      wordIDs: wordIDs, snippet: "a story")
  }

  /// Builds an editor seeded with the given cut suggestions via its initial document. PR 2 made
  /// the editor's document the source of truth for bands; persistence flows out through the tab's
  /// sidecar bridge, so these band tests need no file storage at all.
  private func withEditor(
    suggestions: [CutSuggestion], _ body: (EditorModel) -> Void
  ) {
    let model = EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: Fixtures.editPlan(),
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
        [TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [10, 11, 12], kind: .approved)])
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
        [TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .suggested)])
    }
  }

  @Test func approvedComesBeforeSuggested() {
    let pending = Fixtures.cutSuggestion(id: Fixtures.uuid(9), wordIDs: [7, 8], status: .pending)
    withEditor(suggestions: [pending]) { model in
      model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2])]
      expectNoDifference(
        model.clipBands,
        [
          TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .approved),
          TranscriptClipBand(id: Fixtures.uuid(9), wordIDs: [7, 8], kind: .suggested),
        ])
    }
  }

  /// Green wins: a pending suggestion is drawn only over the words no slice already claims.
  @Test func sliceClaimsWinOverOverlappingSuggestion() {
    let pending = Fixtures.cutSuggestion(
      id: Fixtures.uuid(9), wordIDs: [2, 3, 4], status: .pending)
    withEditor(suggestions: [pending]) { model in
      model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2, 3])]
      expectNoDifference(
        model.clipBands,
        [
          TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2, 3], kind: .approved),
          // words 2 and 3 are claimed green, so amber keeps only word 4.
          TranscriptClipBand(id: Fixtures.uuid(9), wordIDs: [4], kind: .suggested),
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
        [TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2], kind: .approved)])
    }
  }

  @Test func suggestionFullyCoveredBySlicesProducesNoBand() {
    let pending = Fixtures.cutSuggestion(id: Fixtures.uuid(9), wordIDs: [1, 2], status: .pending)
    withEditor(suggestions: [pending]) { model in
      model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2, 3])]
      expectNoDifference(
        model.clipBands,
        [TranscriptClipBand(id: Fixtures.uuid(1), wordIDs: [1, 2, 3], kind: .approved)])
    }
  }
}
