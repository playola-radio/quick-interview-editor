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

  /// The overflow-safe sample midpoint of a word with real bounds — used to build ranges that
  /// clip a word at its edge (start past its start / end before its end).
  private func mid(_ word: Word) -> Int {
    word.startSample! + (word.endSample! - word.startSample!) / 2
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

  @Test func selectedWordIDsHighlightsPartiallyOverlappedWords() {
    let model = editor()
    let words = model.editPlan.words
    // A selection from mid-word[1] to mid-word[3] clips the edges of word[1]/word[3] and fully
    // covers word[2]. Overlap highlights all three; full-containment would highlight only word[2].
    let range = mid(words[1])..<mid(words[3])
    model.selectSourceRange(range, snapPlayhead: false)
    expectNoDifference(
      model.selectedWordIDs, Set([words[1].id, words[2].id, words[3].id]))
  }

  @Test func strikethroughIsOnlyFullyRemovedWords() async {
    let model = editor()
    let words = model.editPlan.words
    // Range spans mid-word[1] to just past mid-word[3]: it fully contains word[2] but only clips
    // word[1] and word[3]. Midpoint membership (the old rule) would strike all three; the spec's
    // full-containment rule strikes only word[2].
    let range = mid(words[1])..<(mid(words[3]) + 1)
    model.selectSourceRange(range, snapPlayhead: false)
    await model.removeSelectedSectionTapped()
    expectNoDifference(model.removedWordIDs, Set([words[2].id]))
  }

  @Test func addSliceWordIDsAreOverlapDerivedAtCommit() {
    let model = editor()
    let words = model.editPlan.words
    // A selection anchored mid-word[1] to mid-word[3] clips the edges of word[1]/word[3]; slice
    // membership is overlap-derived from the RANGE, not the transcript's own (empty) selection.
    let range = mid(words[1])..<mid(words[3])
    model.selectSourceRange(range, snapPlayhead: false)
    model.addSliceTapped()
    expectNoDifference(model.slices.last?.wordIDs, wordIDs(anyOverlap: range, words: words))
  }
}
