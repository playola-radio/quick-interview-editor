import CoreGraphics
import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditedWaveformAdapterTests {

  // MARK: - Helpers

  /// Wraps a source `WaveformModel` (synthetic pyramid, no audio decode — same construction as
  /// `WaveformTests.makeModel`) in an adapter whose `EditedTimeline` has a single removal.
  /// Defaults produce editedDurationSamples == 40 (source 64, removal [24,40), crossfade 8).
  private func makeAdapter(
    sourceDuration: Int = 64, removedRange: Range<Int> = 24..<40, crossfadeLength: Int = 8,
    viewportWidth: CGFloat, samplesPerPixel: Double, start: Int = 0,
    base: (mins: [Float], maxs: [Float])? = nil, baseBucketSize: Int = 4
  ) -> EditedWaveformAdapter {
    let source = WaveformModel()
    source.totalSamples = sourceDuration
    if let base {
      source.waveform = Waveform.pyramid(
        baseMins: base.mins, baseMaxs: base.maxs, sampleRate: 44100,
        totalSamples: sourceDuration, baseBucketSize: baseBucketSize)
    }
    let removal = TimelineRemoval(
      id: UUID(), removedRange: removedRange, crossfade: Crossfade(lengthSamples: crossfadeLength))
    let timeline = EditedTimeline(sourceDurationSamples: sourceDuration, removals: [removal])
    let adapter = EditedWaveformAdapter(source: source, timeline: timeline)
    adapter.viewportWidth = viewportWidth
    adapter.samplesPerPixel = samplesPerPixel
    adapter.visibleStartSample = start
    return adapter
  }

  // MARK: - editedDurationSamples

  @Test func editedDurationSamplesReflectsTheTimeline() {
    // K0=[0,24) len24, K1=[40,64) len24, crossfade 8 -> 24+24-8 = 40.
    let adapter = makeAdapter(viewportWidth: 15, samplesPerPixel: 2)
    expectNoDifference(adapter.editedDurationSamples, 40)
  }

  // MARK: - Coordinate transforms

  @Test func editedSampleToXAndXToEditedSampleRoundTrip() {
    let adapter = makeAdapter(viewportWidth: 15, samplesPerPixel: 2)
    expectNoDifference(adapter.editedSampleToX(10), 5)
    expectNoDifference(adapter.xToEditedSample(5), 10)
  }

  @Test func xToSourceSampleMapsThroughTheTimeline() {
    let adapter = makeAdapter(viewportWidth: 15, samplesPerPixel: 2)
    // x=5 -> edited 10 -> pure K0 (before the crossfade) -> source 10.
    expectNoDifference(adapter.xToSourceSample(5), 10)
    // x=15 -> edited 30 -> K1 exclusive region -> source 40 + (30-16) = 54.
    expectNoDifference(adapter.xToSourceSample(15), 54)
  }

  @Test func sourceSampleToXAndPlayheadXResolveInsideRemovalAndOffscreen() {
    let adapter = makeAdapter(viewportWidth: 15, samplesPerPixel: 2)
    // source 10 is pure K0 -> edited 10 -> x 5, on-screen.
    expectNoDifference(adapter.sourceSampleToX(10), 5)
    expectNoDifference(adapter.viewX(forSource: 10), 5)

    // source 30 is inside the removal [24,40); nearest bias (default) is closer to the cut
    // start (distance 6) than the cut end (distance 10) -> edited 24 -> x 12, on-screen.
    expectNoDifference(adapter.sourceSampleToX(30), 12)
    expectNoDifference(adapter.viewX(forSource: 30), 12)

    // source 63 (K1, past the crossfade) -> edited 39 -> x 19.5, past the 15pt viewport.
    expectNoDifference(adapter.sourceSampleToX(63), 19.5)
    #expect(adapter.viewX(forSource: 63) == nil)
  }

  // MARK: - span

  @Test func spanForSourceMapsBoundariesThroughTheTimeline() {
    let adapter = makeAdapter(viewportWidth: 15, samplesPerPixel: 2)
    // [0,10) is pure K0 -> edited [0,10) -> x [0,5).
    expectNoDifference(adapter.span(forSource: 0..<10), WaveformSpan(positionX: 0, width: 5))
  }

  @Test func spanForSourceNilWhenEntirelyInsideARemoval() {
    let adapter = makeAdapter(viewportWidth: 15, samplesPerPixel: 2)
    // [26,34) is entirely inside the removal [24,40): leftEdge -> edited 24, rightEdge ->
    // edited 16 (start of K1's crossfade overlap) — inverted, so there's nothing to draw.
    #expect(adapter.span(forSource: 26..<34) == nil)
  }

  @Test func spanForEditedClipsToViewportAndNilWhenOffscreenOrEmpty() {
    let adapter = makeAdapter(viewportWidth: 15, samplesPerPixel: 2)
    expectNoDifference(adapter.span(forEdited: 5..<15), WaveformSpan(positionX: 2.5, width: 5))
    #expect(adapter.span(forEdited: 100..<110) == nil)  // off-screen
    #expect(adapter.span(forEdited: 5..<5) == nil)  // empty
  }

  @Test func spanForSeamCoversTheCrossfadeWindow() {
    let adapter = makeAdapter(viewportWidth: 15, samplesPerPixel: 2)
    let seam = adapter.timeline.seams[0]
    expectNoDifference(seam.editedCrossfadeStart, 16)
    expectNoDifference(seam.crossfadeLength, 8)
    // edited [16,24) -> x [8,12).
    expectNoDifference(adapter.spanForSeam(seam), WaveformSpan(positionX: 8, width: 4))
  }

  @Test func spanForSeamIsAZeroWidthMarkerForAHardCut() {
    // Removal to EOF -> the right kept island is empty -> crossfade clamps to 0. The seam still
    // sits at the join (edited 24 -> x 12) and must render/hit as a zero-width marker, not vanish.
    let adapter = makeAdapter(
      removedRange: 24..<64, crossfadeLength: 8, viewportWidth: 15, samplesPerPixel: 2)
    let seam = adapter.timeline.seams[0]
    expectNoDifference(seam.crossfadeLength, 0)
    expectNoDifference(seam.editedCrossfadeStart, 24)
    expectNoDifference(adapter.spanForSeam(seam), WaveformSpan(positionX: 12, width: 0))
  }

  @Test func spanForSeamIsNilWhenTheHardCutIsOffscreen() {
    // Same hard cut at edited 24 -> x 12, but the viewport is only 10pt wide -> off-screen -> nil.
    let adapter = makeAdapter(
      removedRange: 24..<64, crossfadeLength: 8, viewportWidth: 10, samplesPerPixel: 2)
    let seam = adapter.timeline.seams[0]
    expectNoDifference(seam.crossfadeLength, 0)
    #expect(adapter.spanForSeam(seam) == nil)
  }

  // MARK: - visibleColumns across a seam

  @Test func visibleColumnsMergePeaksAcrossASeam() {
    // Base level (bucketSize 4) has 16 buckets over 64 source samples. Bucket 4 (part of
    // source [16,24), the left side of the seam) supplies a deep min and a shallow max;
    // bucket 10 (part of source [40,48), the right side) supplies a shallow min and a deep
    // max. A correct merge takes the min from one side and the max from the other — neither
    // side's own (min, max) pair matches the merged result, and neither does their average,
    // so this only passes for a real min-of-mins/max-of-maxs fold.
    var mins = [Float](repeating: 0, count: 16)
    var maxs = [Float](repeating: 0, count: 16)
    mins[4] = -0.9
    maxs[4] = 0.1
    mins[10] = -0.05
    maxs[10] = 0.9
    let adapter = makeAdapter(
      viewportWidth: 5, samplesPerPixel: 8, base: (mins, maxs))

    // editedDuration 40, spp 8 -> 5 pixels covering edited [0,40) exactly. Pixel 2 covers
    // edited [16,24), exactly the seam's crossfade window: it maps to source [16,24) (level1
    // bucket 2, folded from base buckets 4-5: min -0.9, max 0.1) and source [40,48) (level1
    // bucket 5, folded from base buckets 10-11: min -0.05, max 0.9). Merged:
    // min(-0.9,-0.05) = -0.9 (from the left side), max(0.1,0.9) = 0.9 (from the right side).
    let columns = adapter.visibleColumns()
    #expect(columns.count == 5)
    expectNoDifference(columns[2].positionX, 2)
    #expect(columns[2].min == -0.9)
    #expect(columns[2].max == 0.9)

    // Neighboring pixels stay on one side of the seam (sanity check the merge is localized).
    #expect(columns[1].min == 0)
    #expect(columns[1].max == 0)
  }

  @Test func visibleColumnsEmptyWithoutSourceWaveform() {
    let adapter = makeAdapter(viewportWidth: 5, samplesPerPixel: 8)  // no `base` -> unloaded
    expectNoDifference(adapter.visibleColumns(), [])
  }

  // MARK: - zoom / pan clamp against editedDurationSamples

  @Test func zoomOutClampsAtEditedFit() {
    // K0=[0,400_000) len400_000, K1=[600_000,1_000_000) len400_000, crossfade 50_000 ->
    // editedDuration = 400_000+400_000-50_000 = 750_000; fit = 750_000/1000 = 750.
    let adapter = makeAdapter(
      sourceDuration: 1_000_000, removedRange: 400_000..<600_000, crossfadeLength: 50_000,
      viewportWidth: 1000, samplesPerPixel: 90, base: ([0], [0]))
    for _ in 0..<10 { adapter.zoomOutTapped() }
    expectNoDifference(adapter.samplesPerPixel, 750)
    #expect(adapter.canZoomOut == false)
  }

  @Test func zoomInClampsAtMinimum() {
    let adapter = makeAdapter(
      sourceDuration: 1_000_000, removedRange: 400_000..<600_000, crossfadeLength: 50_000,
      viewportWidth: 1000, samplesPerPixel: 750, base: ([0], [0]))
    for _ in 0..<20 { adapter.zoomInTapped() }
    expectNoDifference(adapter.samplesPerPixel, 8)  // WaveformViewport.minSamplesPerPixel
    #expect(adapter.canZoomIn == false)
  }

  @Test func panByPixelsClampsAtEditedBounds() {
    let adapter = makeAdapter(
      sourceDuration: 1_000_000, removedRange: 400_000..<600_000, crossfadeLength: 50_000,
      viewportWidth: 1000, samplesPerPixel: 100, start: 5_000, base: ([0], [0]))
    adapter.panByPixels(1_000_000)  // hard pan toward the start
    expectNoDifference(adapter.visibleStartSample, 0)
    // visibleSampleCount = 1000*100 = 100_000; editedDuration 750_000 -> maxStart 650_000.
    adapter.panByPixels(-2_000_000)  // hard pan toward the end
    expectNoDifference(adapter.visibleStartSample, 650_000)
  }

  // MARK: - zoomFitToggled keyed on SOURCE selection identity

  @Test func zoomFitToggledFitsSourceSelectionThenRestoresOnSecondPress() {
    let adapter = makeAdapter(
      sourceDuration: 1_000_000, removedRange: 400_000..<600_000, crossfadeLength: 50_000,
      viewportWidth: 1000, samplesPerPixel: 50, start: 300_000, base: ([0], [0]))
    let sourceSelection = 0..<200_000  // fully inside K0, no remap needed.
    adapter.zoomFitToggled(sourceSelection: sourceSelection)
    // edited range 0..<200_000 -> spp 200, center 100_000, start 0.
    expectNoDifference(adapter.samplesPerPixel, 200)
    expectNoDifference(adapter.visibleStartSample, 0)

    adapter.zoomFitToggled(sourceSelection: sourceSelection)  // same selection -> restore
    expectNoDifference(adapter.samplesPerPixel, 50)
    expectNoDifference(adapter.visibleStartSample, 300_000)
  }

  @Test func zoomFitToggledRefitsWhenSourceSelectionChanges() {
    let adapter = makeAdapter(
      sourceDuration: 1_000_000, removedRange: 400_000..<600_000, crossfadeLength: 50_000,
      viewportWidth: 1000, samplesPerPixel: 50, start: 300_000, base: ([0], [0]))
    adapter.zoomFitToggled(sourceSelection: 0..<200_000)  // fit A (arms restore of 50/300_000)
    adapter.zoomFitToggled(sourceSelection: 700_000..<900_000)  // different selection -> fit B
    // K1 edited span starts at 350_000. source 700_000 -> edited 350_000+(700_000-600_000)
    // = 450_000; source 900_000 -> edited 350_000+(900_000-600_000) = 650_000. range width
    // 200_000 -> spp 200, center 550_000, start 450_000.
    expectNoDifference(adapter.samplesPerPixel, 200)
    expectNoDifference(adapter.visibleStartSample, 450_000)
  }

  @Test func zoomFitToggledWithNilSelectionFitsWholeEditedTimeline() {
    let adapter = makeAdapter(
      sourceDuration: 1_000_000, removedRange: 400_000..<600_000, crossfadeLength: 50_000,
      viewportWidth: 1000, samplesPerPixel: 50, start: 300_000, base: ([0], [0]))
    adapter.zoomFitToggled(sourceSelection: nil)
    expectNoDifference(adapter.samplesPerPixel, 750)  // editedDuration 750_000 / 1000
    expectNoDifference(adapter.visibleStartSample, 0)

    adapter.zoomFitToggled(sourceSelection: nil)  // restore
    expectNoDifference(adapter.samplesPerPixel, 50)
    expectNoDifference(adapter.visibleStartSample, 300_000)
  }

  // MARK: - zoomToFitSource (source range → edited fit)

  @Test func zoomToFitSourceConvertsThroughTheTimelineThenFits() {
    let adapter = makeAdapter(
      sourceDuration: 1_000_000, removedRange: 400_000..<600_000, crossfadeLength: 50_000,
      viewportWidth: 1000, samplesPerPixel: 50, start: 300_000, base: ([0], [0]))
    // K1 edited span starts at 350_000: source 700_000 -> edited 450_000, source 900_000 ->
    // edited 650_000. Width 200_000 over 1000 px -> spp 200, centered -> start 450_000.
    adapter.zoomToFitSource(700_000..<900_000)
    expectNoDifference(adapter.samplesPerPixel, 200)
    expectNoDifference(adapter.visibleStartSample, 450_000)
  }

  // MARK: - timelineChanged re-clamps into the new edited duration

  @Test func timelineChangedReclampsViewportIntoTheNewEditedDuration() {
    let source = WaveformModel()
    source.totalSamples = 1_000_000
    source.waveform = Waveform.pyramid(
      baseMins: [0], baseMaxs: [0], sampleRate: 44100, totalSamples: 1_000_000, baseBucketSize: 4)
    let adapter = EditedWaveformAdapter(
      source: source, timeline: EditedTimeline(sourceDurationSamples: 1_000_000, removals: []))
    adapter.viewportWidth = 1000
    adapter.samplesPerPixel = 100  // visibleSampleCount 100_000
    adapter.visibleStartSample = 850_000  // valid on a 1_000_000-sample edited timeline

    // A large removal collapses the edited duration to 150_000 (K0 100_000 + K1 50_000).
    let removal = TimelineRemoval(
      id: UUID(), removedRange: 100_000..<950_000, crossfade: Crossfade(lengthSamples: 0))
    adapter.timeline = EditedTimeline(sourceDurationSamples: 1_000_000, removals: [removal])
    adapter.timelineChanged()

    expectNoDifference(adapter.editedDurationSamples, 150_000)
    // maxStart = 150_000 - 100_000 = 50_000; the stale 850_000 clamps back into range.
    expectNoDifference(adapter.visibleStartSample, 50_000)
    // spp 100 is still within [min, fit=150], so the zoom level is preserved (not reset).
    expectNoDifference(adapter.samplesPerPixel, 100)
  }
}
