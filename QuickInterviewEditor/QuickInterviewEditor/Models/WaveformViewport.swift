import CoreGraphics
import Foundation

/// Pure viewport math for the waveform: zoom/pan/clamp/fit/coordinate-transform formulas,
/// parameterized by `viewportWidth` and an `axis` — the half-open sample range the viewport
/// may cover. The axis need not start at 0: `WaveformModel` passes its `navigableRange` (the
/// whole file, or a slice-pinned sub-window with a non-zero lower bound), while
/// `EditedWaveformAdapter` passes `0..<editedDurationSamples`. Fit/clamp are relative to the
/// axis's bounds (its `count` for zoom-to-fit, its `lowerBound` as the scroll floor). This is a
/// stateless helper — `WaveformModel` owns the `@Observable` viewport state
/// (`visibleStartSample`, `samplesPerPixel`, …) and calls into these functions with its current
/// values, assigning the results back to its own stored properties. Kept axis-agnostic (rather
/// than hardcoded to `totalSamples`) so both the source and the edited/collapsed axis reuse the
/// identical rules without duplicating this math.
enum WaveformViewport {

  // MARK: - Constants
  static let minSamplesPerPixel = 8.0
  static let zoomStep = 2.0
  /// Points a line-based mouse wheel "click" is worth (trackpads report pixel-precise deltas
  /// already). Pan/zoom sensitivity constants; on-screen direction verified in QA.
  static let pointsPerScrollLine: CGFloat = 40
  static let pixelsPerZoomDouble = 300.0

  // MARK: - Fit / clamp

  static func fitSamplesPerPixel(viewportWidth: CGFloat, axis: Range<Int>) -> Double {
    guard viewportWidth > 0, axis.count > 0 else { return 1 }
    return Double(axis.count) / Double(viewportWidth)
  }

  static func minEffectiveSamplesPerPixel(viewportWidth: CGFloat, axis: Range<Int>) -> Double {
    min(minSamplesPerPixel, fitSamplesPerPixel(viewportWidth: viewportWidth, axis: axis))
  }

  static func clampedSamplesPerPixel(_ spp: Double, viewportWidth: CGFloat, axis: Range<Int>)
    -> Double
  {
    min(
      max(spp, minEffectiveSamplesPerPixel(viewportWidth: viewportWidth, axis: axis)),
      fitSamplesPerPixel(viewportWidth: viewportWidth, axis: axis))
  }

  /// Samples currently visible across the viewport at `samplesPerPixel`.
  static func visibleSampleCount(viewportWidth: CGFloat, samplesPerPixel: Double) -> Int {
    guard viewportWidth > 0, samplesPerPixel > 0 else { return 0 }
    return Int((Double(viewportWidth) * samplesPerPixel).rounded())
  }

  static func clampedStart(
    _ start: Int, viewportWidth: CGFloat, samplesPerPixel: Double, axis: Range<Int>
  ) -> Int {
    let maxStart = max(
      axis.lowerBound,
      axis.upperBound
        - visibleSampleCount(viewportWidth: viewportWidth, samplesPerPixel: samplesPerPixel)
    )
    return min(max(start, axis.lowerBound), maxStart)
  }

  // MARK: - Coordinate transforms

  static func sampleToX(_ sample: Int, visibleStartSample: Int, samplesPerPixel: Double)
    -> CGFloat
  {
    guard samplesPerPixel > 0 else { return 0 }
    return CGFloat(Double(sample - visibleStartSample) / samplesPerPixel)
  }

  /// Plan sample at the left edge of pixel `x`. Floor semantics: `x` covers
  /// `[floor(x·spp), floor((x+1)·spp))` offset by `visibleStartSample`.
  static func xToSample(_ posX: CGFloat, visibleStartSample: Int, samplesPerPixel: Double) -> Int {
    visibleStartSample + Int((Double(posX) * samplesPerPixel).rounded(.down))
  }

  // MARK: - Zoom / pan

