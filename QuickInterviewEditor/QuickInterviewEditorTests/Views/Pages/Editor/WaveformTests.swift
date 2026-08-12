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

  @Test func dragScrollPansRelativeToAnchorAndClamps() {
    let model = WaveformModel()
    model.totalSamples = 10_000
    model.viewportResized(width: 100)
    model.zoomInTapped()  // spp 50, visibleStart 2500
    model.dragScrollBegan()  // anchor 2500
    model.dragScrolled(byPixels: 10)  // drag right reveals earlier audio: 2500 - 10*50
    #expect(model.visibleStartSample == 2000)
    model.dragScrolled(byPixels: -10)  // still relative to the same anchor
    #expect(model.visibleStartSample == 3000)
    model.dragScrolled(byPixels: 100_000)  // clamps to 0
    #expect(model.visibleStartSample == 0)
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

  @Test func loadIsIdempotentOnceLoaded() async {
    let calls = LockIsolated(0)
    let fixture = Waveform.pyramid(
      baseMins: [0], baseMaxs: [0.5], sampleRate: 44100, totalSamples: 500)
    let model = withDependencies {
      $0.waveform = WaveformClient(loadWaveform: { _, _, _ in
        calls.withValue { $0 += 1 }
        return fixture
      })
    } operation: {
      WaveformModel()
    }
    let url = URL(fileURLWithPath: "/x")
    await model.load(url: url, planSampleRate: 44100, durationSamples: 500)
    await model.load(url: url, planSampleRate: 44100, durationSamples: 500)
    #expect(calls.value == 1)  // second call is a no-op — no re-decode
  }

  @Test func loadIgnoresDegeneratePlan() async {
    let calls = LockIsolated(0)
    let model = withDependencies {
      $0.waveform = WaveformClient(loadWaveform: { _, _, _ in
        calls.withValue { $0 += 1 }
        return Waveform.pyramid(baseMins: [0], baseMaxs: [0], sampleRate: 1, totalSamples: 1)
      })
    } operation: {
      WaveformModel()
    }
    await model.load(url: URL(fileURLWithPath: "/x"), planSampleRate: 0, durationSamples: 0)
    #expect(calls.value == 0)  // never touches AVFoundation with a garbage plan
    #expect(model.waveform == nil)
    #expect(model.showsEmpty)
  }

  @Test func loadSwallowsCancellationWithoutReportingAnIssue() async {
    let model = withDependencies {
      $0.waveform = WaveformClient(loadWaveform: { _, _, _ in throw CancellationError() })
    } operation: {
      WaveformModel()
    }
    // No withKnownIssue: a reported issue here would fail the test, proving cancellation
    // is swallowed (the view went away) rather than surfaced as an error.
    await model.load(url: URL(fileURLWithPath: "/x"), planSampleRate: 44100, durationSamples: 1000)
    #expect(model.waveform == nil)
    #expect(model.isLoading == false)
  }

  // MARK: - Cursor-anchored zoom + wheel pan

  @Test func zoomByFactorKeepsSampleUnderCursorFixedZoomingIn() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 200_000)
    let cursorX: CGFloat = 400
    let sampleUnder = Double(model.xToSample(cursorX))
    model.zoomByFactor(0.5, anchoredAtX: cursorX)  // zoom in
    expectNoDifference(model.samplesPerPixel, 50)
    // the same sample is still drawn within a pixel of the cursor
    #expect(abs(Double(model.sampleToX(Int(sampleUnder)) - cursorX)) < 1.0)
  }

  @Test func zoomByFactorKeepsSampleUnderCursorFixedZoomingOut() {
    let model = makeModel(
      totalSamples: 10_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 500_000)
    let cursorX: CGFloat = 250
    let sampleUnder = Double(model.xToSample(cursorX))
    model.zoomByFactor(2.0, anchoredAtX: cursorX)  // zoom out
    expectNoDifference(model.samplesPerPixel, 200)
    #expect(abs(Double(model.sampleToX(Int(sampleUnder)) - cursorX)) < 1.0)
  }

  @Test func zoomByFactorClampsAtMinSamplesPerPixel() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 16, start: 0)
    model.zoomByFactor(0.01, anchoredAtX: 500)  // far past the min (8)
    expectNoDifference(model.samplesPerPixel, 8)
  }

  @Test func zoomByFactorClampsAtFit() {
    let model = makeModel(
      totalSamples: 100_000, viewportWidth: 1000, samplesPerPixel: 90, start: 0)
    // fit spp = 100_000 / 1000 = 100
    model.zoomByFactor(100, anchoredAtX: 500)
    expectNoDifference(model.samplesPerPixel, 100)
  }

  @Test func panByPixelsClampsAtStart() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 5_000)
    model.panByPixels(1_000_000)  // pan hard toward the start
    expectNoDifference(model.visibleStartSample, 0)
  }

  @Test func panByPixelsClampsAtEnd() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 5_000)
    // visibleSampleCount = 1000*100 = 100_000; maxStart = 900_000
    model.panByPixels(-1_000_000)  // pan hard toward the end
    expectNoDifference(model.visibleStartSample, 900_000)
  }

  @Test func panByPixelsMovesByPixelsTimesSamplesPerPixel() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 500_000)
    model.panByPixels(-10)  // 10 px * 100 spp = 1000 samples, toward the end
    expectNoDifference(model.visibleStartSample, 501_000)
  }

  // MARK: - Z zoom-to-fit toggle

  @Test func zoomToFitAllFitsWholeFileAtStart() {
    let model = makeModel(
      totalSamples: 100_000, viewportWidth: 1000, samplesPerPixel: 20, start: 40_000)
    model.zoomToFitAll()
    expectNoDifference(model.samplesPerPixel, 100)  // 100_000 / 1000
    expectNoDifference(model.visibleStartSample, 0)
  }

  @Test func zoomToFitCentersTheRange() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 0)
    model.zoomToFit(400_000..<600_000)  // 200_000 wide -> spp 200; center 500_000
    expectNoDifference(model.samplesPerPixel, 200)
    // visibleSampleCount = 1000*200 = 200_000; start = 500_000 - 100_000
    expectNoDifference(model.visibleStartSample, 400_000)
  }

  @Test func zoomToFitPaddingLeavesBreathingRoomAroundTheRange() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 0)
    // 200_000 wide, padded ×1.2 -> 240_000 over 1000 px -> spp 240; center stays 500_000.
    model.zoomToFit(400_000..<600_000, paddingFraction: 0.1)
    expectNoDifference(model.samplesPerPixel, 240)
    // visibleSampleCount = 1000*240 = 240_000; start = 500_000 - 120_000
    expectNoDifference(model.visibleStartSample, 380_000)
  }

  @Test func paddedZoomInvalidatesTheArmedFitRestore() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 50, start: 0)
    let selection = 400_000..<600_000
    model.zoomFitToggled(selection: selection)  // fits X (spp 200), arms restore of spp 50
    model.zoomToFit(selection, paddingFraction: 0.1)  // reveal: must clear the armed restore
    // With the restore cleared, a second Z fits fresh (spp 200) instead of restoring spp 50.
    model.zoomFitToggled(selection: selection)
    expectNoDifference(model.samplesPerPixel, 200)
  }

  @Test func plainZoomToFitStillTogglesRestoreForTheZKey() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 50, start: 300_000)
    let selection = 400_000..<600_000
    model.zoomFitToggled(selection: selection)  // fit (spp 200), arms restore of spp 50/start 300k
    model.zoomFitToggled(selection: selection)  // same selection -> restore, NOT re-fit
    expectNoDifference(model.samplesPerPixel, 50)
    expectNoDifference(model.visibleStartSample, 300_000)
  }

  @Test func zoomFitToggledFitsThenRestores() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 50, start: 300_000)
    model.zoomFitToggled(selection: nil)  // fit all
    expectNoDifference(model.samplesPerPixel, 1000)  // 1_000_000 / 1000
    expectNoDifference(model.visibleStartSample, 0)
    model.zoomFitToggled(selection: nil)  // restore
    expectNoDifference(model.samplesPerPixel, 50)
    expectNoDifference(model.visibleStartSample, 300_000)
  }

  @Test func zoomFitToggledUsesSelectionWhenProvided() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 50, start: 0)
    model.zoomFitToggled(selection: 400_000..<600_000)
    expectNoDifference(model.samplesPerPixel, 200)
    expectNoDifference(model.visibleStartSample, 400_000)
  }

  @Test func zoomFitToggledRefitsWhenSelectionChanged() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 50, start: 300_000)
    model.zoomFitToggled(selection: 100_000..<200_000)  // fit A
    model.zoomFitToggled(selection: 700_000..<900_000)  // selection changed -> fit B, NOT restore
    expectNoDifference(model.samplesPerPixel, 200)  // 200_000 / 1000
    #expect(model.samplesPerPixel != 50)  // did not restore pre-fit zoom
  }

  @Test func zoomFitToggledRestoresWhenSelectionUnchanged() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 50, start: 300_000)
    model.zoomFitToggled(selection: 100_000..<200_000)  // fit
    model.zoomFitToggled(selection: 100_000..<200_000)  // same selection -> restore
    expectNoDifference(model.samplesPerPixel, 50)
    expectNoDifference(model.visibleStartSample, 300_000)
  }

  @Test func manualZoomBetweenTogglesInvalidatesRestore() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 50, start: 300_000)
    model.zoomFitToggled(selection: nil)  // fit all (stores 50/300_000)
    model.zoomByFactor(0.5, anchoredAtX: 500)  // manual zoom -> invalidates restore
    let sppAfterManual = model.samplesPerPixel
    model.zoomFitToggled(selection: nil)  // must FIT again, not restore
    expectNoDifference(model.samplesPerPixel, 1000)
    #expect(model.samplesPerPixel != sppAfterManual)
  }

  @Test func manualPanBetweenTogglesInvalidatesRestore() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 50, start: 300_000)
    model.zoomFitToggled(selection: nil)  // fit all (stores 50/300_000)
    model.panByPixels(-10)  // manual pan -> invalidates restore
    model.zoomFitToggled(selection: nil)  // must FIT again, not restore
    expectNoDifference(model.visibleStartSample, 0)
    expectNoDifference(model.samplesPerPixel, 1000)
  }
}
