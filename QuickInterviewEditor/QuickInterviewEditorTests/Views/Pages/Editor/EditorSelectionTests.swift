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

  @Test func transcriptSelectionWritesAudioSelectionViaIntent() {
    let model = editor()
    // Word 2 ("a", samples 70648..<74176) has real sample bounds — see EditorAreaSelectTests.
    model.transcript.selectWords(anchorID: 2, focusID: 2)
    expectNoDifference(model.selectedSourceRange, model.transcript.selectedSampleRange)
    expectNoDifference(model.selectedSourceRange, 70648..<74176)
  }

  @Test func activeAndHighlightRangesReadTheFacade() {
    let model = editor()
    // Words 2..4 ("a"..."Hayes", samples 70648..<119202) have real sample bounds — see
    // EditorAreaSelectTests's header comment.
    model.transcript.selectWords(anchorID: 2, focusID: 4)
    expectNoDifference(model.highlightedSampleRange, model.selectedSourceRange)
    expectNoDifference(
      model.activeOrSelectedRange, model.selectedSourceRange ?? model.activeSliceRange)
  }

  @Test func canAddAndCanRemoveReadTheFacade() {
    let model = editor()
    model.transcript.selectWords(anchorID: 2, focusID: 4)
    #expect(model.canAddSlice)
    #expect(model.canRemoveSelectedSection)
  }

  @Test func transcriptSelectionSeedsAudioSelectionWithoutView() {
    // Regression: readers now read `selectedSourceRange` (= audioSelection). A transcript selection
    // change emits `onSelectionIntent`, which the model applies to `audioSelection` — with no view
    // `.onChange` — otherwise every headless model test that sets a selection reads nil.
    let model = editor()
    model.transcript.selectWords(anchorID: 2, focusID: 4)
    expectNoDifference(model.audioSelection, model.transcript.selectedSampleRange)
    expectNoDifference(model.audioSelection, 70648..<119202)
  }

  @Test func selectingWordsSeedsAudioSelectionWithCoveredSpan() {
    let model = editor()
    let anchorID = model.editPlan.words[1].id
    let focusID = model.editPlan.words[3].id
    model.selectWords(anchorID: anchorID, focusID: focusID)
    let expected = model.editPlan.words[1].startSample!..<model.editPlan.words[3].endSample!
    expectNoDifference(model.audioSelection, expected)
  }

  @Test func selectWordExtendingStretchesFromTheHeldAnchor() {
    let model = editor()
    // A plain select holds word 3's start as the anchor; a Shift-extend to word 5 stretches the
    // freeform range from that anchor to word 5's end (77704..<135960), never replacing it.
    model.selectWord(3, extending: false)
    model.selectWord(5, extending: true)
    expectNoDifference(model.audioSelection, 77704..<135960)
  }

  @Test func nudgingStartEdgeMovesOnlyThatEdgeByTenMs() {
    let model = editor()
    model.selectSourceRange(10_000..<40_000, snapPlayhead: false)
    model.selectionNudged(.start, byMs: -10)
    let expected = model.boundaryEditor.nudgeStart(of: 10_000..<40_000, byMs: -10)
    expectNoDifference(model.audioSelection, expected)
  }

  @Test func nudgingEndEdgeLeavesStartFixed() {
    let model = editor()
    model.selectSourceRange(10_000..<40_000, snapPlayhead: false)
    model.selectionNudged(.end, byMs: 10)
    #expect(model.audioSelection?.lowerBound == 10_000)
    #expect(model.audioSelection!.upperBound > 40_000)
  }

  @Test func edgeDragMovesOnlyDraggedEdgeToSample() {
    let model = editor()
    model.editedWaveform.viewportResized(width: 1000)
    model.selectSourceRange(10_000..<40_000, snapPlayhead: false)
    let target = 25_000
    model.selectionEdgeDragBegan(.start)
    model.selectionEdgeDraggedToSource(.start, target)
    #expect(model.audioSelection?.upperBound == 40_000)
    #expect(abs((model.audioSelection?.lowerBound ?? 0) - target) <= 1)
  }
}
