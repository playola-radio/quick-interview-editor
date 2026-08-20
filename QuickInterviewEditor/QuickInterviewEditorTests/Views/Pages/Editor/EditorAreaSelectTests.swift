import Clocks
import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

/// Logic-style marquee: a horizontal drag in the waveform body writes `audioSelection` with the
/// EXACT dragged `[start, end)` in source samples — freeform, never snapped to word edges — and,
/// on release, snaps the playhead to the range start and scrolls the transcript to the range's
/// first overlapping word. Dragging past the viewport edge auto-scrolls.
///
/// Geometry is installed explicitly (no audio decode) so `xToSample(x) == start + floor(x * spp)`.
/// With `spp: 200, start: 0`, view-x maps to source samples as `sample = x * 200`. The fixture's
/// first words (id: start–end) are:
///   2 a       70648–74176
///   3 young   77704–98916
///   4 Hayes  107736–119202
///   5 Carl   120966–135960
///   6 goes   139488–150072
///  10 Wiley  179222–194216
///  11 Hubbard195098–206564
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

  /// Installs matching source + edited geometry (identity timeline, no removals) plus a trivial
  /// source pyramid so `editedWaveform.hasUsableGeometry` is true — the editor now hit-tests on the
  /// EDITED adapter, whose usable-geometry gate requires a loaded source waveform.
  private func geometry(
    _ model: EditorModel, samplesPerPixel: Double = 200, start: Int = 0,
    viewportWidth: CGFloat = 1000
  ) {
    let duration = model.editPlan.source.durationSamples
    model.waveform.totalSamples = duration
    model.waveform.waveform = Waveform.pyramid(
      baseMins: [0], baseMaxs: [0], sampleRate: model.editPlan.source.sampleRate,
      totalSamples: duration, baseBucketSize: 4)
    model.waveform.viewportWidth = viewportWidth
    model.waveform.samplesPerPixel = samplesPerPixel
    model.waveform.visibleStartSample = start
    model.editedWaveform.viewportWidth = viewportWidth
    model.editedWaveform.samplesPerPixel = samplesPerPixel
    model.editedWaveform.visibleStartSample = start
  }

  // MARK: - Exact source range + direction

  @Test func plainDragSelectsExactSourceRangeLeftToRight() {
    let model = editor()
    geometry(model)
    model.waveformAreaSelectBegan(atX: 350, extending: false)  // anchor sample 70000
    model.waveformAreaSelectChanged(toX: 600)  // focus sample 120000
    model.waveformAreaSelectEnded(toX: 600)
    // Exact dragged samples, NOT snapped to word 2's start (70648) / word 4's end (119202).
    expectNoDifference(model.audioSelection, 70000..<120000)
  }

  @Test func marqueeSelectsExactDraggedSourceRangeNotWordEdges() {
    let model = editor()
    geometry(model)
    // Begin MID word 2 (72000 ∈ 70648..<74176) and end MID word 4 (110000 ∈ 107736..<119202): the
    // stored range must be the raw dragged samples, never widened to the enclosing words' edges.
    model.waveformAreaSelectBegan(atX: 360, extending: false)  // sample 72000
    model.waveformAreaSelectChanged(toX: 550)  // sample 110000
    model.waveformAreaSelectEnded(toX: 550)
    expectNoDifference(model.audioSelection, 72000..<110000)
  }

  @Test func rightToLeftDragPutsTheAnchorAtTheStartEdge() {
    let model = editor()
    geometry(model)
    model.waveformAreaSelectBegan(atX: 600, extending: false)  // anchor sample 120000
    model.waveformAreaSelectChanged(toX: 350)  // focus sample 70000 (dragging left)
    model.waveformAreaSelectEnded(toX: 350)
    // Same range, but the fixed anchor edge is the drag's START (120000) so a later Shift-extend
    // pivots from there.
    expectNoDifference(model.audioSelection, 70000..<120000)
    expectNoDifference(model.selectionAnchorSample, 120000)
  }

  // MARK: - Silence handling

  @Test func draggingWithinSilenceSelectsTheExactRangeWithNoWords() {
    let model = editor()
    geometry(model)
    // 75000..<77000 lies entirely in the gap between word 2 (…74176) and word 3 (77704…). Freeform
    // selection keeps it exactly — silence is selectable, not cleared.
    model.waveformAreaSelectBegan(atX: 375, extending: false)  // sample 75000
    model.waveformAreaSelectChanged(toX: 385)  // sample 77000
    model.waveformAreaSelectEnded(toX: 385)
    expectNoDifference(model.audioSelection, 75000..<77000)
    // no word overlaps → transcript scrolls nowhere
    expectNoDifference(model.transcript.reveal, nil)
  }

  // MARK: - Shift-extend

  @Test func shiftDragExtendsFromTheExistingAnchor() {
    let model = editor()
    geometry(model)
    model.transcript.selectWords(anchorID: 2, focusID: 3)  // seeds audioSelection 70648..<98916
    model.waveformAreaSelectBegan(atX: 750, extending: true)
    model.waveformAreaSelectChanged(toX: 750)  // focus sample 150000
    model.waveformAreaSelectEnded(toX: 750)
    // Anchor edge (word 2's start, 70648) is preserved; the focus moves to the dragged sample.
    expectNoDifference(model.audioSelection, 70648..<150000)
  }

  // MARK: - Playhead

  @Test func releaseSnapsPlayheadScrollsTranscriptAndLeavesTransportStopped() {
    let model = editor()
    geometry(model)
    model.waveformAreaSelectBegan(atX: 350, extending: false)
    model.waveformAreaSelectChanged(toX: 600)
    expectNoDifference(model.transcript.reveal, nil)  // no transcript scroll mid-drag
    model.waveformAreaSelectEnded(toX: 600)
    // Exact range start (not word-snapped 70648)
    expectNoDifference(model.playheadEditedSample, 70000)
    expectNoDifference(model.transportPhase, .stopped)
    // Release scrolls the transcript to the range's first overlapping word (word 2).
    expectNoDifference(model.transcript.reveal?.wordID, 2)
  }

  @Test func playheadSnapIsSuppressedMidDragThenCommittedOnRelease() async {
    let model = editor()
    geometry(model)
    model.playheadEditedSample = 999
    model.waveformAreaSelectBegan(atX: 350, extending: false)
    model.waveformAreaSelectChanged(toX: 600)  // audioSelection 70000..<120000
    // Simulate the view's deferred selection→playhead snap firing mid-drag: it must bail.
    let token = model.cursorMoveToken
    await model.transportSelectionChanged(model.audioSelection, cursorToken: token)
    expectNoDifference(model.playheadEditedSample, 999)  // still suppressed
    model.waveformAreaSelectEnded(toX: 600)
    expectNoDifference(model.playheadEditedSample, 70000)  // committed once on release
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
      expectNoDifference(model.audioSelection, 180000..<200000)  // clamped to the right edge
      await clock.advance(by: .milliseconds(16))  // one auto-scroll tick
      #expect(model.editedWaveform.visibleStartSample > 0)  // the viewport scrolled right
      // The scroll revealed more audio, and the marquee's far edge extended past the old edge.
      #expect(model.audioSelection.map { $0.upperBound > 200_000 } ?? false)
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
      let before = model.editedWaveform.visibleStartSample
      await clock.advance(by: .milliseconds(16))  // one tick
      #expect(model.editedWaveform.visibleStartSample < before)  // scrolled toward the start
      await clock.advance(by: .seconds(1))  // many ticks — must clamp, not overrun
      // Pinned at the document start.
      expectNoDifference(model.editedWaveform.visibleStartSample, 0)
      expectNoDifference(model.audioSelection?.lowerBound, 0)  // far edge reached sample 0
      model.waveformAreaSelectEnded(toX: -50)
    }
  }

  @Test func leftwardShiftDragExtendsFromTheExistingAnchor() {
    let model = editor()
    geometry(model)
    model.transcript.selectWord(5)  // seeds audioSelection to word 5 (120966..<135960)
    model.waveformAreaSelectBegan(atX: 400, extending: true)
    model.waveformAreaSelectChanged(toX: 360)  // focus sample 72000, left of the anchor edge
    model.waveformAreaSelectEnded(toX: 360)
    // The anchor edge (word 5's start, 120966) is preserved; the focus moves left to the dragged
    // sample, so the range spans 72000..<120966.
    expectNoDifference(model.audioSelection, 72000..<120966)
    expectNoDifference(model.selectionAnchorSample, 120966)
  }

  @Test func aDragThatStaysInsideTheViewportNeverAutoScrolls() async {
    let clock = TestClock()
    let model = editor(clock: clock)
    geometry(model)
    await withMainSerialExecutor {
      model.waveformAreaSelectBegan(atX: 350, extending: false)
      model.waveformAreaSelectChanged(toX: 600)  // fully inside the viewport
      await clock.advance(by: .milliseconds(64))
      expectNoDifference(model.editedWaveform.visibleStartSample, 0)  // no scroll task ever started
      model.waveformAreaSelectEnded(toX: 600)
    }
  }

  // MARK: - Geometry guard

  @Test func areaSelectIsANoOpBeforeGeometryLoads() {
    let model = editor()  // no geometry → totalSamples 0, hasUsableGeometry false
    model.waveformAreaSelectBegan(atX: 350, extending: false)
    model.waveformAreaSelectChanged(toX: 600)
    model.waveformAreaSelectEnded(toX: 600)
    expectNoDifference(model.audioSelection, nil)
  }
}
