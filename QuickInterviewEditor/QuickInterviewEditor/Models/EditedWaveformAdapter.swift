import CoreGraphics
import Foundation
import Observation

/// Waveform geometry and hit-testing on the EDITED (collapsed) axis, composed from three
/// existing, tested pieces: ``WaveformModel`` (stays source-pure — the pyramid it owns never
/// moves) supplies peaks per SOURCE range; ``EditedTimeline`` maps SOURCE↔EDITED coordinates
/// and reports which source ranges a pixel's edited window touches; ``WaveformViewport``
/// supplies the zoom/pan/clamp/fit formulas, reused here with `duration: editedDurationSamples`
/// instead of the source's total length. This adapter owns its own EDITED viewport state —
/// it never reads or writes `source`'s `visibleStartSample`/`samplesPerPixel`.
@MainActor
@Observable
final class EditedWaveformAdapter {

  // MARK: - Composed pieces
  let source: WaveformModel
  /// Rebuilt by the owner whenever removals change; cheap to construct (see ``EditedTimeline``).
  var timeline: EditedTimeline

  // MARK: - Properties
  /// Pixel width of the waveform view, reported by the view on layout.
  var viewportWidth: CGFloat = 0
  /// Zoom: EDITED samples represented by one horizontal pixel. Larger = more zoomed out.
  var samplesPerPixel: Double = 1
  /// EDITED-sample index at the left edge of the viewport.
  var visibleStartSample = 0
  /// Zoom+scroll captured by `zoomFitToggled` so a second Z press can restore it, keyed on the
  /// SOURCE selection identity (the selection the caller reasons about) rather than the derived
  /// EDITED range, so the same source selection restores even if the timeline is rebuilt with
  /// identical geometry in between.
  @ObservationIgnored private var fitRestore: FitRestore?

  // MARK: - Initialization
  init(source: WaveformModel, timeline: EditedTimeline) {
    self.source = source
    self.timeline = timeline
  }

  // MARK: - View Helpers
  var editedDurationSamples: Int { timeline.editedDurationSamples }
  /// True once the geometry is meaningful enough to map a view-x back to an edited sample: the
  /// source waveform is loaded, the edited timeline has nonzero length, the viewport has been
  /// measured, and a real samples-per-pixel is set.
  var hasUsableGeometry: Bool {
    source.hasWaveform && editedDurationSamples > 0 && viewportWidth > 0 && samplesPerPixel > 0
  }
  /// EDITED samples currently visible across the viewport.
  var visibleSampleCount: Int {
    WaveformViewport.visibleSampleCount(
      viewportWidth: viewportWidth, samplesPerPixel: samplesPerPixel)
  }
  var canZoomIn: Bool {
    hasUsableGeometry && samplesPerPixel > minEffectiveSamplesPerPixel() + .ulpOfOne
  }
  var canZoomOut: Bool { hasUsableGeometry && samplesPerPixel < fitSamplesPerPixel() - .ulpOfOne }

  func viewportResized(width: CGFloat) {
    let wasUnset = viewportWidth <= 0
    viewportWidth = width
    if wasUnset || samplesPerPixel <= 0 { samplesPerPixel = fitSamplesPerPixel() }
    samplesPerPixel = clampedSamplesPerPixel(samplesPerPixel)
    visibleStartSample = clampedStart(visibleStartSample)
  }

  // MARK: - Rendering
  /// One min/max column per horizontal pixel on the EDITED axis. Each pixel's EDITED sample
  /// window is translated to one or more SOURCE ranges via `timeline.sourceRanges(forEdited:)`
  /// (more than one when the pixel straddles a seam), and the source pyramid's peak for each
  /// range is merged (min of mins, max of maxs — never averaged). Reads only this adapter's own
  /// observed viewport state plus `timeline` and `source`'s waveform data — never a playhead —
  /// so a 30 Hz playhead tick never invalidates it.
  func visibleColumns() -> [WaveformColumn] {
    guard hasUsableGeometry, viewportWidth >= 1 else { return [] }
    let columnCount = Int(viewportWidth.rounded(.up))
    var columns: [WaveformColumn] = []
    columns.reserveCapacity(columnCount)
    for pixel in 0..<columnCount {
      let start = visibleStartSample + Int((Double(pixel) * samplesPerPixel).rounded(.down))
      let end = visibleStartSample + Int((Double(pixel + 1) * samplesPerPixel).rounded(.down))
      let lo = max(0, min(start, editedDurationSamples))
      let hi = max(0, min(end, editedDurationSamples))
      guard hi > lo, let peak = mergedSourcePeak(forEdited: lo..<hi) else { continue }
      columns.append(WaveformColumn(positionX: CGFloat(pixel), min: peak.min, max: peak.max))
    }
    return columns
  }

  /// View-x of the persistent playhead cursor for a SOURCE sample, or nil when it falls outside
  /// the viewport (or maps nowhere at all).
  func playheadX(forSource sourceSample: Int) -> CGFloat? {
    guard viewportWidth > 0, let posX = sourceSampleToX(sourceSample) else { return nil }
    guard posX >= 0, posX <= viewportWidth else { return nil }
    return posX
  }

