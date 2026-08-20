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

  @Test func activeAndHighlightRangesReadTheFacade() {
    let model = editor()
    // Words 2..4 ("a"..."Hayes", samples 70648..<119202) have real sample bounds — see
    // EditorAreaSelectTests's header comment.
    model.transcript.selectWords(anchorID: 2, focusID: 4)
    model.seedSelectionFromTranscript()
    expectNoDifference(model.highlightedSampleRange, model.selectedSourceRange)
    expectNoDifference(
      model.activeOrSelectedRange, model.selectedSourceRange ?? model.activeSliceRange)
  }

  @Test func canAddAndCanRemoveReadTheFacade() {
    let model = editor()
    model.transcript.selectWords(anchorID: 2, focusID: 4)
    model.seedSelectionFromTranscript()
    #expect(model.canAddSlice)
    #expect(model.canRemoveSelectedSection)
  }

  @Test func transcriptSelectionSeedsAudioSelectionWithoutView() {
    // Regression: readers now read `selectedSourceRange` (= audioSelection). The model must seed
    // itself from a transcript selection change via `transcript.onSelectionChanged`, with no view
    // `.onChange` — otherwise every headless model test that sets a selection reads nil.
    let model = editor()
    model.transcript.selectWords(anchorID: 2, focusID: 4)
    expectNoDifference(model.audioSelection, model.transcript.selectedSampleRange)
    expectNoDifference(model.audioSelection, 70648..<119202)
  }
}
