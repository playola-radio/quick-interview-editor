import CoreGraphics
import Dependencies
import Foundation
import IssueReporting
import Observation

/// All waveform geometry, zoom, and hit-testing math for the editor — the sample↔pixel
/// core the app's trust depends on. Owns only geometry state; it does not know transcript
/// semantics or where the playhead is. ``EditorModel`` mediates: it derives selection/red
/// ranges from the transcript and turns them into spans via `span(for:)`, maps a tapped x
/// back to a word, and asks for the cursor's x via `playheadX(for:)`. Every coordinate is in
/// PLAN samples.
@MainActor
@Observable
final class WaveformModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.waveform) var waveformClient

  // MARK: - Initialization
  override init() { super.init() }

  // MARK: - Properties
  var waveform: Waveform?
  var isLoading = false
  var totalSamples = 0
  var sampleRate = 44100

  /// Pixel width of the waveform view, reported by the view on layout.
  var viewportWidth: CGFloat = 0
  /// Zoom: plan samples represented by one horizontal pixel. Larger = more zoomed out.
  var samplesPerPixel: Double = 1
  /// Plan-sample index at the left edge of the viewport.
  var visibleStartSample = 0
  /// `visibleStartSample` captured at the start of a drag-pan gesture.
  @ObservationIgnored private var dragAnchorStartSample = 0
  /// The navigable extent of the lane, in plan samples: `nil` ⇒ the whole file (the main editor);
  /// a window ⇒ the lane is pinned to it, so the slice-edit sheet shows ONLY the slice — you cannot
  /// scroll or zoom past its start/end. Reads still resolve against the shared full-file pyramid in
  /// absolute samples; this bounds the viewport only.
  @ObservationIgnored private var contentRange: Range<Int>?
  /// Zoom+scroll captured by `zoomFitToggled` so a second Z press can restore it, along with
  /// the selection that was fitted — restore only applies if the selection hasn't changed.
  /// Cleared by any manual zoom/pan so the next Z fits fresh instead of restoring stale state.
  @ObservationIgnored private var fitRestore: FitRestore?

  // MARK: - Display Text
  let caption = "WAVEFORM"
  let loadingMessage = "Loading waveform…"
  let emptyMessage = "No audio loaded."
  let zoomInLabel = "Zoom in"
  let zoomOutLabel = "Zoom out"

  // MARK: - View Helpers
  var hasWaveform: Bool { waveform != nil && totalSamples > 0 }
  var showsWaveform: Bool { hasWaveform && !isLoading }
  /// True once the geometry is meaningful enough to map a view-x back to a plan sample: the file is
  /// loaded (not mid-decode), its length is known, the viewport has been measured, and a real
  /// samples-per-pixel is set. `load` sets `totalSamples` before awaiting the decode while
  /// `samplesPerPixel` is still the default 1, so `!isLoading` is what keeps a ruler click during
  /// that window from storing a garbage cursor.
  var hasUsableGeometry: Bool {
    !isLoading && totalSamples > 0 && viewportWidth > 0 && samplesPerPixel > 0
  }
  var showsLoading: Bool { isLoading }
  var showsEmpty: Bool { !hasWaveform && !isLoading }
  var canZoomIn: Bool {
    showsWaveform && samplesPerPixel > minEffectiveSamplesPerPixel() + .ulpOfOne
  }
  var canZoomOut: Bool { showsWaveform && samplesPerPixel < fitSamplesPerPixel() - .ulpOfOne }

  /// Plan samples currently visible across the viewport.
  var visibleSampleCount: Int {
    WaveformViewport.visibleSampleCount(
      viewportWidth: viewportWidth, samplesPerPixel: samplesPerPixel)
  }

  /// One min/max column per horizontal pixel, read from the pyramid level whose bucket
  /// size best matches the current zoom. Each pixel covers plan samples
  /// `[floor(px·spp), floor((px+1)·spp))` from `visibleStartSample`, clamped to the file.
  func visibleColumns() -> [WaveformColumn] {
    guard let waveform, waveform.baseLevel != nil, showsWaveform, viewportWidth >= 1,
      samplesPerPixel > 0
    else { return [] }
    let level = pyramidLevel(for: samplesPerPixel, in: waveform)
    let columnCount = Int(viewportWidth.rounded(.up))
    var columns: [WaveformColumn] = []
    columns.reserveCapacity(columnCount)
    // Clamp reads to the navigable range (the whole file for the main editor; the slice for a
    // pinned sheet) so a right-edge column — `columnCount` is `ceil(width)`, so the last pixel can
    // spill past the content — never draws audio from beyond the pinned slice.
    let bounds = navigableRange
    for pixel in 0..<columnCount {
      let start = visibleStartSample + Int((Double(pixel) * samplesPerPixel).rounded(.down))
      let end = visibleStartSample + Int((Double(pixel + 1) * samplesPerPixel).rounded(.down))
      let lo = max(bounds.lowerBound, min(start, bounds.upperBound))
      let hi = max(bounds.lowerBound, min(end, bounds.upperBound))
      guard hi > lo else { continue }
      let peak = level.peak(in: lo..<hi)
      columns.append(WaveformColumn(positionX: CGFloat(pixel), min: peak.min, max: peak.max))
    }
    return columns
  }

  /// One min/max column per pixel across an arbitrary plan-sample `window`, rendered at a
  /// fixed `pixelWidth` (independent of the main viewport/zoom). Used by the fine-tune insets:
  /// the window is a fixed ±0.5 s span, so samples-per-pixel is constant, and pixels whose
  /// sample range falls past the file edge are omitted (they render blank, not rescaled).
  func columns(in window: Range<Int>, pixelWidth: CGFloat) -> [WaveformColumn] {
    guard let waveform, waveform.baseLevel != nil, totalSamples > 0, pixelWidth >= 1,
      window.lowerBound < window.upperBound
    else { return [] }
    let spp = Double(window.count) / Double(pixelWidth)
    guard spp > 0 else { return [] }
    let level = pyramidLevel(for: spp, in: waveform)
    let columnCount = Int(pixelWidth.rounded(.up))
    var columns: [WaveformColumn] = []
    columns.reserveCapacity(columnCount)
    for pixel in 0..<columnCount {
      let start = window.lowerBound + Int((Double(pixel) * spp).rounded(.down))
      let end = window.lowerBound + Int((Double(pixel + 1) * spp).rounded(.down))
      let lo = max(0, min(start, totalSamples))
      let hi = max(0, min(end, totalSamples))
      guard hi > lo else { continue }
      let peak = level.peak(in: lo..<hi)
      columns.append(WaveformColumn(positionX: CGFloat(pixel), min: peak.min, max: peak.max))
    }
    return columns
  }

  /// Min/max of the source peak pyramid across a SOURCE range at the given zoom, or nil if
  /// unavailable. Source-only — the pyramid stays source-indexed; callers rendering an edited
  /// axis compose this per kept-segment source sub-range.
  func sourcePeak(in sourceRange: Range<Int>, samplesPerPixel: Double) -> (min: Float, max: Float)?
  {
    guard let waveform, waveform.baseLevel != nil, samplesPerPixel > 0,
      sourceRange.lowerBound < sourceRange.upperBound
    else { return nil }
    let level = pyramidLevel(for: samplesPerPixel, in: waveform)
    let lo = max(0, min(sourceRange.lowerBound, totalSamples))
    let hi = max(0, min(sourceRange.upperBound, totalSamples))
    guard hi > lo else { return nil }
    return level.peak(in: lo..<hi)
  }

  /// Horizontal extent of a plan-sample range in view coordinates, clipped to the
  /// viewport; nil when the range is empty or entirely off-screen.
  func span(for range: Range<Int>) -> WaveformSpan? {
    guard viewportWidth > 0, range.lowerBound < range.upperBound else { return nil }
    let clippedStart = max(0, sampleToX(range.lowerBound))
    let clippedEnd = min(viewportWidth, sampleToX(range.upperBound))
    guard clippedEnd > clippedStart else { return nil }
    return WaveformSpan(positionX: clippedStart, width: clippedEnd - clippedStart)
  }

  /// View-x of the persistent playhead cursor at `sample`, or nil when it falls outside the
  /// viewport. Pure geometry — ``EditorModel`` owns the cursor sample and asks for its x.
  func playheadX(for sample: Int) -> CGFloat? {
    guard viewportWidth > 0 else { return nil }
    let posX = sampleToX(sample)
    guard posX >= 0, posX <= viewportWidth else { return nil }
    return posX
  }

  // MARK: - Coordinate transforms
  func sampleToX(_ sample: Int) -> CGFloat {
    WaveformViewport.sampleToX(
      sample, visibleStartSample: visibleStartSample, samplesPerPixel: samplesPerPixel)
  }

  /// Plan sample at the left edge of pixel `x`. Floor semantics: `x` covers
  /// `[floor(x·spp), floor((x+1)·spp))` offset by `visibleStartSample`.
  func xToSample(_ posX: CGFloat) -> Int {
    WaveformViewport.xToSample(
      posX, visibleStartSample: visibleStartSample, samplesPerPixel: samplesPerPixel)
  }

  // MARK: - User Actions
  /// Idempotent: a second call (e.g. the view re-appearing on a tab switch) is a no-op
  /// once the pyramid is built or while it's building, so long files aren't re-decoded.
  func load(url: URL, planSampleRate: Int, durationSamples: Int) async {
    guard waveform == nil, !isLoading else { return }
    // A degenerate plan (rate/duration <= 0) would pass garbage to AVFoundation; show the
    // empty state instead. Other code clamps these for labels; the waveform bails.
    guard planSampleRate > 0, durationSamples > 0 else { return }
    sampleRate = planSampleRate
    totalSamples = durationSamples
    isLoading = true
    defer { isLoading = false }
    do {
      waveform = try await waveformClient.loadWaveform(url, planSampleRate, durationSamples)
    } catch is CancellationError {
      // The view went away mid-decode; stay unloaded and retry when it reappears.
    } catch {
      reportIssue(error)
    }
    if viewportWidth > 0 { samplesPerPixel = clampedSamplesPerPixel(fitSamplesPerPixel()) }
  }

  /// Seeds this model from an ALREADY-decoded waveform (shared from another model) instead of
  /// decoding via the client, then normalizes geometry the way `load` does. Used by the slice-edit
  /// sheet: it borrows the main editor's decoded pyramid rather than re-decoding the file, so it
  /// gets a fully-interactive lane (zoom/scroll/ruler) for free. Sharing the same `Waveform` value
  /// between two models is safe — its pyramid arrays are read-only here. `contentRange`, when given,
  /// pins the navigable extent to that window (the sheet shows ONLY the slice); `nil` navigates the
  /// whole file. The initial fit frames the navigable range: immediately if the viewport is already
  /// measured, otherwise on the first `viewportResized` (its `wasUnset` fit already uses it).
  func adopt(waveform: Waveform?, totalSamples: Int, sampleRate: Int, contentRange: Range<Int>?) {
    self.waveform = waveform
    self.totalSamples = totalSamples
    self.sampleRate = sampleRate
    self.contentRange = contentRange
    isLoading = false
    // A fresh seed invalidates any armed Z-restore: a snapshot taken against the pre-adopt (often
    // empty, mid-decode) geometry must not be restorable after the real waveform is framed.
    fitRestore = nil
    if viewportWidth > 0 { zoomToFitAll() }
  }

  func viewportResized(width: CGFloat) {
    let wasUnset = viewportWidth <= 0
    viewportWidth = width
    if wasUnset || samplesPerPixel <= 0 { samplesPerPixel = fitSamplesPerPixel() }
    samplesPerPixel = clampedSamplesPerPixel(samplesPerPixel)
    visibleStartSample = clampedStart(visibleStartSample)
  }

  func zoomInTapped() { zoom(by: 1 / WaveformViewport.zoomStep) }
  func zoomOutTapped() { zoom(by: WaveformViewport.zoomStep) }

  func scrolled(toStartSample start: Int) {
    fitRestore = nil
    visibleStartSample = clampedStart(start)
  }

  /// Drag-to-pan: records the anchor when a horizontal drag begins so subsequent
  /// `dragScrolled` calls pan relative to it (dragging right reveals earlier audio).
  func dragScrollBegan() { dragAnchorStartSample = visibleStartSample }
  func dragScrolled(byPixels deltaX: CGFloat) {
    guard deltaX.isFinite else { return }
    scrolled(
      toStartSample: WaveformViewport.panByPixels(
        deltaX, samplesPerPixel: samplesPerPixel, visibleStartSample: dragAnchorStartSample))
  }

  /// Multiplies zoom by `factor` (clamped) while keeping the plan sample under view-x
  /// `cursorX` pinned to `cursorX`. Recomputes from the current invariant each call, so
  /// repeated small wheel deltas don't accumulate drift.
  func zoomByFactor(_ factor: Double, anchoredAtX cursorX: CGFloat) {
    guard viewportWidth > 0, totalSamples > 0, factor > 0 else { return }
    fitRestore = nil
    let result = WaveformViewport.zoomByFactor(
      factor, anchoredAtX: cursorX, viewportWidth: viewportWidth, axis: navigableRange,
      samplesPerPixel: samplesPerPixel, visibleStartSample: visibleStartSample)
    samplesPerPixel = result.samplesPerPixel
    visibleStartSample = result.visibleStartSample
  }

  /// Pans the viewport by `deltaX` pixels' worth of samples (clamped to the file).
  func panByPixels(_ deltaX: CGFloat) {
    scrolled(
      toStartSample: WaveformViewport.panByPixels(
        deltaX, samplesPerPixel: samplesPerPixel, visibleStartSample: visibleStartSample))
  }

  // swiftlint:disable function_parameter_count
  /// Wheel/trackpad on the waveform. Holding ⌘ while scrolling ⇒ cursor-anchored horizontal
  /// zoom; a plain scroll (no ⌘) ⇒ horizontal pan. ⌘ is a single modifier that a Magic Mouse
  /// swipe reliably carries, matching how Logic users reach for zoom. `optionDown` is accepted
  /// for forward-compatibility but does not affect the decision. Interpretation lives here,
  /// not the view.
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

  func zoomToFitAll() {
    guard viewportWidth > 0, navigableRange.count > 0 else { return }
    samplesPerPixel = clampedSamplesPerPixel(fitSamplesPerPixel())
    visibleStartSample = clampedStart(navigableRange.lowerBound)
  }

  /// Frames `range` in the viewport. `paddingFraction` leaves that fraction of the range as
  /// breathing room on each side (0.1 ⇒ the range fills the middle ~83% of the width); the
  /// default of 0 fills edge-to-edge, so `zoomFitToggled`'s `Z` behavior is unchanged.
  func zoomToFit(_ range: Range<Int>, paddingFraction: Double = 0) {
    guard viewportWidth > 0, totalSamples > 0, range.lowerBound < range.upperBound else { return }
    // A padded fit is a reveal (click a suggestion/clip), not the `Z` toggle — invalidate any
    // armed restore like every other manual zoom/pan does, so the next `Z` fits fresh instead
    // of jumping back to a pre-fit viewport. The `Z` path calls this with paddingFraction 0 and
    // manages `fitRestore` itself, so it must not be cleared here.
    if paddingFraction > 0 { fitRestore = nil }
    let result = WaveformViewport.zoomToFit(
      range, paddingFraction: paddingFraction, viewportWidth: viewportWidth, axis: navigableRange)
    samplesPerPixel = result.samplesPerPixel
    visibleStartSample = result.visibleStartSample
  }

  /// Logic's `Z`: fit on the first press (selection if any, else whole file), restore the
  /// prior zoom+scroll on the next consecutive press.
  func zoomFitToggled(selection: Range<Int>?) {
    guard viewportWidth > 0, totalSamples > 0 else { return }
    if let restore = fitRestore, restore.selection == selection {
      samplesPerPixel = clampedSamplesPerPixel(restore.samplesPerPixel)
      visibleStartSample = clampedStart(restore.visibleStartSample)
      fitRestore = nil
      return
    }
    fitRestore = FitRestore(
      samplesPerPixel: samplesPerPixel, visibleStartSample: visibleStartSample,
      selection: selection)
    if let selection { zoomToFit(selection) } else { zoomToFitAll() }
  }

  // MARK: - Private Helpers
  private func zoom(by factor: Double) {
    guard viewportWidth > 0, totalSamples > 0 else { return }
    fitRestore = nil
    let result = WaveformViewport.zoom(
      by: factor, viewportWidth: viewportWidth, axis: navigableRange,
      samplesPerPixel: samplesPerPixel, visibleStartSample: visibleStartSample)
    samplesPerPixel = result.samplesPerPixel
    visibleStartSample = result.visibleStartSample
  }

  /// The plan-sample range the viewport may cover: the pinned `contentRange` when set, else the
  /// whole file. A set pin is clamped into `[0, totalSamples]` but is NEVER widened back to the
  /// whole file when degenerate — a pinned lane that can't resolve a real window stays inert (empty)
  /// rather than silently exposing the entire file, preserving the pin invariant.
  private var navigableRange: Range<Int> {
    guard let contentRange else { return 0..<max(0, totalSamples) }
    let lower = max(0, min(contentRange.lowerBound, totalSamples))
    let upper = max(lower, min(contentRange.upperBound, totalSamples))
    return lower..<upper
  }

  private func fitSamplesPerPixel() -> Double {
    WaveformViewport.fitSamplesPerPixel(viewportWidth: viewportWidth, axis: navigableRange)
  }

  private func minEffectiveSamplesPerPixel() -> Double {
    WaveformViewport.minEffectiveSamplesPerPixel(
      viewportWidth: viewportWidth, axis: navigableRange)
  }

  private func clampedSamplesPerPixel(_ spp: Double) -> Double {
    WaveformViewport.clampedSamplesPerPixel(
      spp, viewportWidth: viewportWidth, axis: navigableRange)
  }

  private func clampedStart(_ start: Int) -> Int {
    WaveformViewport.clampedStart(
      start, viewportWidth: viewportWidth, samplesPerPixel: samplesPerPixel, axis: navigableRange)
  }

  private struct FitRestore {
    var samplesPerPixel: Double
    var visibleStartSample: Int
    var selection: Range<Int>?
  }

  /// The coarsest level whose bucket size doesn't exceed `spp` (so each pixel aggregates
  /// as few whole buckets as possible); level 0 when zoomed in past the base resolution.
  /// Falls back to an empty level for a degenerate (levels-empty) waveform rather than
  /// trapping.
  private func pyramidLevel(for spp: Double, in waveform: Waveform) -> Waveform.Level {
    guard var chosen = waveform.levels.first else {
      return Waveform.Level(bucketSize: Waveform.baseBucketSize, mins: [], maxs: [])
    }
    for level in waveform.levels {
      if Double(level.bucketSize) <= spp { chosen = level } else { break }
    }
    return chosen
  }
}

