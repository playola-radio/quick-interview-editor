import CoreGraphics
import Dependencies
import Foundation
import IssueReporting
import Observation

/// All waveform geometry, zoom, and hit-testing math for the editor — the sample↔pixel
/// core the app's trust depends on. Owns only geometry state; it does not know transcript
/// semantics. ``EditorModel`` mediates: it derives selection/red ranges from the transcript
/// and turns them into spans via `span(for:)`, and maps a tapped x back to a word.
/// `playheadSample` is the one value pushed in (from the playback stream). Every coordinate
/// is in PLAN samples.
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

  /// Current playback position, pushed in from the playback stream; nil when stopped.
  var playheadSample: Int?

  // MARK: - Display Text
  let caption = "WAVEFORM"
  let loadingMessage = "Loading waveform…"
  let emptyMessage = "No audio loaded."
  let zoomInLabel = "Zoom in"
  let zoomOutLabel = "Zoom out"

  // MARK: - Constants
  private let minSamplesPerPixel = 8.0
  private let zoomStep = 2.0

  // MARK: - View Helpers
  var hasWaveform: Bool { waveform != nil && totalSamples > 0 }
  var showsWaveform: Bool { hasWaveform && !isLoading }
  var showsLoading: Bool { isLoading }
  var showsEmpty: Bool { !hasWaveform && !isLoading }
  var canZoomIn: Bool {
    showsWaveform && samplesPerPixel > minEffectiveSamplesPerPixel() + .ulpOfOne
  }
  var canZoomOut: Bool { showsWaveform && samplesPerPixel < fitSamplesPerPixel() - .ulpOfOne }

  /// Plan samples currently visible across the viewport.
  var visibleSampleCount: Int {
    guard viewportWidth > 0, samplesPerPixel > 0 else { return 0 }
    return Int((Double(viewportWidth) * samplesPerPixel).rounded())
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
    for pixel in 0..<columnCount {
      let start = visibleStartSample + Int((Double(pixel) * samplesPerPixel).rounded(.down))
      let end = visibleStartSample + Int((Double(pixel + 1) * samplesPerPixel).rounded(.down))
      let lo = max(0, min(start, totalSamples))
      let hi = max(0, min(end, totalSamples))
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

  /// Horizontal extent of a plan-sample range in view coordinates, clipped to the
  /// viewport; nil when the range is empty or entirely off-screen.
  func span(for range: Range<Int>) -> WaveformSpan? {
    guard viewportWidth > 0, range.lowerBound < range.upperBound else { return nil }
    let clippedStart = max(0, sampleToX(range.lowerBound))
    let clippedEnd = min(viewportWidth, sampleToX(range.upperBound))
    guard clippedEnd > clippedStart else { return nil }
    return WaveformSpan(positionX: clippedStart, width: clippedEnd - clippedStart)
  }

  var playheadX: CGFloat? {
    guard let playheadSample, viewportWidth > 0 else { return nil }
    let posX = sampleToX(playheadSample)
    guard posX >= 0, posX <= viewportWidth else { return nil }
    return posX
  }

  // MARK: - Coordinate transforms
  func sampleToX(_ sample: Int) -> CGFloat {
    guard samplesPerPixel > 0 else { return 0 }
    return CGFloat(Double(sample - visibleStartSample) / samplesPerPixel)
  }

  /// Plan sample at the left edge of pixel `x`. Floor semantics: `x` covers
  /// `[floor(x·spp), floor((x+1)·spp))` offset by `visibleStartSample`.
  func xToSample(_ posX: CGFloat) -> Int {
    visibleStartSample + Int((Double(posX) * samplesPerPixel).rounded(.down))
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

  func viewportResized(width: CGFloat) {
    let wasUnset = viewportWidth <= 0
    viewportWidth = width
    if wasUnset || samplesPerPixel <= 0 { samplesPerPixel = fitSamplesPerPixel() }
    samplesPerPixel = clampedSamplesPerPixel(samplesPerPixel)
    visibleStartSample = clampedStart(visibleStartSample)
  }

  func zoomInTapped() { zoom(by: 1 / zoomStep) }
  func zoomOutTapped() { zoom(by: zoomStep) }

  func scrolled(toStartSample start: Int) {
    visibleStartSample = clampedStart(start)
  }

  /// Drag-to-pan: records the anchor when a horizontal drag begins so subsequent
  /// `dragScrolled` calls pan relative to it (dragging right reveals earlier audio).
  func dragScrollBegan() { dragAnchorStartSample = visibleStartSample }
  func dragScrolled(byPixels deltaX: CGFloat) {
    scrolled(toStartSample: dragAnchorStartSample - Int(Double(deltaX) * samplesPerPixel))
  }

  // MARK: - Private Helpers
  private func zoom(by factor: Double) {
    guard viewportWidth > 0, totalSamples > 0 else { return }
    let center = visibleStartSample + visibleSampleCount / 2
    samplesPerPixel = clampedSamplesPerPixel(samplesPerPixel * factor)
    visibleStartSample = clampedStart(center - visibleSampleCount / 2)
  }

  private func fitSamplesPerPixel() -> Double {
    guard viewportWidth > 0, totalSamples > 0 else { return 1 }
    return Double(totalSamples) / Double(viewportWidth)
  }

  private func minEffectiveSamplesPerPixel() -> Double {
    min(minSamplesPerPixel, fitSamplesPerPixel())
  }

  private func clampedSamplesPerPixel(_ spp: Double) -> Double {
    min(max(spp, minEffectiveSamplesPerPixel()), fitSamplesPerPixel())
  }

  private func clampedStart(_ start: Int) -> Int {
    let maxStart = max(0, totalSamples - visibleSampleCount)
    return min(max(start, 0), maxStart)
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
