import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct TranscriptResizeItemsTests {

  private func slice(_ id: UUID, wordIDs: [Word.ID]) -> Slice {
    Slice(
      id: id, name: "A story", startSample: 0, endSample: 100,
      wordIDs: wordIDs, snippet: "a story")
  }

  private func editor(suggestions: [CutSuggestion] = []) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: Fixtures.editPlan(),
      initialDocument: EditorDocumentState(
        cutSuggestions: IdentifiedArray(uniqueElements: suggestions)))
  }

  /// Words 1 ("So") and 2 ("a") back the clip; words 2,3,4 ("a","young","Hayes") back the pending
  /// suggestion (word 2 is claimed by both); words 5,6 ("Carl","goes") back the selection.
  @Test func itemsIncludeSelectionClipsAndFullSuggestionRanges() {
    let pending = Fixtures.cutSuggestion(
      id: Fixtures.uuid(9), wordIDs: [2, 3, 4], status: .pending)
    let model = editor(suggestions: [pending])
    model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2])]
    model.selectWords(anchorID: 5, focusID: 6)

    let items = model.transcriptResizeItems

    // Suggestion keeps word 2 even though the clip claims it (semantic, not drawn).
    let suggestion = items.first {
      if case .suggestion = $0.identity { return true }
      return false
    }
    expectNoDifference(suggestion?.wordIDs, [2, 3, 4])

    // Selection present with its covered words.
    let selection = items.first { $0.identity == .selection }
    expectNoDifference(selection?.wordIDs, [5, 6])

    // Clip present with its own words.
    let clip = items.first { $0.identity == .clip(Fixtures.uuid(1)) }
    expectNoDifference(clip?.wordIDs, [1, 2])
  }

  @Test func noSelectionMeansNoSelectionItem() {
    let model = editor()
    model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2])]
    expectNoDifference(model.transcriptResizeItems.contains { $0.identity == .selection }, false)
  }
}