  /// Horizontal extent of a SOURCE range in view coordinates, clipped to the viewport; nil when
  /// the mapped EDITED range is empty (e.g. the whole source range fell inside a removal) or
  /// entirely off-screen. `startBias`/`endBias` resolve either boundary should it land inside a
  /// removed span rather than a kept segment.
  func span(
    forSource sourceRange: Range<Int>, startBias: MappingBias = .leftEdge,
    endBias: MappingBias = .rightEdge
  ) -> WaveformSpan? {
    guard sourceRange.lowerBound < sourceRange.upperBound,
      let editedStart = timeline.sourceToEdited(sourceRange.lowerBound, bias: startBias),
      let editedEnd = timeline.sourceToEdited(sourceRange.upperBound, bias: endBias),
      editedStart < editedEnd
    else { return nil }
    return span(forEdited: editedStart..<editedEnd)
  }

  /// Horizontal extent of an EDITED range in view coordinates, clipped to the viewport; nil when
  /// the range is empty or entirely off-screen.
  func span(forEdited editedRange: Range<Int>) -> WaveformSpan? {
    guard viewportWidth > 0, editedRange.lowerBound < editedRange.upperBound else { return nil }
    let clippedStart = max(0, editedSampleToX(editedRange.lowerBound))
    let clippedEnd = min(viewportWidth, editedSampleToX(editedRange.upperBound))
    guard clippedEnd > clippedStart else { return nil }
    return WaveformSpan(positionX: clippedStart, width: clippedEnd - clippedStart)
  }

  /// The bowtie span for a crossfaded seam: `editedCenter..<(editedCenter + crossfadeLength)`,
  /// mapped to view-x. Nil for a zero-length (fully clamped) crossfade — there's nothing to draw.
  func spanForSeam(_ seam: TimelineSeam) -> WaveformSpan? {
    span(forEdited: seam.editedCenter..<(seam.editedCenter + seam.crossfadeLength))
  }

  // MARK: - Coordinate transforms
  func editedSampleToX(_ editedSample: Int) -> CGFloat {
    WaveformViewport.sampleToX(
      editedSample, visibleStartSample: visibleStartSample, samplesPerPixel: samplesPerPixel)
  }

  /// EDITED sample at the left edge of pixel `x`. Floor semantics, matching `WaveformModel`.
  func xToEditedSample(_ posX: CGFloat) -> Int {
    WaveformViewport.xToSample(
      posX, visibleStartSample: visibleStartSample, samplesPerPixel: samplesPerPixel)
  }

  /// SOURCE sample at the left edge of pixel `x` — for clicks/marquee/ruler, which reason about
  /// the original recording, not the collapsed timeline.
  func xToSourceSample(_ posX: CGFloat) -> Int {
    timeline.editedToSource(xToEditedSample(posX))
  }

  /// View-x for a SOURCE sample. `bias` resolves the position when `sourceSample` falls inside a
  /// removed span (where there is no 1:1 edited position); nil only if `bias` is
  /// `.nilInsideRemoval` and it does.
  func sourceSampleToX(_ sourceSample: Int, bias: MappingBias = .nearest) -> CGFloat? {
    guard let editedSample = timeline.sourceToEdited(sourceSample, bias: bias) else { return nil }
    return editedSampleToX(editedSample)
  }

  // MARK: - User Actions (zoom / pan / fit)
  func zoomInTapped() { zoom(by: 1 / WaveformViewport.zoomStep) }
  func zoomOutTapped() { zoom(by: WaveformViewport.zoomStep) }

  func scrolled(toStartEditedSample start: Int) {
    fitRestore = nil
    visibleStartSample = clampedStart(start)
  }

  func panByPixels(_ deltaX: CGFloat) {
    scrolled(
      toStartEditedSample: WaveformViewport.panByPixels(
        deltaX, samplesPerPixel: samplesPerPixel, visibleStartSample: visibleStartSample))
  }

  /// Multiplies zoom by `factor` (clamped) while keeping the EDITED sample under view-x
  /// `cursorX` pinned to `cursorX`.
  func zoomByFactor(_ factor: Double, anchoredAtX cursorX: CGFloat) {
    guard viewportWidth > 0, editedDurationSamples > 0, factor > 0 else { return }
    fitRestore = nil
    let result = WaveformViewport.zoomByFactor(
      factor, anchoredAtX: cursorX, viewportWidth: viewportWidth, duration: editedDurationSamples,
      samplesPerPixel: samplesPerPixel, visibleStartSample: visibleStartSample)
    samplesPerPixel = result.samplesPerPixel
    visibleStartSample = result.visibleStartSample
  }

