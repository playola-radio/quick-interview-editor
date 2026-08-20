import Foundation

/// Pure crossfade gain/blend math shared by live audition and export (one
/// renderer, so preview == export). No AVFoundation — plain Float arrays only,
/// fully unit-testable.
enum CrossfadeRenderer {
  /// Complementary out/in gain envelopes for an `count`-sample crossfade overlap.
  static func gains(count: Int, curve: CrossfadeCurve) -> (out: [Float], `in`: [Float]) {
    guard count > 0 else { return ([], []) }
    var out = [Float](repeating: 0, count: count)
    var `in` = [Float](repeating: 0, count: count)
    for i in 0..<count {
      let t: Float = count > 1 ? Float(i) / Float(count - 1) : 0
      switch curve {
      case .equalPower:
        let angle = t * .pi / 2
        out[i] = cos(angle)
        `in`[i] = sin(angle)
      case .linear:
        out[i] = 1 - t
        `in`[i] = t
      }
    }
    return (out, `in`)
  }

  /// Blends outgoing and incoming multichannel audio frame-by-frame with the
  /// gains for `curve`. `out` and `incoming` are [channel][sample], each channel
  /// `count` samples; returns [channel][sample] of the same shape.
  static func blend(out: [[Float]], incoming: [[Float]], curve: CrossfadeCurve) -> [[Float]] {
    let count = out.first?.count ?? 0
    let (gOut, gIn) = gains(count: count, curve: curve)
    var result: [[Float]] = []
    result.reserveCapacity(out.count)
    for channel in out.indices {
      let outChannel = out[channel]
      let inChannel = incoming[channel]
      var blended = [Float](repeating: 0, count: count)
      for i in 0..<count {
        blended[i] = outChannel[i] * gOut[i] + inChannel[i] * gIn[i]
      }
      result.append(blended)
    }
    return result
  }
}
