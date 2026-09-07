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
}
