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
      initialDocument: EditorDocumentState(cutSuggestions: suggestions))
  }

  @Test func suggestionResizeCommitsOnceAndDerivesSamplesFromWords() async {
    let suggestionID = Fixtures.uuid(1)
    let suggestion = Fixtures.cutSuggestion(
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
    let suggestion = Fixtures.cutSuggestion(
      id: suggestionID, wordIDs: [1, 2], status: .accepted)
    let model = editor(suggestions: [suggestion])

    model.transcriptResizeBegan(.suggestion(suggestionID), .end)

    expectNoDifference(model.transcriptResizeDraft, nil)
  }

  @Test func rejectedSuggestionIsNotResizable() {
    let suggestionID = Fixtures.uuid(1)
    let suggestion = Fixtures.cutSuggestion(
      id: suggestionID, wordIDs: [1, 2], status: .rejected)
    let model = editor(suggestions: [suggestion])

    model.transcriptResizeBegan(.suggestion(suggestionID), .end)

    expectNoDifference(model.transcriptResizeDraft, nil)
  }

  private func slice(_ id: UUID, wordIDs: [Word.ID]) -> Slice {
    Slice(
      id: id, name: "A story", startSample: 0, endSample: 100,
      wordIDs: wordIDs, snippet: "a story")
  }

  /// Regression for Codex challenge P1#3: `transcriptResizeItems` must match `clipBands`'
  /// visibility rules. A suggestion fully covered by a clip draws no band, so it must publish no
  /// resize handles either — otherwise the invisible suggestion still steals clicks. A
  /// partially-covered suggestion in the same setup survives with its FULL (unfiltered) wordIDs.
  @Test func suggestionFullyCoveredByClipHasNoResizeItem() {
    let fullyCovered = Fixtures.cutSuggestion(
      id: Fixtures.uuid(1), wordIDs: [1, 2], status: .pending)
    let partiallyCovered = Fixtures.cutSuggestion(
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
    expectNoDifference(suggestionItems.map(\.identity), [.suggestion(Fixtures.uuid(2))])
    expectNoDifference(suggestionItems.first?.wordIDs, [3, 4])
  }

  /// Regression for Codex challenge P1#3: toggling the Suggestions panel's show/hide bands off
  /// must drop every `.suggestion` resize item, mirroring `clipBands`' early return, and restore
  /// them when toggled back on.
  @Test func suggestionResizeItemsHiddenWhenBandsToggledOff() {
    let suggestionID = Fixtures.uuid(1)
    let suggestion = Fixtures.cutSuggestion(id: suggestionID, wordIDs: [1, 2], status: .pending)
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
    let suggestion = Fixtures.cutSuggestion(
      id: suggestionID, wordIDs: [1, 2], status: .pending)
    let model = editor(suggestions: [suggestion])

    // A real resize first, so the suggestion's samples are internally consistent with its words.
    model.transcriptResizeBegan(.suggestion(suggestionID), .end)
    model.transcriptResizeDragged(toWord: 4)
    model.transcriptResizeEnded()
    let before = model.documentCutSuggestions[id: suggestionID]
    let undoCountBefore = model.documentUndo.undo.count

    // Dragging back to the same drafted words nets no change, so `ended` must be a no-op.
    model.transcriptResizeBegan(.suggestion(suggestionID), .end)
    model.transcriptResizeDragged(toWord: 4)
    model.transcriptResizeEnded()

    expectNoDifference(model.documentCutSuggestions[id: suggestionID], before)
    expectNoDifference(model.documentUndo.undo.count, undoCountBefore)
  }
}
