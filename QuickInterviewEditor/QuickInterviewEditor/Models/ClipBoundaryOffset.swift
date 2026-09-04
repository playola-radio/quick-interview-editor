import Foundation

/// Nudges a NEW clip's sample boundaries by the user's configured start/end offsets (each
/// clamped to ±50 ms), converting ms→samples the same way `BoundaryRangeEditor` does. The two
/// offsets are applied and clamped INDEPENDENTLY to `0...totalSamples`; if the result would
/// invert or collapse (lower >= upper) the original range is returned unchanged. Positive ms
/// means later in time (sample index increases), negative means earlier.
func offsetClipRange(
  _ range: Range<Int>, startOffsetMs: Double, endOffsetMs: Double, sampleRate: Int,
  totalSamples: Int
) -> Range<Int> {
  let maxOffsetMs = 50.0
  let clampedStartMs = min(max(startOffsetMs, -maxOffsetMs), maxOffsetMs)
  let clampedEndMs = min(max(endOffsetMs, -maxOffsetMs), maxOffsetMs)
  let startSamples = samples(forMs: clampedStartMs, sampleRate: sampleRate)
  let endSamples = samples(forMs: clampedEndMs, sampleRate: sampleRate)

  let upperBound = max(0, totalSamples)
  let lower = min(max(range.lowerBound + startSamples, 0), upperBound)
  let upper = min(max(range.upperBound + endSamples, 0), upperBound)
  guard lower < upper else { return range }
  return lower..<upper
}

private func samples(forMs ms: Double, sampleRate: Int) -> Int {
  Int((ms / 1000 * Double(max(1, sampleRate))).rounded())
}