/// A source-axis model drives ``WaveformLaneView`` directly in the slice-edit sheet (pinned to a
/// slice's sub-range via `navigableRange`). There a source sample IS a plan sample, so the lane's
/// `forSource:` requirements forward to the plain source-coordinate methods.
extension WaveformModel: WaveformLaneDriving {
  func laneSpan(forSource sourceRange: Range<Int>) -> WaveformSpan? {
    span(for: sourceRange)
  }

  func lanePlayheadX(forSource sourceSample: Int) -> CGFloat? {
    playheadX(for: sourceSample)
  }
}

extension Waveform.Level {
  /// Min/max amplitude across a plan-sample range, resolved to this level's buckets:
  /// floor for the start bucket, end-exclusive for the last. Clamped to the bucket array.
  func peak(in samples: Range<Int>) -> (min: Float, max: Float) {
    guard bucketSize > 0, !mins.isEmpty, samples.lowerBound < samples.upperBound else {
      return (0, 0)
    }
    let firstBucket = max(0, min(samples.lowerBound / bucketSize, mins.count - 1))
    let lastBucket = max(0, min((samples.upperBound - 1) / bucketSize, mins.count - 1))
    var low = mins[firstBucket]
    var high = maxs[firstBucket]
    if lastBucket > firstBucket {
      for bucket in (firstBucket + 1)...lastBucket {
        low = min(low, mins[bucket])
        high = max(high, maxs[bucket])
      }
    }
    return (low, high)
  }
}

/// One vertical min/max slice of the waveform at a horizontal pixel; amplitudes are
/// normalized -1...1 and mapped to the view's height at draw time.
struct WaveformColumn: Equatable {
  var positionX: CGFloat
  var min: Float
  var max: Float
}

/// A horizontal band (highlight, red overlay) in view coordinates, clipped to the viewport.
struct WaveformSpan: Equatable {
  var positionX: CGFloat
  var width: CGFloat
}
