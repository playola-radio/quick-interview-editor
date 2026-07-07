import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct WaveformTests {

  // MARK: - Helpers

  /// A model with a synthetic pyramid and explicit geometry, no audio decode.
  private func makeModel(
    totalSamples: Int, viewportWidth: CGFloat, samplesPerPixel: Double, start: Int = 0,
    base: (mins: [Float], maxs: [Float])? = nil, baseBucketSize: Int = 4
  ) -> WaveformModel {
    let model = WaveformModel()
    model.totalSamples = totalSamples
    model.viewportWidth = viewportWidth
    model.samplesPerPixel = samplesPerPixel
    model.visibleStartSample = start
    if let base {
      model.waveform = Waveform.pyramid(
        baseMins: base.mins, baseMaxs: base.maxs, sampleRate: 44100,
        totalSamples: totalSamples, baseBucketSize: baseBucketSize)
    }
    return model
  }

  // MARK: - Coordinate transforms

  @Test func sampleToXAndBackRoundTrip() {
    let model = makeModel(
      totalSamples: 100_000, viewportWidth: 1000, samplesPerPixel: 100, start: 0)
    #expect(model.sampleToX(500) == 5)
    #expect(model.xToSample(5) == 500)
    // with a scrolled start
    model.visibleStartSample = 2000
    #expect(model.sampleToX(2500) == 5)
    #expect(model.xToSample(5) == 2500)
  }

  @Test func xToSampleUsesFloorSemantics() {
    let model = makeModel(totalSamples: 100_000, viewportWidth: 1000, samplesPerPixel: 100)
    // pixel 5 covers [500, 600); a fractional x floors to the left-edge sample.
    #expect(model.xToSample(5.0) == 500)
    #expect(model.xToSample(5.99) == 599)
    #expect(model.xToSample(5.999) == 599)
  }

  // MARK: - visibleColumns

  @Test func visibleColumnsReadBucketsAtFloorEndExclusive() {
    // 8 base buckets of size 4 -> samples [0,32). spp 4 -> one bucket per pixel.
    let mins: [Float] = [-0.1, -0.2, -0.3, -0.4, -0.5, -0.6, -0.7, -0.8]
    let maxs: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
    let model = makeModel(
      totalSamples: 32, viewportWidth: 8, samplesPerPixel: 4, base: (mins, maxs))
    let columns = model.visibleColumns()
    expectNoDifference(columns.map(\.min), mins)
    expectNoDifference(columns.map(\.max), maxs)
    expectNoDifference(columns.map(\.positionX), (0..<8).map { CGFloat($0) })
  }

  @Test func visibleColumnsClampAtFileEndAndPreserveFinalPartialBucket() {
    // totalSamples 30 (< 32): the last pixel covers [28,32) clamped to [28,30) -> bucket 7.
    let mins: [Float] = [-0.1, -0.2, -0.3, -0.4, -0.5, -0.6, -0.7, -0.9]
    let maxs: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.9]
    let model = makeModel(
      totalSamples: 30, viewportWidth: 8, samplesPerPixel: 4, base: (mins, maxs))
    let columns = model.visibleColumns()
    #expect(columns.count == 8)
    #expect(columns.last?.min == -0.9)
    #expect(columns.last?.max == 0.9)
  }

  @Test func visibleColumnsEmptyWithoutWaveform() {
    let model = makeModel(totalSamples: 32, viewportWidth: 8, samplesPerPixel: 4)
    expectNoDifference(model.visibleColumns(), [])
  }

  @Test func zoomedInPixelAggregatesOneBaseBucket() {
    // spp 2 (< base bucketSize 4): stays on level 0; pixel 0 covers [0,2) -> bucket 0.
    let mins: [Float] = [-0.5, -0.6, -0.7, -0.8]
    let maxs: [Float] = [0.5, 0.6, 0.7, 0.8]
    let model = makeModel(
      totalSamples: 16, viewportWidth: 8, samplesPerPixel: 2, base: (mins, maxs))
    let columns = model.visibleColumns()
    // pixels 0 and 1 both fall in bucket 0 ([0,2) and [2,4))
    #expect(columns[0].min == -0.5)
    #expect(columns[1].min == -0.5)
    #expect(columns[2].min == -0.6)  // pixel 2 covers [4,6) -> bucket 1
  }

  // MARK: - span / overlays

  @Test func spanClipsToViewport() {
    let model = makeModel(totalSamples: 100_000, viewportWidth: 100, samplesPerPixel: 10)
    // [500,2000) -> x 50..200, clipped to width 100.
    let span = model.span(for: 500..<2000)
    expectNoDifference(span, WaveformSpan(positionX: 50, width: 50))
  }

  @Test func spanClipsWhenRangeStartsBeforeVisibleWindow() {
    let model = makeModel(
      totalSamples: 100_000, viewportWidth: 100, samplesPerPixel: 10, start: 500)
    // range [0,1000): xStart (0-500)/10 = -50 -> 0; xEnd (1000-500)/10 = 50.
    expectNoDifference(model.span(for: 0..<1000), WaveformSpan(positionX: 0, width: 50))
  }

  @Test func spanNilWhenOffscreenOrEmpty() {
    let model = makeModel(totalSamples: 100_000, viewportWidth: 100, samplesPerPixel: 10)
    #expect(model.span(for: 5000..<6000) == nil)  // starts at x 500, off-screen
    #expect(model.span(for: 300..<300) == nil)  // empty range
  }

  @Test func highlightAndRedSpansDerivedFromRanges() {
    let model = makeModel(totalSamples: 100_000, viewportWidth: 100, samplesPerPixel: 10)
    model.highlightedRange = 100..<300
    model.redRanges = [0..<100, 500..<700]
    expectNoDifference(model.highlightSpan, WaveformSpan(positionX: 10, width: 20))
    // second red range starts at x 50 (on-screen), first at x 0.
    expectNoDifference(
      model.redSpans,
      [WaveformSpan(positionX: 0, width: 10), WaveformSpan(positionX: 50, width: 20)])
  }

  // MARK: - playhead

  @Test func playheadXOnlyWhenInsideViewport() {
    let model = makeModel(totalSamples: 100_000, viewportWidth: 100, samplesPerPixel: 10)
    model.playheadSample = 500
    #expect(model.playheadX == 50)
    model.playheadSample = 5000  // x 500 -> off-screen
    #expect(model.playheadX == nil)
    model.playheadSample = nil
    #expect(model.playheadX == nil)
  }

  // MARK: - zoom / scroll

  @Test func viewportResizedFitsWholeFileWhenUnset() {
    let model = WaveformModel()
    model.totalSamples = 1000
    model.viewportResized(width: 100)
    #expect(model.samplesPerPixel == 10)  // 1000 / 100
    #expect(model.visibleStartSample == 0)
  }

  @Test func zoomInHalvesSamplesPerPixelAndKeepsCenter() {
    let model = WaveformModel()
    model.totalSamples = 10_000
    model.viewportResized(width: 100)  // spp 100 (fit), center 5000
    model.zoomInTapped()
    #expect(model.samplesPerPixel == 50)
    #expect(model.visibleStartSample == 2500)  // center 5000 - 5000/2
  }

  @Test func zoomInClampsAtMinimum() {
    let model = WaveformModel()
    model.totalSamples = 10_000
    model.viewportResized(width: 100)  // spp 100
    for _ in 0..<20 { model.zoomInTapped() }
    #expect(model.samplesPerPixel == 8)  // minSamplesPerPixel
    #expect(model.canZoomIn == false)
  }

  @Test func zoomOutClampsAtFit() {
    let model = WaveformModel()
    model.totalSamples = 10_000
    model.viewportResized(width: 100)
    model.zoomInTapped()  // spp 50
    model.zoomInTapped()  // spp 25
    for _ in 0..<10 { model.zoomOutTapped() }
    #expect(model.samplesPerPixel == 100)  // fit
    #expect(model.canZoomOut == false)
  }

  @Test func scrolledClampsToBounds() {
    let model = WaveformModel()
    model.totalSamples = 10_000
    model.viewportResized(width: 100)
    model.zoomInTapped()  // spp 50 -> visibleCount 5000, maxStart 5000
    model.scrolled(toStartSample: -100)
    #expect(model.visibleStartSample == 0)
    model.scrolled(toStartSample: 99_999)
    #expect(model.visibleStartSample == 5000)
  }

  // MARK: - load

  @Test func loadPopulatesWaveformViaClientAndFitsZoom() async {
    let fixture = Waveform.pyramid(
      baseMins: [0, -0.5], baseMaxs: [0.1, 0.8], sampleRate: 44100, totalSamples: 1000)
    let model = withDependencies {
      $0.waveform = WaveformClient(loadWaveform: { _, _, _ in fixture })
    } operation: {
      WaveformModel()
    }
    model.viewportResized(width: 100)
    await model.load(url: URL(fileURLWithPath: "/x"), planSampleRate: 44100, durationSamples: 1000)
    expectNoDifference(model.waveform, fixture)
    #expect(model.isLoading == false)
    #expect(model.totalSamples == 1000)
    #expect(model.samplesPerPixel == 10)  // fit: 1000 / 100
  }
}
