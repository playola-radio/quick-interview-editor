import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct WaveformViewportTests {

  // MARK: - Fit / clamp

  @Test func fitSamplesPerPixelDividesAxisCountByViewportWidth() {
    expectNoDifference(
      WaveformViewport.fitSamplesPerPixel(viewportWidth: 1000, axis: 0..<100_000), 100)
  }

  @Test func fitSamplesPerPixelDefaultsToOneWhenDegenerate() {
    expectNoDifference(WaveformViewport.fitSamplesPerPixel(viewportWidth: 0, axis: 0..<100), 1)
    expectNoDifference(WaveformViewport.fitSamplesPerPixel(viewportWidth: 100, axis: 0..<0), 1)
  }

  @Test func clampedSamplesPerPixelRaisesBelowMinimum() {
    // fit = 1_000_000 / 1000 = 1000; minEffective = min(8, 1000) = 8.
    expectNoDifference(
      WaveformViewport.clampedSamplesPerPixel(2, viewportWidth: 1000, axis: 0..<1_000_000), 8)
  }

  @Test func clampedSamplesPerPixelCapsAtFit() {
    // fit = 100_000 / 1000 = 100.
    expectNoDifference(
      WaveformViewport.clampedSamplesPerPixel(500, viewportWidth: 1000, axis: 0..<100_000), 100)
  }

  @Test func visibleSampleCountMultipliesWidthBySamplesPerPixel() {
    expectNoDifference(
      WaveformViewport.visibleSampleCount(viewportWidth: 1000, samplesPerPixel: 100), 100_000)
  }

  @Test func clampedStartClampsToLowerBoundAndMaxStart() {
    // visibleSampleCount = 100 * 50 = 5000; maxStart = 10_000 - 5000 = 5000.
    expectNoDifference(
      WaveformViewport.clampedStart(
        -100, viewportWidth: 100, samplesPerPixel: 50, axis: 0..<10_000), 0)
    expectNoDifference(
      WaveformViewport.clampedStart(
        99_999, viewportWidth: 100, samplesPerPixel: 50, axis: 0..<10_000), 5000)
  }

  // MARK: - Coordinate transforms

  @Test func sampleToXAndXToSampleRoundTrip() {
    expectNoDifference(
      WaveformViewport.sampleToX(2500, visibleStartSample: 2000, samplesPerPixel: 100), 5)
    expectNoDifference(
      WaveformViewport.xToSample(5, visibleStartSample: 2000, samplesPerPixel: 100), 2500)
  }

  @Test func xToSampleFloorsFractionalPixels() {
    // pixel 5 covers [500, 600); a fractional x floors to the left-edge sample.
    expectNoDifference(
      WaveformViewport.xToSample(5.99, visibleStartSample: 0, samplesPerPixel: 100), 599)
  }

  // MARK: - Zoom

  @Test func zoomByFactorAnchorsOnCursorSample() {
    // Mirrors WaveformTests' scrolledWithCommandDownZoomsAnchoredAtX vector.
    let result = WaveformViewport.zoomByFactor(
      0.5, anchoredAtX: 400, viewportWidth: 1000, axis: 0..<1_000_000, samplesPerPixel: 100,
      visibleStartSample: 200_000)
    expectNoDifference(result.samplesPerPixel, 50)
    expectNoDifference(result.visibleStartSample, 220_000)
  }

  @Test func zoomByFactorClampsAtMinimum() {
    let result = WaveformViewport.zoomByFactor(
      0.01, anchoredAtX: 500, viewportWidth: 1000, axis: 0..<1_000_000, samplesPerPixel: 16,
      visibleStartSample: 0)
    expectNoDifference(result.samplesPerPixel, 8)
  }

  @Test func zoomByFactorCentersAndClamps() {
    let result = WaveformViewport.zoom(
      by: 0.5, viewportWidth: 100, axis: 0..<10_000, samplesPerPixel: 100,
      visibleStartSample: 0)
    expectNoDifference(result.samplesPerPixel, 50)
    expectNoDifference(result.visibleStartSample, 2500)
  }

  // MARK: - Pan

  @Test func panByPixelsMovesByPixelsTimesSamplesPerPixel() {
    expectNoDifference(
      WaveformViewport.panByPixels(-10, samplesPerPixel: 100, visibleStartSample: 500_000),
      501_000)
  }

  // MARK: - Zoom to fit

  @Test func zoomToFitCentersTheRangeEdgeToEdge() {
    let result = WaveformViewport.zoomToFit(
      400_000..<600_000, paddingFraction: 0, viewportWidth: 1000, axis: 0..<1_000_000)
    expectNoDifference(result.samplesPerPixel, 200)
    expectNoDifference(result.visibleStartSample, 400_000)
  }

  @Test func zoomToFitPaddingLeavesBreathingRoom() {
    let result = WaveformViewport.zoomToFit(
      400_000..<600_000, paddingFraction: 0.1, viewportWidth: 1000, axis: 0..<1_000_000)
    expectNoDifference(result.samplesPerPixel, 240)
    expectNoDifference(result.visibleStartSample, 380_000)
  }

  // MARK: - Scroll-wheel interpretation

  @Test func scrollPanPixelsPassesThroughPreciseDeltas() {
    expectNoDifference(
      WaveformViewport.scrollPanPixels(deltaX: 10, deltaY: 0, hasPreciseDeltas: true), 10)
  }

  @Test func scrollPanPixelsScalesImpreciseDeltasByPointsPerLine() {
    expectNoDifference(
      WaveformViewport.scrollPanPixels(deltaX: 1, deltaY: 0, hasPreciseDeltas: false), 40)
  }

  @Test func scrollZoomFactorConvertsDeltaYToADoublingFactor() {
    expectNoDifference(
      WaveformViewport.scrollZoomFactor(deltaY: 300, hasPreciseDeltas: true), 0.5)
  }

  // MARK: - Coexistence of range-aware axes (merge guardrail)

  /// Regression guard for the merge that made `WaveformViewport` range-aware: the SAME math must
  /// serve BOTH callers' axes in one run. `WaveformModel` passes a #49 slice-pinned sub-range with
  /// a NON-zero lower bound; `EditedWaveformAdapter` passes a 0-anchored edited axis. Same span
  /// count (600_000) ⇒ identical fit; different lower bounds ⇒ the scroll floor differs (the pinned
  /// axis clamps up to 200_000, the edited axis clamps down to 0), which is the whole point.
  @Test func rangeAwareAxisServesBothPinnedAndZeroAnchoredAxes() {
    // #49 slice-pinned sub-range: viewport pinned to 200_000..<800_000 (count 600_000).
    let pinned = 200_000..<800_000
    expectNoDifference(
      WaveformViewport.fitSamplesPerPixel(viewportWidth: 1000, axis: pinned), 600)
    // visibleSampleCount = 1000 * 100 = 100_000; maxStart = 800_000 - 100_000 = 700_000.
    // A start BELOW the pinned lower bound snaps UP to 200_000 — NOT to 0.
    expectNoDifference(
      WaveformViewport.clampedStart(
        100_000, viewportWidth: 1000, samplesPerPixel: 100, axis: pinned), 200_000)
    // A start past the end snaps to maxStart.
    expectNoDifference(
      WaveformViewport.clampedStart(
        999_999, viewportWidth: 1000, samplesPerPixel: 100, axis: pinned), 700_000)

    // Edited-timeline 0-anchored axis of the SAME length: identical fit, but the floor is 0 —
    // matching the pre-merge behavior exactly.
    let edited = 0..<600_000
    expectNoDifference(
      WaveformViewport.fitSamplesPerPixel(viewportWidth: 1000, axis: edited), 600)
    // maxStart = 600_000 - 100_000 = 500_000; a negative start snaps down to 0.
    expectNoDifference(
      WaveformViewport.clampedStart(
        -100, viewportWidth: 1000, samplesPerPixel: 100, axis: edited), 0)
    expectNoDifference(
      WaveformViewport.clampedStart(
        999_999, viewportWidth: 1000, samplesPerPixel: 100, axis: edited), 500_000)
  }
}