  // swiftlint:disable function_parameter_count
  func scrolled(
    deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool,
    optionDown: Bool, commandDown: Bool, atX positionX: CGFloat
  ) {
    guard deltaX.isFinite, deltaY.isFinite else { return }
    if commandDown {
      zoomByFactor(
        WaveformViewport.scrollZoomFactor(deltaY: deltaY, hasPreciseDeltas: hasPreciseDeltas),
        anchoredAtX: positionX)
    } else {
      panByPixels(
        WaveformViewport.scrollPanPixels(
          deltaX: deltaX, deltaY: deltaY, hasPreciseDeltas: hasPreciseDeltas))
    }
  }
  // swiftlint:enable function_parameter_count

  /// Frames `editedRange` in the viewport. `paddingFraction` leaves that fraction of the range as
  /// breathing room on each side; the default of 0 fills edge-to-edge so `zoomFitToggled`'s `Z`
  /// behavior is unchanged. A padded fit (a reveal, not the `Z` toggle) invalidates any armed
  /// restore, same as `WaveformModel.zoomToFit`.
  func zoomToFitEdited(_ editedRange: Range<Int>, paddingFraction: Double = 0) {
    guard viewportWidth > 0, editedDurationSamples > 0,
      editedRange.lowerBound < editedRange.upperBound
    else { return }
    if paddingFraction > 0 { fitRestore = nil }
    let result = WaveformViewport.zoomToFit(
      editedRange, paddingFraction: paddingFraction, viewportWidth: viewportWidth,
      duration: editedDurationSamples)
    samplesPerPixel = result.samplesPerPixel
    visibleStartSample = result.visibleStartSample
  }

  /// Logic's `Z`: fit on the first press (the source selection if any, else the whole edited
  /// timeline), restore the prior zoom+scroll on the next consecutive press. The restore is keyed
  /// on the SOURCE selection identity — the coordinate space the caller reasons about — not the
  /// EDITED range derived from it.
  func zoomFitToggled(sourceSelection: Range<Int>?) {
    guard viewportWidth > 0, editedDurationSamples > 0 else { return }
    if let restore = fitRestore, restore.sourceSelection == sourceSelection {
      samplesPerPixel = clampedSamplesPerPixel(restore.samplesPerPixel)
      visibleStartSample = clampedStart(restore.visibleStartSample)
      fitRestore = nil
      return
    }
    fitRestore = FitRestore(
      samplesPerPixel: samplesPerPixel, visibleStartSample: visibleStartSample,
      sourceSelection: sourceSelection)
    if let sourceSelection, let editedRange = editedRange(forSource: sourceSelection) {
      zoomToFitEdited(editedRange)
    } else {
      zoomToFitAllEdited()
    }
  }

  // MARK: - Private Helpers
  private func mergedSourcePeak(forEdited editedRange: Range<Int>) -> (min: Float, max: Float)? {
    var merged: (min: Float, max: Float)?
    for sourceRange in timeline.sourceRanges(forEdited: editedRange) {
      guard let peak = source.sourcePeak(in: sourceRange, samplesPerPixel: samplesPerPixel) else {
        continue
      }
      if let current = merged {
        merged = (Swift.min(current.min, peak.min), Swift.max(current.max, peak.max))
      } else {
        merged = peak
      }
    }
    return merged
  }

  private func editedRange(forSource sourceRange: Range<Int>) -> Range<Int>? {
    guard let start = timeline.sourceToEdited(sourceRange.lowerBound, bias: .leftEdge),
      let end = timeline.sourceToEdited(sourceRange.upperBound, bias: .rightEdge), start < end
    else { return nil }
    return start..<end
  }

  private func zoomToFitAllEdited() {
    guard viewportWidth > 0, editedDurationSamples > 0 else { return }
    samplesPerPixel = clampedSamplesPerPixel(fitSamplesPerPixel())
    visibleStartSample = clampedStart(0)
  }

  private func zoom(by factor: Double) {
    guard viewportWidth > 0, editedDurationSamples > 0 else { return }
    fitRestore = nil
    let result = WaveformViewport.zoom(
      by: factor, viewportWidth: viewportWidth, duration: editedDurationSamples,
      samplesPerPixel: samplesPerPixel, visibleStartSample: visibleStartSample)
    samplesPerPixel = result.samplesPerPixel
    visibleStartSample = result.visibleStartSample
  }

  private func fitSamplesPerPixel() -> Double {
    WaveformViewport.fitSamplesPerPixel(
      viewportWidth: viewportWidth, duration: editedDurationSamples)
  }

  private func minEffectiveSamplesPerPixel() -> Double {
    WaveformViewport.minEffectiveSamplesPerPixel(
      viewportWidth: viewportWidth, duration: editedDurationSamples)
  }

  private func clampedSamplesPerPixel(_ spp: Double) -> Double {
    WaveformViewport.clampedSamplesPerPixel(
      spp, viewportWidth: viewportWidth, duration: editedDurationSamples)
  }

  private func clampedStart(_ start: Int) -> Int {
    WaveformViewport.clampedStart(
      start, viewportWidth: viewportWidth, samplesPerPixel: samplesPerPixel,
      duration: editedDurationSamples)
  }

  private struct FitRestore {
    var samplesPerPixel: Double
    var visibleStartSample: Int
    var sourceSelection: Range<Int>?
  }
}
