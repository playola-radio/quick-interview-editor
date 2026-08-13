import Clocks
import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

/// Logic-style marquee: a horizontal drag in the waveform body selects the overlapped transcript
/// words (by midpoint), highlights them, and — on release — snaps the playhead to the selection
/// start and scrolls the transcript there. Dragging past the viewport edge auto-scrolls.
///
/// Geometry is installed explicitly (no audio decode) so `xToSample(x) == start + floor(x * spp)`.
/// With `spp: 200, start: 0`, view-x maps to plan samples as `sample = x * 200`. The fixture's
/// first words (id: start–end, midpoint) are:
///   2 a       70648–74176  (72412)
///   3 young   77704–98916  (88310)
///   4 Hayes  107736–119202 (113469)
///   5 Carl   120966–135960 (128463)
///   6 goes   139488–150072 (144780)
///  10 Wiley  179222–194216 (186719)
///  11 Hubbard195098–206564 (200831)
@MainActor
struct EditorAreaSelectTests {
  private func editor(_ plan: EditPlan = Fixtures.editPlan()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan)
  }

  private func editor(clock: some Clock<Duration>) -> EditorModel {
    withDependencies {
      $0.continuousClock = clock
    } operation: {
      editor()
    }
  }

  private func geometry(
    _ model: EditorModel, samplesPerPixel: Double = 200, start: Int = 0,
    viewportWidth: CGFloat = 1000
  ) {
    model.waveform.totalSamples = model.editPlan.source.durationSamples
    model.waveform.viewportWidth = viewportWidth
    model.waveform.samplesPerPixel = samplesPerPixel
    model.waveform.visibleStartSample = start
  }

  // MARK: - Word mapping + direction

  @Test func plainDragSelectsOverlappedWordsLeftToRight() {
    let model = editor()
    geometry(model)
    model.waveformAreaSelectBegan(atX: 350, extending: false)  // anchor sample 70000
    model.waveformAreaSelectChanged(toX: 600)  // focus sample 120000 → words 2,3,4
    model.waveformAreaSelectEnded(toX: 600)
    expectNoDifference(model.transcript.selectionAnchorID, 2)
    expectNoDifference(model.transcript.selectionFocusID, 4)
    expectNoDifference(model.transcript.orderedSelectedWordIDs, [2, 3, 4])
    expectNoDifference(model.transcript.selectedSampleRange, 70648..<119202)
  }

  @Test func rightToLeftDragPutsTheAnchorAtTheStartEdge() {
    let model = editor()
    geometry(model)
    model.waveformAreaSelectBegan(atX: 600, extending: false)  // anchor sample 120000
    model.waveformAreaSelectChanged(toX: 350)  // focus sample 70000 (dragging left)
    model.waveformAreaSelectEnded(toX: 350)
    // Same words, but the anchor is the word under the drag's START edge so a later Shift-click
    // extends from the right place.
    expectNoDifference(model.transcript.selectionAnchorID, 4)
    expectNoDifference(model.transcript.selectionFocusID, 2)
    expectNoDifference(model.transcript.orderedSelectedWordIDs, [2, 3, 4])
  }

  // MARK: - Silence handling

  @Test func draggingIntoSilenceRetainsTheLastSelectionThenClearsOnRelease() {
    let model = editor()
    geometry(model)
    model.waveformAreaSelectBegan(atX: 350, extending: false)
    model.waveformAreaSelectChanged(toX: 600)  // words 2,3,4
    expectNoDifference(model.transcript.orderedSelectedWordIDs, [2, 3, 4])
    model.waveformAreaSelectChanged(toX: 350)  // collapses to a wordless sliver → retain
    expectNoDifference(model.transcript.orderedSelectedWordIDs, [2, 3, 4])
    model.waveformAreaSelectEnded(toX: 350)  // still wordless on release → clear
    expectNoDifference(model.transcript.selectionAnchorID, nil)
    expectNoDifference(model.transcript.selectionFocusID, nil)
  }

  // MARK: - Shift-extend

  @Test func shiftDragExtendsFromTheExistingAnchor() {
    let model = editor()
    geometry(model)
    model.transcript.selectWords(anchorID: 2, focusID: 3)  // existing selection, anchor = 2
    model.waveformAreaSelectBegan(atX: 750, extending: true)
    model.waveformAreaSelectChanged(toX: 750)  // focus sample 150000
    model.waveformAreaSelectEnded(toX: 750)
    // Anchor stays 2 (not recomputed to the earliest overlapped word); focus moves to the edge.
    expectNoDifference(model.transcript.selectionAnchorID, 2)
    expectNoDifference(model.transcript.selectionFocusID, 6)
    expectNoDifference(model.transcript.orderedSelectedWordIDs, [2, 3, 4, 5, 6])
  }

  // MARK: - Playhead

  @Test func releaseSnapsPlayheadToSelectionStartAndLeavesTransportStopped() {
    let model = editor()
    geometry(model)
    model.waveformAreaSelectBegan(atX: 350, extending: false)
    model.waveformAreaSelectChanged(toX: 600)
    model.waveformAreaSelectEnded(toX: 600)
    expectNoDifference(model.playheadSample, 70648)  // selection start
    expectNoDifference(model.transportPhase, .stopped)
  }

  @Test func playheadSnapIsSuppressedMidDragThenCommittedOnRelease() async {
    let model = editor()
    geometry(model)
    model.playheadSample = 999
    model.waveformAreaSelectBegan(atX: 350, extending: false)
    model.waveformAreaSelectChanged(toX: 600)  // selection [2,3,4]
    // Simulate the view's deferred selection→playhead snap firing mid-drag: it must bail.
    let token = model.cursorMoveToken
    await model.transportSelectionChanged(model.transcript.selectedSampleRange, cursorToken: token)
    expectNoDifference(model.playheadSample, 999)  // still suppressed
    model.waveformAreaSelectEnded(toX: 600)
    expectNoDifference(model.playheadSample, 70648)  // committed once on release
  }

  // MARK: - Auto-scroll past the visible edge

  @Test func draggingPastTheRightEdgeAutoScrollsAndExtendsTheSelection() async {
    let clock = TestClock()
    let model = editor(clock: clock)
    geometry(model)  // visible samples [0, 200_000); plenty of file to the right
    await withMainSerialExecutor {
      model.waveformAreaSelectBegan(atX: 900, extending: false)  // anchor sample 180000
      // Past the right edge → word 10 only, and the auto-scroll loop starts.
      model.waveformAreaSelectChanged(toX: 1100)
      expectNoDifference(model.transcript.orderedSelectedWordIDs, [10])
      await clock.advance(by: .milliseconds(16))  // one auto-scroll tick
      #expect(model.waveform.visibleStartSample > 0)  // the viewport scrolled right
      // The scroll revealed word 11, and the marquee extended to include it.
      #expect(model.transcript.orderedSelectedWordIDs.contains(11))
      model.waveformAreaSelectEnded(toX: 1100)
    }
  }

  @Test func draggingPastTheLeftEdgeAutoScrollsLeftAndClampsAtTheStart() async {
    let clock = TestClock()
    let model = editor(clock: clock)
    geometry(model, start: 100_000)  // scrolled in: visible [100_000, 300_000)
    await withMainSerialExecutor {
      model.waveformAreaSelectBegan(atX: 500, extending: false)  // anchor sample 200000
      model.waveformAreaSelectChanged(toX: -50)  // past the left edge → scroll left
      let before = model.waveform.visibleStartSample
      await clock.advance(by: .milliseconds(16))  // one tick
      #expect(model.waveform.visibleStartSample < before)  // scrolled toward the start
      await clock.advance(by: .seconds(1))  // many ticks — must clamp, not overrun
      expectNoDifference(model.waveform.visibleStartSample, 0)  // pinned at the document start
      #expect(model.transcript.orderedSelectedWordIDs.contains(1))  // reached the first word
      model.waveformAreaSelectEnded(toX: -50)
    }
  }

  @Test func leftwardShiftDragExtendsFromTheExistingAnchor() {
    let model = editor()
    geometry(model)
    model.transcript.selectWord(5)  // existing selection, anchor = 5
    model.waveformAreaSelectBegan(atX: 400, extending: true)
    model.waveformAreaSelectChanged(toX: 360)  // focus sample 72000, left of the anchor word
    model.waveformAreaSelectEnded(toX: 360)
    // Anchor stays 5; focus moves left to word 2; the run between them fills in.
    expectNoDifference(model.transcript.selectionAnchorID, 5)
    expectNoDifference(model.transcript.selectionFocusID, 2)
    expectNoDifference(model.transcript.orderedSelectedWordIDs, [2, 3, 4, 5])
  }

  @Test func aDragThatStaysInsideTheViewportNeverAutoScrolls() async {
    let clock = TestClock()
    let model = editor(clock: clock)
    geometry(model)
    await withMainSerialExecutor {
      model.waveformAreaSelectBegan(atX: 350, extending: false)
      model.waveformAreaSelectChanged(toX: 600)  // fully inside the viewport
      await clock.advance(by: .milliseconds(64))
      expectNoDifference(model.waveform.visibleStartSample, 0)  // no scroll task ever started
      model.waveformAreaSelectEnded(toX: 600)
    }
  }

  // MARK: - Geometry guard

  @Test func areaSelectIsANoOpBeforeGeometryLoads() {
    let model = editor()  // no geometry → totalSamples 0, hasUsableGeometry false
    model.waveformAreaSelectBegan(atX: 350, extending: false)
    model.waveformAreaSelectChanged(toX: 600)
    model.waveformAreaSelectEnded(toX: 600)
    expectNoDifference(model.transcript.selectionAnchorID, nil)
  }
}
