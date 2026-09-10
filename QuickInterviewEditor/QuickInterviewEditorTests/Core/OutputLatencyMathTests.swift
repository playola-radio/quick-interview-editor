import CustomDump
import Testing

@testable import PlayolaInterviewEditor

struct OutputLatencyMathTests {

  @Test func effectiveSecondsAddsAutomaticAndManual() {
    expectNoDifference(OutputLatencyMath.effectiveSeconds(automatic: 0.15, manual: 0.05), 0.20)
  }

  @Test func effectiveSecondsAllowsNegativeManualToReduceTotal() {
    // Expected as `0.15 - 0.05` (not the `0.10` literal): IEEE-754 double addition of
    // 0.15 + -0.05 does not equal the decimal literal 0.10 bit-for-bit, so the expected
    // value must be produced by the same arithmetic to compare equal.
    expectNoDifference(
      OutputLatencyMath.effectiveSeconds(automatic: 0.15, manual: -0.05), 0.15 - 0.05)
  }

  @Test func effectiveSecondsFloorsAtZero() {
    expectNoDifference(OutputLatencyMath.effectiveSeconds(automatic: 0.02, manual: -0.10), 0.0)
  }

  @Test func effectiveSecondsTreatsNonFiniteManualAsZero() {
    expectNoDifference(OutputLatencyMath.effectiveSeconds(automatic: 0.15, manual: .nan), 0.15)
    expectNoDifference(OutputLatencyMath.effectiveSeconds(automatic: 0.15, manual: .infinity), 0.15)
    expectNoDifference(
      OutputLatencyMath.effectiveSeconds(automatic: 0.15, manual: -.infinity), 0.15)
  }

  @Test func presentationFramesSubtractsRateScaledDelay() {
    // 0.2 s * 48000 * 2.0 = 19_200 input frames backed off.
    expectNoDifference(
      OutputLatencyMath.presentationFrames(
        renderFrames: 100_000, effectiveSeconds: 0.2, nativeSampleRate: 48_000, rate: 2.0),
      80_800)
  }

  @Test func presentationFramesScalesWithRateAtOneX() {
    expectNoDifference(
      OutputLatencyMath.presentationFrames(
        renderFrames: 100_000, effectiveSeconds: 0.2, nativeSampleRate: 48_000, rate: 1.0),
      90_400)
  }

  @Test func presentationFramesClampsToZeroAtPlaybackStart() {
    expectNoDifference(
      OutputLatencyMath.presentationFrames(
        renderFrames: 1_000, effectiveSeconds: 0.2, nativeSampleRate: 48_000, rate: 1.0),
      0)
  }

  @Test func presentationFramesReturnsRenderFramesWhenNoDelay() {
    expectNoDifference(
      OutputLatencyMath.presentationFrames(
        renderFrames: 5_000, effectiveSeconds: 0.0, nativeSampleRate: 48_000, rate: 1.0),
      5_000)
  }
}
