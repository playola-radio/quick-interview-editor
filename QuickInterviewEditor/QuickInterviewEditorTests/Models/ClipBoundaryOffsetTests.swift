import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct ClipBoundaryOffsetTests {
  private func offset(
    _ range: Range<Int>, start: Double = 0, end: Double = 0, rate: Int = 48_000,
    total: Int = 480_000
  ) -> Range<Int> {
    offsetClipRange(
      range, startOffsetMs: start, endOffsetMs: end, sampleRate: rate, totalSamples: total)
  }

  @Test func zeroOffsetsAreIdentity() {
    expectNoDifference(offset(10_000..<20_000, start: 0, end: 0), 10_000..<20_000)
  }

  @Test func negativeStartGrowsTheFront() {
    // -50 ms at 48_000 Hz = -2_400 samples.
    expectNoDifference(offset(10_000..<20_000, start: -50), 7_600..<20_000)
  }

  @Test func positiveEndGrowsTheTail() {
    // +50 ms at 48_000 Hz = +2_400 samples.
    expectNoDifference(offset(10_000..<20_000, end: 50), 10_000..<22_400)
  }

  @Test func positiveStartAndNegativeEndShrinkTheRange() {
    expectNoDifference(offset(10_000..<20_000, start: 20, end: -20), 10_960..<19_040)
  }

  @Test func clampsAtBeginningOfFile() {
    expectNoDifference(offset(100..<20_000, start: -50), 0..<20_000)
  }

  @Test func clampsAtEndOfFile() {
    expectNoDifference(offset(460_000..<479_950, end: 50), 460_000..<480_000)
  }

  @Test func invertingTheRangeReturnsTheOriginalUnchanged() {
    // A tiny 10-sample range with a large negative-start / positive-end squeeze would invert.
    expectNoDifference(offset(10_000..<10_010, start: 50, end: -50), 10_000..<10_010)
  }

  @Test func collapsingTheRangeReturnsTheOriginalUnchanged() {
    expectNoDifference(offset(10_000..<12_400, start: 50, end: -50), 10_000..<12_400)
  }

  @Test func msToSampleRoundingAtFortyEightKHz() {
    // 50 ms at 48_000 Hz = exactly 2_400 samples.
    expectNoDifference(offset(10_000..<20_000, start: -50, end: 50), 7_600..<22_400)
  }

  @Test func msBeyondFiftyIsClampedToFifty() {
    expectNoDifference(offset(10_000..<20_000, start: -1_000), offset(10_000..<20_000, start: -50))
    expectNoDifference(offset(10_000..<20_000, end: 1_000), offset(10_000..<20_000, end: 50))
  }

  @Test func startAndEndOffsetsAreOrderIndependent() {
    // Order independence: applying start then end (or vice versa) gives the same result since
    // each bound is clamped only against the total, never against the other (possibly-still-old)
    // bound.
    expectNoDifference(offset(10_000..<20_000, start: 10, end: -10), 10_480..<19_520)
  }
}
