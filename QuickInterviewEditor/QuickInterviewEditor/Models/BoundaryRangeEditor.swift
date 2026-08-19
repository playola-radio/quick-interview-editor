import Foundation

/// The raw two-boundary edge math for the freeform audio selection, mirroring
/// `FineTuneModel`'s clamp/min-duration/snap behavior but with the WHOLE FILE as the
/// window (the primary selection has no magnified inset). Extracted as a value type so the
/// selection path reuses the mechanics without inheriting `FineTuneModel`'s
/// session/target/audition state machine (see spec §5). `snap:false` is the primary path.
struct BoundaryRangeEditor: Equatable {
  var fileDurationSamples: Int
  var sampleRate: Int
  var minDurationSamples: Int
  var snapThresholdSamples: Int
  var silences: [EditPlan.Silence]

  private var constraints: BoundaryConstraints {
    BoundaryConstraints(
      window: 0...fileDurationSamples, durationSamples: fileDurationSamples,
      minDurationSamples: minDurationSamples)
  }

  func moveStart(of range: Range<Int>, to sourceSample: Int, snap: Bool) -> Range<Int> {
    let resolved = resolve(sourceSample, moving: .start, opposite: range.upperBound, snap: snap)
    return resolved..<range.upperBound
  }

  func moveEnd(of range: Range<Int>, to sourceSample: Int, snap: Bool) -> Range<Int> {
    let resolved = resolve(sourceSample, moving: .end, opposite: range.lowerBound, snap: snap)
    return range.lowerBound..<resolved
  }

  func nudgeStart(of range: Range<Int>, byMs deltaMs: Double) -> Range<Int> {
    moveStart(of: range, to: range.lowerBound + samples(forMs: deltaMs), snap: false)
  }

  func nudgeEnd(of range: Range<Int>, byMs deltaMs: Double) -> Range<Int> {
    moveEnd(of: range, to: range.upperBound + samples(forMs: deltaMs), snap: false)
  }

  private func resolve(_ proposed: Int, moving edge: SliceEdge, opposite: Int, snap: Bool) -> Int {
    let limits = constraints
    let clamped = clampedBoundary(proposed, moving: edge, opposite: opposite, constraints: limits)
    guard snap else { return clamped }
    let legal = legalBoundaryRange(moving: edge, opposite: opposite, constraints: limits)
    return nearestSilenceEdge(
      sample: clamped, thresholdSamples: snapThresholdSamples, silences: silences, legalRange: legal
    )
      ?? clamped
  }

  private func samples(forMs ms: Double) -> Int {
    Int((ms / 1000 * Double(sampleRate)).rounded())
  }
}
