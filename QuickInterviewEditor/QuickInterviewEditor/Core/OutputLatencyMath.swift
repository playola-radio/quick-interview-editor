import Foundation

/// Pure math for compensating the visual playhead for output latency. Isolated from the audio
/// graph so it is fully unit-testable; the live player actor (untested, hardware-bound) calls
/// these and adds only the frame reads.
enum OutputLatencyMath {

  /// The delay to back the playhead off by, in seconds: the automatic estimate plus a signed
  /// manual correction, floored at 0. A non-finite manual value (corrupt defaults) is treated as 0.
  static func effectiveSeconds(automatic: Double, manual: Double) -> Double {
    let safeManual = manual.isFinite ? manual : 0
    return max(0, automatic + safeManual)
  }

  /// Converts the node's render (input-frame) count to the count representing audio the user is
  /// actually hearing. `effectiveSeconds` is a wall-clock OUTPUT delay; input frames advance at
  /// `nativeSampleRate * rate` per wall-clock second (the time-pitch rate speeds up input
  /// consumption), so the subtraction is rate-scaled. Clamped to 0 so the first `effectiveSeconds`
  /// of playback never maps below the range start.
  static func presentationFrames(
    renderFrames: Int, effectiveSeconds: Double, nativeSampleRate: Double, rate: Double
  ) -> Int {
    let offset = effectiveSeconds * nativeSampleRate * rate
    return max(0, Int((Double(renderFrames) - offset).rounded()))
  }
}
