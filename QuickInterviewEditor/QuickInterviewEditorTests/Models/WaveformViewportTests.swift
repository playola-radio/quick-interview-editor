import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct WaveformViewportTests {

  // MARK: - Fit / clamp

  @Test func fitSamplesPerPixelDividesDurationByViewportWidth() {
    expectNoDifference(
      WaveformViewport.fitSamplesPerPixel(viewportWidth: 1000, duration: 100_000), 100)
  }

  @Test func fitSamplesPerPixelDefaultsToOneWhenDegenerate() {
    expectNoDifference(WaveformViewport.fitSamplesPerPixel(viewportWidth: 0, duration: 100), 1)
    expectNoDifference(WaveformViewport.fitSamplesPerPixel(viewportWidth: 100, duration: 0), 1)
  }

  @Test func clampedSamplesPerPixelRaisesBelowMinimum() {
    // fit = 1_000_000 / 1000 = 1000; minEffective = min(8, 1000) = 8.
    expectNoDifference(
      WaveformViewport.clampedSamplesPerPixel(2, viewportWidth: 1000, duration: 1_000_000), 8)
  }

  @Test func clampedSamplesPerPixelCapsAtFit() {
    // fit = 100_000 / 1000 = 100.
    expectNoDifference(
      WaveformViewport.clampedSamplesPerPixel(500, viewportWidth: 1000, duration: 100_000), 100)
  }

  @Test func visibleSampleCountMultipliesWidthBySamplesPerPixel() {
    expectNoDifference(
      WaveformViewport.visibleSampleCount(viewportWidth: 1000, samplesPerPixel: 100), 100_000)
  }

  @Test func clampedStartClampsToZeroAndMaxStart() {
    // visibleSampleCount = 100 * 50 = 5000; maxStart = 10_000 - 5000 = 5000.
    expectNoDifference(
      WaveformViewport.clampedStart(
        -100, viewportWidth: 100, samplesPerPixel: 50, duration: 10_000), 0)
    expectNoDifference(
      WaveformViewport.clampedStart(
        99_999, viewportWidth: 100, samplesPerPixel: 50, duration: 10_000), 5000)
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
      0.5, anchoredAtX: 400, viewportWidth: 1000, duration: 1_000_000, samplesPerPixel: 100,
      visibleStartSample: 200_000)
    expectNoDifference(result.samplesPerPixel, 50)
    expectNoDifference(result.visibleStartSample, 220_000)
  }

  @Test func zoomByFactorClampsAtMinimum() {
    let result = WaveformViewport.zoomByFactor(
      0.01, anchoredAtX: 500, viewportWidth: 1000, duration: 1_000_000, samplesPerPixel: 16,
      visibleStartSample: 0)
    expectNoDifference(result.samplesPerPixel, 8)
  }

  @Test func zoomByFactorCentersAndClamps() {
    let result = WaveformViewport.zoom(
      by: 0.5, viewportWidth: 100, duration: 10_000, samplesPerPixel: 100,
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
      400_000..<600_000, paddingFraction: 0, viewportWidth: 1000, duration: 1_000_000)
    expectNoDifference(result.samplesPerPixel, 200)
    expectNoDifference(result.visibleStartSample, 400_000)
  }

  @Test func zoomToFitPaddingLeavesBreathingRoom() {
    let result = WaveformViewport.zoomToFit(
      400_000..<600_000, paddingFraction: 0.1, viewportWidth: 1000, duration: 1_000_000)
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
}
