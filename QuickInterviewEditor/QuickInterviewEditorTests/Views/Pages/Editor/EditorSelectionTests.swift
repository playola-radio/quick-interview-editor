import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorSelectionTests {
  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan)
  }

  @Test func seedMirrorsTranscriptSelectionIntoAudioSelection() {
    let model = editor()
    // Word 2 ("a", samples 70648..<74176) has real sample bounds — see EditorAreaSelectTests.
    model.transcript.selectWords(anchorID: 2, focusID: 2)
    model.seedSelectionFromTranscript()
    expectNoDifference(model.selectedSourceRange, model.transcript.selectedSampleRange)
    expectNoDifference(model.selectedSourceRange, 70648..<74176)
  }
}