  /// Center-anchored zoom: multiplies `samplesPerPixel` by `factor`, then re-centers the
  /// viewport on the sample that was at its center beforehand.
  static func zoom(
    by factor: Double, viewportWidth: CGFloat, axis: Range<Int>, samplesPerPixel: Double,
    visibleStartSample: Int
  ) -> (samplesPerPixel: Double, visibleStartSample: Int) {
    let visibleCount = visibleSampleCount(
      viewportWidth: viewportWidth, samplesPerPixel: samplesPerPixel)
    let center = visibleStartSample + visibleCount / 2
    let newSamplesPerPixel = clampedSamplesPerPixel(
      samplesPerPixel * factor, viewportWidth: viewportWidth, axis: axis)
    let newVisibleCount = visibleSampleCount(
      viewportWidth: viewportWidth, samplesPerPixel: newSamplesPerPixel)
    let newStart = clampedStart(
      center - newVisibleCount / 2, viewportWidth: viewportWidth,
      samplesPerPixel: newSamplesPerPixel, axis: axis)
    return (newSamplesPerPixel, newStart)
  }

  // swiftlint:disable function_parameter_count
  /// Multiplies zoom by `factor` (clamped) while keeping the sample under view-x `cursorX`
  /// pinned to `cursorX`. Recomputed from the current invariant, so repeated small wheel
  /// deltas don't accumulate drift.
  static func zoomByFactor(
    _ factor: Double, anchoredAtX cursorX: CGFloat, viewportWidth: CGFloat, axis: Range<Int>,
    samplesPerPixel: Double, visibleStartSample: Int
  ) -> (samplesPerPixel: Double, visibleStartSample: Int) {
    let sampleUnderCursor = Double(visibleStartSample) + Double(cursorX) * samplesPerPixel
    let newSamplesPerPixel = clampedSamplesPerPixel(
      samplesPerPixel * factor, viewportWidth: viewportWidth, axis: axis)
    let newStart = clampedStart(
      Int((sampleUnderCursor - Double(cursorX) * newSamplesPerPixel).rounded()),
      viewportWidth: viewportWidth, samplesPerPixel: newSamplesPerPixel, axis: axis)
    return (newSamplesPerPixel, newStart)
  }
  // swiftlint:enable function_parameter_count

  /// Target start sample for panning by `deltaX` pixels' worth of samples (unclamped —
  /// callers that need file-bounds clamping run it through `clampedStart`).
  static func panByPixels(_ deltaX: CGFloat, samplesPerPixel: Double, visibleStartSample: Int)
    -> Int
  {
    visibleStartSample - Int((Double(deltaX) * samplesPerPixel).rounded())
  }

  /// Frames `range` in the viewport. `paddingFraction` leaves that fraction of the range as
  /// breathing room on each side (0.1 ⇒ the range fills the middle ~83% of the width); 0
  /// fills edge-to-edge.
  static func zoomToFit(
    _ range: Range<Int>, paddingFraction: Double, viewportWidth: CGFloat, axis: Range<Int>
  ) -> (samplesPerPixel: Double, visibleStartSample: Int) {
    let padded = Double(range.count) * (1 + 2 * max(0, paddingFraction))
    let newSamplesPerPixel = clampedSamplesPerPixel(
      padded / Double(viewportWidth), viewportWidth: viewportWidth, axis: axis)
    let center = range.lowerBound + range.count / 2
    let newVisibleCount = visibleSampleCount(
      viewportWidth: viewportWidth, samplesPerPixel: newSamplesPerPixel)
    let newStart = clampedStart(
      center - newVisibleCount / 2, viewportWidth: viewportWidth,
      samplesPerPixel: newSamplesPerPixel, axis: axis)
    return (newSamplesPerPixel, newStart)
  }

  // MARK: - Scroll-wheel interpretation

  static func scrollPanPixels(
    deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool
  ) -> CGFloat {
    let primary = abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
    return hasPreciseDeltas ? primary : primary * pointsPerScrollLine
  }

  static func scrollZoomFactor(deltaY: CGFloat, hasPreciseDeltas: Bool) -> Double {
    let dy = Double(hasPreciseDeltas ? deltaY : deltaY * pointsPerScrollLine)
    // spp *= factor; scrolling "away" should zoom in (spp < 1). Flip the sign in QA if inverted.
    return pow(2.0, -dy / pixelsPerZoomDouble)
  }
}
