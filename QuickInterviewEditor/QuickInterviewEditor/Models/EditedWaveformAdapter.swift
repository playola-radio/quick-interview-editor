import CoreGraphics
import Foundation
import Observation

/// Waveform geometry and hit-testing on the EDITED (collapsed) axis, composed from three
/// existing, tested pieces: ``WaveformModel`` (stays source-pure — the pyramid it owns never
/// moves) supplies peaks per SOURCE range; ``EditedTimeline`` maps SOURCE↔EDITED coordinates
/// and reports which source ranges a pixel's edited window touches; ``WaveformViewport``
/// supplies the zoom/pan/clamp/fit formulas, reused here with `axis: 0..<editedDurationSamples`
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
  /// When set, confines the viewport (fit / zoom / scroll / pan / columns) to a sub-range of the
  /// EDITED axis — the collapsed extent of one slice for the Edit Slice modal. nil means the whole
  /// edited timeline, so the main editor's geometry is unchanged. Configuration set alongside
  /// `timeline`; every setter re-clamps through observed viewport state, so it needs no observation.
  @ObservationIgnored private var navigableEditedRange: Range<Int>?

  // MARK: - Initialization
  init(source: WaveformModel, timeline: EditedTimeline) {
    self.source = source
    self.timeline = timeline
  }

  /// The effective navigable axis for all viewport math: the pin clamped into the current edited
  /// duration, or the whole edited timeline when unpinned. Empty when a removal collapses the whole
  /// pinned slice — callers gate on `!isEmpty` and never widen back to the global axis.
  private var navigableRange: Range<Int> {
    guard let range = navigableEditedRange else { return 0..<max(0, editedDurationSamples) }
    let lower = max(0, min(range.lowerBound, editedDurationSamples))
    let upper = max(lower, min(range.upperBound, editedDurationSamples))
    return lower..<upper
  }

  /// Pins (or unpins, with nil) the viewport to a slice's collapsed extent. Clears any armed Z
  /// restore — a viewport captured under the previous pin (a different slice, or this slice before
  /// a removal changed its edited span) must not be restored into the new one — then re-clamps the
  /// zoom+scroll into the new axis without otherwise resetting them.
  func setNavigableEditedRange(_ range: Range<Int>?) {
    navigableEditedRange = range
    fitRestore = nil
    timelineChanged()
  }

  // MARK: - View Helpers
  var editedDurationSamples: Int { timeline.editedDurationSamples }
  /// True once the geometry is meaningful enough to map a view-x back to an edited sample: the
  /// source waveform is loaded, the edited timeline has nonzero length, the viewport has been
  /// measured, and a real samples-per-pixel is set.
  var hasUsableGeometry: Bool {
    source.hasWaveform && navigableRange.count > 0 && viewportWidth > 0 && samplesPerPixel > 0
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

  /// The lane renders the SOURCE waveform's load/empty state on the edited axis — the edited
  /// waveform is loading/empty exactly when its source is — so these pass straight through.
  var showsLoading: Bool { source.showsLoading }
  var showsEmpty: Bool { source.showsEmpty }
  var loadingMessage: String { source.loadingMessage }
  var emptyMessage: String { source.emptyMessage }
  var amplitudeScale: CGFloat { source.amplitudeScale }

  func viewportResized(width: CGFloat) {
    let wasUnset = viewportWidth <= 0
    viewportWidth = width
    if wasUnset || samplesPerPixel <= 0 { samplesPerPixel = fitSamplesPerPixel() }
    samplesPerPixel = clampedSamplesPerPixel(samplesPerPixel)
    visibleStartSample = clampedStart(visibleStartSample)
  }

  /// Re-clamps the viewport into the freshly rebuilt timeline's edited duration after removals
  /// change, WITHOUT resetting zoom: only pins `samplesPerPixel` and `visibleStartSample` back
  /// into the valid range so a collapse (or restore) can't strand the viewport past the new end.
  func timelineChanged() {
    guard viewportWidth > 0, navigableRange.count > 0, samplesPerPixel > 0 else { return }
    samplesPerPixel = clampedSamplesPerPixel(samplesPerPixel)
    visibleStartSample = clampedStart(visibleStartSample)
  }

  /// Applies a live crossfade-stretch preview atomically: renders `timeline` and moves the viewport
  /// to `targetVisibleStart` (clamped into the navigable axis), so the stretched seam grows about a
  /// fixed screen center while everything downstream reflows continuously. Timeline and viewport
  /// move in lockstep, which makes committing the same length a visual no-op (no reposition on
  /// release). No zoom change and no armed-`Z` reset — a drag isn't a fit.
  func previewStretch(timeline previewTimeline: EditedTimeline, targetVisibleStart: Int) {
    timeline = previewTimeline
    visibleStartSample = clampedStart(targetVisibleStart)
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
      let lo = max(navigableRange.lowerBound, min(start, navigableRange.upperBound))
      let hi = max(navigableRange.lowerBound, min(end, navigableRange.upperBound))
      guard hi > lo, let peak = mergedSourcePeak(forEdited: lo..<hi) else { continue }
      columns.append(WaveformColumn(positionX: CGFloat(pixel), min: peak.min, max: peak.max))
    }
    return columns
  }

  /// View-x of a SOURCE sample, or nil when it falls outside the viewport (or maps nowhere at
  /// all) — for source-anchored geometry like the selection edge handles.
  func viewX(forSource sourceSample: Int) -> CGFloat? {
    guard viewportWidth > 0, let posX = sourceSampleToX(sourceSample) else { return nil }
    guard posX >= 0, posX <= viewportWidth else { return nil }
    return posX
  }

  /// View-x of the persistent playhead cursor for an EDITED sample, or nil when it falls outside
  /// the viewport.
  func playheadX(forEdited editedSample: Int) -> CGFloat? {
    guard viewportWidth > 0 else { return nil }
    let posX = editedSampleToX(editedSample)
    guard posX >= 0, posX <= viewportWidth else { return nil }
    return posX
  }

  /// Horizontal extent of a SOURCE range in view coordinates, clipped to the viewport; nil when
  /// the range maps to no kept audio (the whole source range fell inside a removal) or is entirely
  /// off-screen. Uses the timeline's edited footprint — the union of every kept segment the source
  /// range overlaps — so a boundary landing inside a crossfaded removal keeps the crossfade tail
  /// instead of snapping short of it (matching the overview pin).
  func span(forSource sourceRange: Range<Int>) -> WaveformSpan? {
    guard let footprint = timeline.editedFootprint(ofSource: sourceRange) else { return nil }
    return span(forEdited: footprint)
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

  /// The bowtie span for a seam, mapped to view-x. A crossfaded seam covers
  /// `editedCrossfadeStart..<(editedCrossfadeStart + crossfadeLength)`. A zero-length (fully
  /// clamped) seam — a removal at sample 0 or EOF, or an adjacent seam that lost a shared island —
  /// collapses to a zero-width span at the join: the bowtie renders as a thin hard-cut marker and,
  /// crucially, stays selectable (and therefore restorable) rather than becoming an invisible
  /// dead-end. Nil only when the seam sits entirely off-screen.
  func spanForSeam(_ seam: TimelineSeam) -> WaveformSpan? {
    guard seam.crossfadeLength > 0 else {
      let positionX = editedSampleToX(seam.editedCrossfadeStart)
      guard positionX >= 0, positionX <= viewportWidth else { return nil }
      return WaveformSpan(positionX: positionX, width: 0)
    }
    return span(
      forEdited: seam.editedCrossfadeStart..<(seam.editedCrossfadeStart + seam.crossfadeLength))
  }

  /// A draft bowtie span for an in-progress stretch: `previewLength` samples wide, grown
  /// symmetrically about the seam's current edited center so the bowtie widens/narrows live while
  /// the underlying waveform stays put (it reflows only on commit). A zero-length draft collapses
  /// to the same zero-width hard-cut marker `spanForSeam` draws.
  func spanForSeam(_ seam: TimelineSeam, previewLength: Int) -> WaveformSpan? {
    guard previewLength > 0 else {
      let positionX = editedSampleToX(seam.editedCrossfadeCenter)
      guard positionX >= 0, positionX <= viewportWidth else { return nil }
      return WaveformSpan(positionX: positionX, width: 0)
    }
    let start = seam.editedCrossfadeCenter - previewLength / 2
    return span(forEdited: start..<(start + previewLength))
  }

  /// The view-x of a seam's two crossfade edges — the draggable stretch handles — each nil when it
  /// falls outside the viewport. Unlike the drawn bowtie span (which is CLIPPED to the viewport, so
  /// a partly-scrolled crossfade's boundary snaps to the viewport edge), a handle must sit on the
  /// TRUE edge or nowhere: a clipped boundary is not a grabbable edge, and placing a handle there
  /// would both swallow gestures at the viewport edge and stretch against a phantom coordinate.
  /// `previewLength` overrides the committed length during a live drag, mirroring `spanForSeam`.
  /// A zero-length hard cut collapses both edges onto the join (grabbable when visible, so a hard
  /// cut can be dragged out into a fade).
  func seamHandleXs(_ seam: TimelineSeam, previewLength: Int?) -> (
    leading: CGFloat?, trailing: CGFloat?
  ) {
    let start: Int
    let length: Int
    if let previewLength {
      length = previewLength
      start = seam.editedCrossfadeCenter - previewLength / 2
    } else {
      length = seam.crossfadeLength
      start = seam.editedCrossfadeStart
    }
    return (visibleEdgeX(start), visibleEdgeX(start + length))
  }

  /// The view-x of an edited sample, or nil when it maps outside the viewport — the per-edge basis
  /// for `seamHandleXs`, matching `viewX(forSource:)`'s nil-when-off-screen contract.
  private func visibleEdgeX(_ editedSample: Int) -> CGFloat? {
    guard viewportWidth > 0 else { return nil }
    let posX = editedSampleToX(editedSample)
    guard posX >= 0, posX <= viewportWidth else { return nil }
    return posX
  }

  // MARK: - Coordinate transforms
  func editedSampleToX(_ editedSample: Int) -> CGFloat {
    WaveformViewport.sampleToX(
      editedSample, visibleStartSample: visibleStartSample, samplesPerPixel: samplesPerPixel)
  }

  /// EDITED sample at the left edge of pixel `x`. Floor semantics, matching `WaveformModel`.
  /// Clamped into the navigable axis so a click on a pixel that spills past a pinned slice's edited
  /// extent resolves to the slice's own boundary, not audio beyond it.
  func xToEditedSample(_ posX: CGFloat) -> Int {
    let raw = WaveformViewport.xToSample(
      posX, visibleStartSample: visibleStartSample, samplesPerPixel: samplesPerPixel)
    return max(navigableRange.lowerBound, min(raw, navigableRange.upperBound))
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
    guard viewportWidth > 0, !navigableRange.isEmpty, factor > 0 else { return }
    fitRestore = nil
    let result = WaveformViewport.zoomByFactor(
      factor, anchoredAtX: cursorX, viewportWidth: viewportWidth, axis: navigableRange,
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
    guard viewportWidth > 0, !navigableRange.isEmpty else { return }
    let clampedLower = max(navigableRange.lowerBound, editedRange.lowerBound)
    let clampedUpper = min(navigableRange.upperBound, editedRange.upperBound)
    guard clampedLower < clampedUpper else { return }
    let clamped = clampedLower..<clampedUpper
    if paddingFraction > 0 { fitRestore = nil }
    let result = WaveformViewport.zoomToFit(
      clamped, paddingFraction: paddingFraction, viewportWidth: viewportWidth,
      axis: navigableRange)
    samplesPerPixel = result.samplesPerPixel
    visibleStartSample = result.visibleStartSample
  }

  /// Frames a SOURCE range on the edited axis: maps its bounds through the timeline into edited
  /// coordinates (clamped into kept space), then fits that edited range. "Reveal" reasons in
  /// source coordinates, so it hands a source range here rather than pre-converting.
  func zoomToFitSource(_ sourceRange: Range<Int>, paddingFraction: Double = 0) {
    guard let editedRange = editedRange(forSource: sourceRange) else { return }
    zoomToFitEdited(editedRange, paddingFraction: paddingFraction)
  }

  /// Logic's `Z`: fit on the first press (the source selection if any, else the whole edited
  /// timeline), restore the prior zoom+scroll on the next consecutive press. The restore is keyed
  /// on the SOURCE selection identity — the coordinate space the caller reasons about — not the
  /// EDITED range derived from it.
  func zoomFitToggled(sourceSelection: Range<Int>?) {
    guard viewportWidth > 0, !navigableRange.isEmpty else { return }
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
    // Same kept-segment footprint the highlight uses, so `Z` fits exactly what `span(forSource:)`
    // draws — a boundary landing inside a crossfaded removal keeps the crossfade tail rather than
    // fitting a range short of it.
    timeline.editedFootprint(ofSource: sourceRange)
  }

  private func zoomToFitAllEdited() {
    guard viewportWidth > 0, !navigableRange.isEmpty else { return }
    samplesPerPixel = clampedSamplesPerPixel(fitSamplesPerPixel())
    visibleStartSample = clampedStart(navigableRange.lowerBound)
  }

  private func zoom(by factor: Double) {
    guard viewportWidth > 0, !navigableRange.isEmpty else { return }
    fitRestore = nil
    let result = WaveformViewport.zoom(
      by: factor, viewportWidth: viewportWidth, axis: navigableRange,
      samplesPerPixel: samplesPerPixel, visibleStartSample: visibleStartSample)
    samplesPerPixel = result.samplesPerPixel
    visibleStartSample = result.visibleStartSample
  }

  private func fitSamplesPerPixel() -> Double {
    WaveformViewport.fitSamplesPerPixel(viewportWidth: viewportWidth, axis: navigableRange)
  }

  private func minEffectiveSamplesPerPixel() -> Double {
    WaveformViewport.minEffectiveSamplesPerPixel(viewportWidth: viewportWidth, axis: navigableRange)
  }

  private func clampedSamplesPerPixel(_ spp: Double) -> Double {
    WaveformViewport.clampedSamplesPerPixel(spp, viewportWidth: viewportWidth, axis: navigableRange)
  }

  private func clampedStart(_ start: Int) -> Int {
    WaveformViewport.clampedStart(
      start, viewportWidth: viewportWidth, samplesPerPixel: samplesPerPixel, axis: navigableRange)
  }

  private struct FitRestore {
    var samplesPerPixel: Double
    var visibleStartSample: Int
    var sourceSelection: Range<Int>?
  }
}

/// The edited/collapsed axis drives ``WaveformLaneView`` in the main editor. The lane's
/// `forSource:` requirements are literal here — every read maps SOURCE↔EDITED through the
/// timeline — and the cursor axis is EDITED, so the playhead reads need no mapping at all.
extension EditedWaveformAdapter: WaveformLaneDriving {
  func laneSpan(forSource sourceRange: Range<Int>) -> WaveformSpan? {
    span(forSource: sourceRange)
  }

  func laneX(forSource sourceSample: Int) -> CGFloat? {
    viewX(forSource: sourceSample)
  }

  func lanePlayheadX(forCursor cursorSample: Int) -> CGFloat? {
    playheadX(forEdited: cursorSample)
  }
}
