import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct DeclickFadeTests {
  @Test func frameCountUsesFadeMsAtTheClipsSampleRate() {
    // 15ms @ 48000 Hz = 720 samples.
    expectNoDifference(
      DeclickFade.frameCount(totalFrames: 100_000, sampleRate: 48000), 720)
  }

  @Test func frameCountClampsToHalfTheClipSoATinyClipDoesNotDoubleRamp() {
    // 15ms @ 48000 Hz would be 720 samples, but the clip is only 1000 frames long.
    expectNoDifference(
      DeclickFade.frameCount(totalFrames: 1000, sampleRate: 48000), 500)
  }

  @Test func frameCountIsZeroForAnEmptyClip() {
    expectNoDifference(DeclickFade.frameCount(totalFrames: 0, sampleRate: 48000), 0)
  }

  @Test func gainRampsLinearlyFromZeroToOneOverTheFadeIn() {
    let gains = (0..<5).map {
      DeclickFade.gain(atFrame: $0, totalFrames: 1000, fadeInCount: 5, fadeOutCount: 5)
    }
    expectNoDifference(gains, [0.0, 0.2, 0.4, 0.6, 0.8])
  }

  @Test func gainRampsLinearlyFromOneToZeroOverTheFadeOut() {
    let gains = (995..<1000).map {
      DeclickFade.gain(atFrame: $0, totalFrames: 1000, fadeInCount: 5, fadeOutCount: 5)
    }
    expectNoDifference(gains, [0.8, 0.6, 0.4, 0.2, 0.0])
  }

  @Test func gainIsOneBetweenTheFadeInAndFadeOutWindows() {
    for frame in [5, 100, 500, 900, 994] {
      expectNoDifference(
        DeclickFade.gain(atFrame: frame, totalFrames: 1000, fadeInCount: 5, fadeOutCount: 5), 1.0)
    }
  }

  @Test func gainIsAlwaysOneWhenBothFadeCountsAreZero() {
    for frame in [0, 1, 500, 999] {
      expectNoDifference(
        DeclickFade.gain(atFrame: frame, totalFrames: 1000, fadeInCount: 0, fadeOutCount: 0), 1.0)
    }
  }

  @Test func aClipShortEnoughForTheFadesToMeetHasNoFlatMiddle() {
    // totalFrames 10, fadeIn/out 5 each — the fades exactly meet, no plateau at 1.0.
    let gains = (0..<10).map {
      DeclickFade.gain(atFrame: $0, totalFrames: 10, fadeInCount: 5, fadeOutCount: 5)
    }
    expectNoDifference(gains, [0.0, 0.2, 0.4, 0.6, 0.8, 0.8, 0.6, 0.4, 0.2, 0.0])
  }

  @Test func applyIsANoOpWhenBothFadeCountsAreZero() {
    var samples: [Float] = [1, 2, 3, 4, 5]
    DeclickFade.apply(
      to: &samples, chunkStart: 0, totalFrames: 5, fadeInCount: 0, fadeOutCount: 0)
    expectNoDifference(samples, [1, 2, 3, 4, 5])
  }

  @Test func applyScalesAWholeBufferMatchingPerFrameGains() {
    var samples: [Float] = [10, 10, 10, 10, 10, 10, 10, 10, 10, 10]
    DeclickFade.apply(
      to: &samples, chunkStart: 0, totalFrames: 10, fadeInCount: 3, fadeOutCount: 3)
    let expected = (0..<10).map {
      10 * DeclickFade.gain(atFrame: $0, totalFrames: 10, fadeInCount: 3, fadeOutCount: 3)
    }
    expectNoDifference(samples, expected)
  }

  @Test func applyingInChunksMatchesApplyingToTheWholeBufferAtOnce() {
    let source: [Float] = (0..<1000).map { Float($0 % 17) }
    var whole = source
    DeclickFade.apply(
      to: &whole, chunkStart: 0, totalFrames: 1000, fadeInCount: 40, fadeOutCount: 40)

    var chunked = source
    var start = 0
    let chunkSize = 300
    while start < chunked.count {
      let end = min(start + chunkSize, chunked.count)
      var slice = Array(chunked[start..<end])
      DeclickFade.apply(
        to: &slice, chunkStart: start, totalFrames: 1000, fadeInCount: 40, fadeOutCount: 40)
      chunked.replaceSubrange(start..<end, with: slice)
      start = end
    }
    expectNoDifference(chunked, whole)
  }
}
