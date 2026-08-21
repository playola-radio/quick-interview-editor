import Foundation

/// A short single-sided declick ramp applied at a rendered clip's OUTER start/end so a hard
/// cut there doesn't click. Distinct from `CrossfadeRenderer`, which blends two ADJACENT clips
/// at an INTERNAL seam; this only ever touches one clip's own first/last samples. Pure and
/// AVFoundation-free like `CrossfadeRenderer`, so it feeds both the export renderer and live
/// audition and the two can never diverge.
enum DeclickFade {
  /// The default fade length: ~15 ms, converted to samples at the clip's own sample rate.
  static let defaultFadeMs: Double = 15

  /// The fade length in samples for a `totalFrames`-long clip at `sampleRate`, clamped to at
  /// most half the clip so a clip shorter than two fades doesn't double-ramp (and its fade-in
  /// and fade-out windows can never overlap).
  static func frameCount(totalFrames: Int, sampleRate: Int, fadeMs: Double = defaultFadeMs) -> Int {
    guard totalFrames > 0, sampleRate > 0 else { return 0 }
    let requested = Int((fadeMs / 1000 * Double(sampleRate)).rounded())
    return min(max(requested, 0), totalFrames / 2)
  }

  /// The linear declick gain at clip-relative `frame` (0-based): ramps 0→1 over the first
  /// `fadeInCount` samples, 1→0 over the last `fadeOutCount`, and is 1 everywhere between.
  static func gain(atFrame frame: Int, totalFrames: Int, fadeInCount: Int, fadeOutCount: Int)
    -> Float
  {
    guard totalFrames > 0, frame >= 0, frame < totalFrames else { return 1 }
    if fadeInCount > 0, frame < fadeInCount {
      return Float(frame) / Float(fadeInCount)
    }
    let framesFromEnd = totalFrames - 1 - frame
    if fadeOutCount > 0, framesFromEnd < fadeOutCount {
      return Float(framesFromEnd) / Float(fadeOutCount)
    }
    return 1
  }

  /// Applies the fade in place to one channel's samples, where `samples[i]` is clip-relative
  /// frame `chunkStart + i` — so a chunked renderer can call this once per read/write chunk and
  /// still reproduce exactly the envelope fading the whole clip at once would.
  static func apply(
    to samples: inout [Float], chunkStart: Int, totalFrames: Int,
    fadeInCount: Int, fadeOutCount: Int
  ) {
    guard fadeInCount > 0 || fadeOutCount > 0 else { return }
    for index in samples.indices {
      let frame = chunkStart + index
      let gain = gain(
        atFrame: frame, totalFrames: totalFrames, fadeInCount: fadeInCount,
        fadeOutCount: fadeOutCount)
      if gain != 1 { samples[index] *= gain }
    }
  }
}
