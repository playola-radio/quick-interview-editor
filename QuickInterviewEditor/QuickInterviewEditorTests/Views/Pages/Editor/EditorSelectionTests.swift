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

  /// A right-to-left transcript drag anchors on the LATER word, so a subsequent Shift-extend must
  /// pivot from that word's end — not the range's lower bound. Regression: `selectWords` used to hold
  /// `range.lowerBound` unconditionally, so extending an R-to-L selection pivoted off the wrong edge.
  @Test func rightToLeftSelectionHoldsAnchorWordFarEdge() {
    let model = editor()
    // Words 2..4 ("a","young","Hayes") have real bounds. Drag anchor=Hayes(id 4) back to focus="a"
    // (id 2): the held anchor is Hayes's end (119202), not "a"'s start.
    model.selectWords(anchorID: 4, focusID: 2)
    // Shift-extend inward to "young" (id 3): the range pivots from Hayes's end, giving young.start →
    // Hayes.end. The old lower-bound anchor would have produced a.start → young.end instead.
    model.selectWord(3, extending: true)
    expectNoDifference(model.audioSelection, 77704..<119202)
  }

  /// The mark-clip bar reads its clear-enabled state and word-count summary from `audioSelection`, so
  /// a waveform marquee selection (which never touches the transcript) still lights up the bar and is
  /// clearable. Regression: the bar read `transcript.hasSelection`/`selectionSummary`, which stayed
  /// stale for waveform-created selections after the source-of-truth inversion.
  @Test func clearBarTracksWaveformSelection() {
    let model = editor()
    #expect(!model.canClearSelection)
    expectNoDifference(model.selectionSummary, "No selection")

    let words = model.editPlan.words
    model.selectSourceRange(words[1].startSample!..<words[3].endSample!, snapPlayhead: false)
    #expect(model.canClearSelection)
    expectNoDifference(model.selectionSummary, "3 words selected")

    model.clearSelectionTapped()
    #expect(!model.canClearSelection)
    expectNoDifference(model.selectionSummary, "No selection")
  }

  /// Clearing the freeform selection must also invalidate the transcript's Shift-click gesture anchor.
  /// Otherwise a later transcript Shift-click extends from the anchor of the selection the user just
  /// cleared — resurrecting it. After a clear, a Shift-click should plain-select the clicked word.
  @Test func clearingSelectionInvalidatesTranscriptExtendAnchor() {
    let model = editor()
    model.transcript.selectWords(anchorID: 2, focusID: 4)
    #expect(model.audioSelection != nil)

    model.clearSelection()
    #expect(model.audioSelection == nil)

    model.transcript.wordClicked(3, extending: true)
    let word3 = model.editPlan.words.first { $0.id == 3 }!
    expectNoDifference(model.audioSelection, word3.startSample!..<word3.endSample!)
  }

  /// A selection built from bad word bounds must not persist past the file's end. `selectSourceRange`
  /// is the single write path, so it clamps to `[0, durationSamples]`; a range fully past EOF collapses
  /// to no selection. Regression: an out-of-file range flowed straight into a removal that revalidation
  /// silently dropped on reload, so the edit vanished.
  @Test func selectSourceRangeClampsToFileExtent() {
    let model = editor()
    let duration = model.editPlan.source.durationSamples
    model.selectSourceRange((duration - 10_000)..<(duration + 50_000), snapPlayhead: false)
    expectNoDifference(model.audioSelection, (duration - 10_000)..<duration)

    model.selectSourceRange((duration + 100_000)..<(duration + 200_000), snapPlayhead: false)
    expectNoDifference(model.audioSelection, nil)
  }

  /// A Shift-click in the waveform with no anchor and no live selection has nothing to extend, so it
  /// behaves as a plain click (selects the containing word) instead of collapsing to an empty range
  /// that clears. Word 3 ("young", 77704..<98916) contains sample 88000 (x=440 at spp 200).
  @Test func firstWaveformShiftClickPlainSelectsContainingWord() {
    let model = editor()
    installGeometry(model)
    #expect(model.audioSelection == nil)
    model.waveformClicked(atX: 440, extending: true)
    expectNoDifference(model.audioSelection, 77704..<98916)
  }

  /// Identity source + edited geometry (no removals) so `editedWaveform.xToSourceSample(x) == x * 200`
  /// and `hasUsableGeometry` is true — mirrors `EditorAreaSelectTests.geometry`.
  private func installGeometry(_ model: EditorModel, samplesPerPixel: Double = 200) {
    let duration = model.editPlan.source.durationSamples
    model.waveform.totalSamples = duration
    model.waveform.waveform = Waveform.pyramid(
      baseMins: [0], baseMaxs: [0], sampleRate: model.editPlan.source.sampleRate,
      totalSamples: duration, baseBucketSize: 4)
    model.waveform.viewportWidth = 1000
    model.waveform.samplesPerPixel = samplesPerPixel
    model.waveform.visibleStartSample = 0
    model.editedWaveform.viewportWidth = 1000
    model.editedWaveform.samplesPerPixel = samplesPerPixel
    model.editedWaveform.visibleStartSample = 0
  }

  /// Trimming the edge that holds the extend-anchor must move the anchor with it, so a later
  /// Shift-extend pivots from the trimmed boundary — never the pre-trim one. Regression: edge edits
  /// wrote `audioSelection` but left `selectionAnchorSample` at the pre-trim start, so the next
  /// Shift-extend restored the audio the user had just trimmed away.
  @Test func trimmingAnchorEdgeMovesAnchorSoShiftExtendKeepsTheTrim() {
    let model = editor()
    // Plain-select "young" (id 3, 77704..<98916): the anchor pins to its start (77704).
    model.selectWord(3, extending: false)
    model.selectionEdgeDragBegan(.start)
    model.selectionEdgeDraggedToSource(.start, 88_000)
    let trimmed = model.audioSelection!
    #expect(trimmed.lowerBound > 77_704)
    expectNoDifference(model.selectionAnchorSample, trimmed.lowerBound)

    // Shift-extend to "Hayes" (id 4, ...<119202): the range pivots from the trimmed start, not 77704.
    model.selectWord(4, extending: true)
    #expect(model.audioSelection?.lowerBound == trimmed.lowerBound)
    #expect(model.audioSelection?.upperBound == 119_202)
  }

  /// A marquee over a gap that overlaps no word must not enable "Mark as Clip": `addSliceTapped()`
  /// would derive no word IDs and no-op, so the button would be enabled yet inert. Regression:
  /// `canAddSlice` keyed only on the selection being non-nil, ignoring whether it covered any word.
  @Test func silenceOnlySelectionDisablesAddSlice() throws {
    let model = editor()
    let spans =
      model.editPlan.words
      .compactMap { word -> Range<Int>? in
        guard let start = word.startSample, let end = word.endSample else { return nil }
        return start..<end
      }
      .sorted { $0.lowerBound < $1.lowerBound }
    // A gap strictly between two adjacent words overlaps no word.
    let gap = try #require(
      zip(spans, spans.dropFirst()).first { $0.1.lowerBound > $0.0.upperBound }
        .map { $0.0.upperBound..<$0.1.lowerBound })
    model.selectSourceRange(gap, snapPlayhead: false)
    #expect(model.selectedSourceRange != nil)
    #expect(!model.canAddSlice)
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
