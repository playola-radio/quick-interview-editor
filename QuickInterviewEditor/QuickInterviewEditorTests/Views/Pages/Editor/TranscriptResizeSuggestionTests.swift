import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct TranscriptResizeSuggestionTests {

  private func editor(suggestions: IdentifiedArrayOf<CutSuggestion>) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL,
      editPlan: Fixtures.editPlan(),
      sourceFingerprint: "resize-source",
      initialDocument: EditorDocumentState(cutSuggestions: suggestions))
  }

  private func candidate(
    id: UUID, wordIDs: [Word.ID], status: CutSuggestion.Status = .pending
  ) -> CutSuggestion {
    let plan = Fixtures.editPlan()
    let words = plan.words.filter { wordIDs.contains($0.id) }
    let start = words.compactMap(\.startSample).min()!
    let end = words.compactMap(\.endSample).max()!
    let sampleRate = Double(plan.source.sampleRate)
    var candidate = Fixtures.cutSuggestion(
      id: id, wordIDs: wordIDs, startSample: start, endSample: end,
      startSec: Double(start) / sampleRate, endSec: Double(end) / sampleRate,
      durationSec: Double(end - start) / sampleRate, status: status)
    candidate.provenance.sourceFingerprint = "resize-source"
    candidate.provenance.transcriptHash = plan.transcriptHash
    return candidate
  }

  @Test func lockedSuggestionsCannotBeginOrCommitResize() {
    let suggestion = candidate(id: Fixtures.uuid(1), wordIDs: [1, 2])
    let model = editor(suggestions: [suggestion])
    model.cutSuggestions.run.ownershipBlocked = true
    expectNoDifference(model.transcriptResizeBegan(.suggestion(suggestion.id), .end), false)
    model.cutSuggestions.run.ownershipBlocked = false
    model.transcriptResizeBegan(.suggestion(suggestion.id), .end)
    model.transcriptResizeDragged(toWord: 4)
    model.cutSuggestions.run.ownershipBlocked = true
    model.transcriptResizeEnded()
    expectNoDifference(model.documentCutSuggestions.elements, [suggestion])
  }

  @Test func filteredSuggestionsHaveNoResizeHandles() {
    let suggestion = candidate(id: Fixtures.uuid(1), wordIDs: [1, 2])
    let model = editor(suggestions: [suggestion])
    model.cutSuggestions.selectedTypeIDs = []
    expectNoDifference(model.transcriptResizeItems, [])
    expectNoDifference(model.transcriptResizeBegan(.suggestion(suggestion.id), .end), false)
  }

  @Test func suggestionResizeCommitsOnceAndDerivesSamplesFromWords() async {
    let suggestionID = Fixtures.uuid(1)
    let suggestion = candidate(
      id: suggestionID, wordIDs: [1, 2], status: .pending)
    let model = editor(suggestions: [suggestion])

    model.transcriptResizeBegan(.suggestion(suggestionID), .end)
    model.transcriptResizeDragged(toWord: 4)

    // Untouched mid-drag: the document only commits once, on release.
    expectNoDifference(model.documentCutSuggestions[id: suggestionID]?.wordIDs, [1, 2])

    model.transcriptResizeEnded()

    expectNoDifference(model.documentCutSuggestions[id: suggestionID]?.wordIDs, [1, 2, 3, 4])
    // Samples/seconds come from the exact drafted words' bounds (fixture words 1...4), never
    // audio overlap: word 1 starts at 54772, word 4 ends at 119202.
    expectNoDifference(model.documentCutSuggestions[id: suggestionID]?.startSample, 54772)
    expectNoDifference(model.documentCutSuggestions[id: suggestionID]?.endSample, 119202)
    expectNoDifference(model.transcriptResizeDraft, nil)

    await model.undoTapped()
    expectNoDifference(model.documentCutSuggestions[id: suggestionID]?.wordIDs, [1, 2])
  }

  @Test func acceptedSuggestionIsNotResizable() {
    let suggestionID = Fixtures.uuid(1)
    let suggestion = candidate(
      id: suggestionID, wordIDs: [1, 2], status: .accepted)
    let model = editor(suggestions: [suggestion])

    model.transcriptResizeBegan(.suggestion(suggestionID), .end)

    expectNoDifference(model.transcriptResizeDraft, nil)
  }

  @Test func rejectedSuggestionIsNotResizable() {
    let suggestionID = Fixtures.uuid(1)
    let suggestion = candidate(
      id: suggestionID, wordIDs: [1, 2], status: .rejected)
    let model = editor(suggestions: [suggestion])

    model.transcriptResizeBegan(.suggestion(suggestionID), .end)

    expectNoDifference(model.transcriptResizeDraft, nil)
  }

  private func slice(_ id: UUID, wordIDs: [Word.ID]) -> Slice {
    let words = Fixtures.editPlan().words.filter { wordIDs.contains($0.id) }
    return Slice(
      id: id, name: "A story", startSample: words.compactMap(\.startSample).min()!,
      endSample: words.compactMap(\.endSample).max()!,
      wordIDs: wordIDs, snippet: "a story")
  }

  @Test func overlappingSuggestionsKeepFullResizeItemsAndSelectedSuggestionIsForeground() {
    let fullyCovered = candidate(
      id: Fixtures.uuid(1), wordIDs: [1, 2], status: .pending)
    let partiallyCovered = candidate(
      id: Fixtures.uuid(2), wordIDs: [3, 4], status: .pending)
    let model = editor(suggestions: [fullyCovered, partiallyCovered])
    model.slices = [
      slice(Fixtures.uuid(3), wordIDs: [1, 2]),
      slice(Fixtures.uuid(4), wordIDs: [3]),
    ]

    let suggestionItems = model.transcriptResizeItems.filter {
      if case .suggestion = $0.identity { return true }
      return false
    }
    expectNoDifference(
      suggestionItems.map(\.identity),
      [.suggestion(fullyCovered.id), .suggestion(partiallyCovered.id)])
    expectNoDifference(suggestionItems.map(\.wordIDs), [[1, 2], [3, 4]])
    model.selectTranscriptObject(.suggestion(fullyCovered.id))
    expectNoDifference(model.transcriptResizeItems.first?.identity, .suggestion(fullyCovered.id))
    expectNoDifference(model.transcriptResizeBegan(.suggestion(fullyCovered.id), .end), true)
    model.transcriptResizeDragged(toWord: 3)
    expectNoDifference(
      model.clipBands.first { $0.id == fullyCovered.id }?.wordIDs, [1, 2, 3])
    expectNoDifference(model.documentCutSuggestions[id: fullyCovered.id]?.wordIDs, [1, 2])
  }

  /// Regression for Codex challenge P1#3: toggling the Suggestions panel's show/hide bands off
  /// must drop every `.suggestion` resize item, mirroring `clipBands`' early return, and restore
  /// them when toggled back on.
  @Test func suggestionResizeItemsHiddenWhenBandsToggledOff() {
    let suggestionID = Fixtures.uuid(1)
    let suggestion = candidate(id: suggestionID, wordIDs: [1, 2], status: .pending)
    let model = editor(suggestions: [suggestion])
    expectNoDifference(
      model.transcriptResizeItems.map(\.identity), [.suggestion(suggestionID)])

    model.cutSuggestions.showsSuggestionBands = false
    expectNoDifference(model.transcriptResizeItems, [])

    model.cutSuggestions.showsSuggestionBands = true
    expectNoDifference(
      model.transcriptResizeItems.map(\.identity), [.suggestion(suggestionID)])
  }

  @Test func suggestionResizeBackToOriginalRecordsNoUndo() {
    let suggestionID = Fixtures.uuid(1)
    let suggestion = candidate(
      id: suggestionID, wordIDs: [1, 2], status: .pending)
    let model = editor(suggestions: [suggestion])

    // A real resize first, so the suggestion's samples are internally consistent with its words.
    model.transcriptResizeBegan(.suggestion(suggestionID), .end)
    model.transcriptResizeDragged(toWord: 4)
    model.transcriptResizeEnded()
    let before = model.documentCutSuggestions[id: suggestionID]
    let undoCountBefore = model.history.undo.count

    // Dragging back to the same drafted words nets no change, so `ended` must be a no-op.
    model.transcriptResizeBegan(.suggestion(suggestionID), .end)
    model.transcriptResizeDragged(toWord: 4)
    model.transcriptResizeEnded()

    expectNoDifference(model.documentCutSuggestions[id: suggestionID], before)
    expectNoDifference(model.history.undo.count, undoCountBefore)
  }
}
