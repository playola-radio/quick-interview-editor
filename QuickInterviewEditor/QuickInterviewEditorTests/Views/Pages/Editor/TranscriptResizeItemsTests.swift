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

  /// Regression: word IDs are not guaranteed unique. When the transcript repeats an ID, an
  /// item's ordered word run must include EVERY occurrence in transcript order — matching the
  /// original `order.filter(set.contains)` that the position-index optimization replaced. Here
  /// ID 1 appears at transcript positions 0 and 2, so a clip covering {1, 2} orders to [1, 2, 1].
  @Test func clipWordRunKeepsEveryOccurrenceOfADuplicateID() {
    func word(_ id: Int, _ start: Int) -> Word {
      Word(
        id: id, text: "w", start: Double(start), end: nil, startSample: start,
        endSample: start + 100)
    }
    let plan = EditPlan(
      schemaVersion: 1,
      source: EditPlan.Source(
        path: "/x.aiff", sampleRate: 44100, channels: 1, durationSamples: 10_000),
      words: [word(1, 0), word(2, 200), word(1, 400), word(3, 600)],
      silences: [], segments: [])
    let model = EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan,
      initialDocument: EditorDocumentState(cutSuggestions: []))
    model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2])]

    let clip = model.transcriptResizeItems.first { $0.identity == .clip(Fixtures.uuid(1)) }
    expectNoDifference(clip?.wordIDs, [1, 2, 1])
  }
}
