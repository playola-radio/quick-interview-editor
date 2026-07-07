import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct WaveformClientTests {

  // MARK: - baseLevel bucketing

  @Test func baseLevelBucketsExactMultiple() {
    // 512 samples, bucket 256 -> exactly 2 buckets.
    var mono = [Float](repeating: 0, count: 512)
    mono[10] = 0.5  // in bucket 0
    mono[300] = -0.8  // in bucket 1
    mono[400] = 0.9  // in bucket 1
    let base = Waveform.baseLevel(mono: mono, bucketSize: 256)
    expectNoDifference(base.mins, [0, -0.8])
    expectNoDifference(base.maxs, [0.5, 0.9])
  }

  @Test func baseLevelPreservesFinalPartialBucket() {
    // 600 samples, bucket 256 -> 3 buckets (256, 256, 88) — the tail is not dropped.
    let mono = [Float](repeating: 0.1, count: 600)
    let base = Waveform.baseLevel(mono: mono, bucketSize: 256)
    #expect(base.mins.count == 3)
    #expect(base.maxs.count == 3)
  }

  @Test func baseLevelEmptyInput() {
    let base = Waveform.baseLevel(mono: [], bucketSize: 256)
    expectNoDifference(base.mins, [])
    expectNoDifference(base.maxs, [])
  }

  // MARK: - pyramid structure

  @Test func pyramidDoublesBucketSizeAndHalvesCounts() {
    // 5 base buckets -> counts 5, 3, 2, 1; bucket sizes 4, 8, 16, 32.
    let mins: [Float] = [-0.1, -0.2, -0.3, -0.4, -0.5]
    let maxs: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
    let waveform = Waveform.pyramid(
      baseMins: mins, baseMaxs: maxs, sampleRate: 44100, totalSamples: 20, baseBucketSize: 4)
    expectNoDifference(waveform.levels.map(\.bucketSize), [4, 8, 16, 32])
    expectNoDifference(waveform.levels.map(\.mins.count), [5, 3, 2, 1])
    #expect(waveform.levels.last?.mins.count == 1)
  }

  @Test func pyramidReduceTakesMinAndMaxOfPairs() {
    let mins: [Float] = [-0.1, -0.5, -0.2, -0.9]
    let maxs: [Float] = [0.3, 0.1, 0.7, 0.2]
    let waveform = Waveform.pyramid(
      baseMins: mins, baseMaxs: maxs, sampleRate: 44100, totalSamples: 16, baseBucketSize: 4)
    // level 1 pairs (0,1) and (2,3)
    expectNoDifference(waveform.levels[1].mins, [-0.5, -0.9])
    expectNoDifference(waveform.levels[1].maxs, [0.3, 0.7])
  }

  @Test func pyramidOddBucketCarriesTrailingBucketThrough() {
    // 3 base buckets: pair (0,1) then lone (2).
    let mins: [Float] = [-0.1, -0.2, -0.7]
    let maxs: [Float] = [0.4, 0.3, 0.9]
    let waveform = Waveform.pyramid(
      baseMins: mins, baseMaxs: maxs, sampleRate: 44100, totalSamples: 12, baseBucketSize: 4)
    expectNoDifference(waveform.levels[1].mins, [-0.2, -0.7])
    expectNoDifference(waveform.levels[1].maxs, [0.4, 0.9])
  }

  @Test func pyramidMinsNeverExceedMaxsAtEveryLevel() {
    let mono = (0..<2000).map { Float(sin(Double($0) * 0.05)) }
    let base = Waveform.baseLevel(mono: mono, bucketSize: 256)
    let waveform = Waveform.pyramid(
      baseMins: base.mins, baseMaxs: base.maxs, sampleRate: 44100, totalSamples: mono.count)
    for level in waveform.levels {
      for index in level.mins.indices {
        #expect(level.mins[index] <= level.maxs[index])
      }
    }
  }

  @Test func pyramidEmptyBaseProducesNoLevels() {
    let waveform = Waveform.pyramid(
      baseMins: [], baseMaxs: [], sampleRate: 44100, totalSamples: 0)
    expectNoDifference(waveform.levels, [])
    #expect(waveform.baseLevel == nil)
  }

  // MARK: - previewValue

  @Test func previewValueProducesNonEmptyPyramid() async throws {
    let waveform = try await WaveformClient.previewValue.loadWaveform(
      URL(fileURLWithPath: "/dev/null"), 100, 1000)
    #expect(waveform.sampleRate == 100)
    #expect(!waveform.levels.isEmpty)
    #expect(waveform.baseLevel?.bucketSize == Waveform.baseBucketSize)
  }
}
