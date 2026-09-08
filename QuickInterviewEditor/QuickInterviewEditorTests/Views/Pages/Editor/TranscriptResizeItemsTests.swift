import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct TranscriptResizeItemsTests {

  private func slice(_ id: UUID, wordIDs: [Word.ID], plan: EditPlan = Fixtures.editPlan()) -> Slice
  {
    let words = plan.words.filter { wordIDs.contains($0.id) }
    return Slice(
      id: id, name: "A story", startSample: words.compactMap(\.startSample).min()!,
      endSample: words.compactMap(\.endSample).max()!,
      wordIDs: wordIDs, snippet: "a story")
  }

  private func editor(suggestions: [CutSuggestion] = []) -> EditorModel {
    let plan = Fixtures.editPlan()
    let freshSuggestions = suggestions.map { original in
      var candidate = original
      candidate.provenance.sourceFingerprint = "resize-source"
      candidate.provenance.transcriptHash = plan.transcriptHash
      return candidate
    }
    return EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan,
      sourceFingerprint: "resize-source",
      initialDocument: EditorDocumentState(
        cutSuggestions: IdentifiedArray(uniqueElements: freshSuggestions)))
  }

  /// Words 1 ("So") and 2 ("a") back the clip; words 2,3,4 ("a","young","Hayes") back the pending
  /// suggestion (word 2 is claimed by both); words 5,6 ("Carl","goes") back the selection.
  @Test func itemsIncludeSelectionClipsAndFullSuggestionRanges() {
    let pending = Fixtures.cutSuggestion(
      id: Fixtures.uuid(9), wordIDs: [2, 3, 4], startSample: 70_648, endSample: 119_202,
      status: .pending)
    let model = editor(suggestions: [pending])
    model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2])]
    model.selectWords(anchorID: 5, focusID: 6)

    let items = model.transcriptResizeItems

    // The overlapping word remains part of both the suggestion band and its resize geometry.
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
    model.slices = [slice(Fixtures.uuid(1), wordIDs: [1, 2], plan: plan)]

    let clip = model.transcriptResizeItems.first { $0.identity == .clip(Fixtures.uuid(1)) }
    expectNoDifference(clip?.wordIDs, [1, 2, 1])
  }

  @Test func resizeGeometryUsesSampleExtentWhenStoredMembershipIsNarrower() {
    let model = editor()
    var clip = slice(Fixtures.uuid(1), wordIDs: [1, 2, 3])
    clip.wordIDs = [2]
    model.slices = [clip]
    expectNoDifference(model.transcriptResizeItems.first?.wordIDs, [1, 2, 3])
  }

  @Test func selectedLowerClipMovesItsResizeHandlesToForeground() {
    let model = editor()
    let first = slice(Fixtures.uuid(1), wordIDs: [1, 2])
    let second = slice(Fixtures.uuid(2), wordIDs: [1, 2])
    model.slices = [first, second]
    expectNoDifference(
      model.transcriptResizeItems.map(\.identity), [.clip(first.id), .clip(second.id)])
    model.selectTranscriptObject(.clip(second.id))
    expectNoDifference(
      model.transcriptResizeItems.map(\.identity), [.clip(second.id), .clip(first.id)])
  }
}
