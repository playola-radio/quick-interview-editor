import Dependencies
import Foundation
import IssueReporting
import Testing

@testable import PlayolaInterviewEditor

struct AudioPlayerClientTests {
  @Test func testValuePlayFailsCleanlyWithoutOverride() async {
    await withKnownIssue {
      _ = try await AudioPlayerClient.testValue.play(
        URL(fileURLWithPath: "/x"), 0..<10, 44100, 1.0, PlaybackSessionID())
    }
  }

  @Test func previewValuePlayIsANoOp() async throws {
    _ = try await AudioPlayerClient.previewValue.play(
      URL(fileURLWithPath: "/x"), 0..<10, 44100, 1.0, PlaybackSessionID())
    await AudioPlayerClient.previewValue.stop(nil)
  }

  // MARK: - Live position overshoot clamp (the fine-tune inset playhead can't drift past the marker)

  /// Below the range end the reported plan sample tracks the audio exactly (start offset + played
  /// frames at the plan rate).
  @Test func sourcePlanSampleTracksTheAudioWithinTheRange() {
    let sample = AudioPlayerClient.sourcePlanSample(
      startPlanSample: 10_000, framesPlayed: 1_000, ratio: 1.0, ceiling: 40_000)
    #expect(sample == 11_000)
  }

  /// The node's frame clock keeps advancing after the last real sample, so a tick can ask for more
  /// frames than the range holds — the reported sample must cap at the range end (the cut-out
  /// marker), never past it.
  @Test func sourcePlanSampleClampsAnOvershootToTheRangeEnd() {
    let sample = AudioPlayerClient.sourcePlanSample(
      startPlanSample: 10_000, framesPlayed: 1_000_000, ratio: 1.0, ceiling: 40_000)
    #expect(sample == 40_000)
  }

  /// A nil ceiling (no active range) clamps nothing.
  @Test func sourcePlanSampleWithoutACeilingIsUnclamped() {
    let sample = AudioPlayerClient.sourcePlanSample(
      startPlanSample: 0, framesPlayed: 1_000_000, ratio: 1.0, ceiling: nil)
    #expect(sample == 1_000_000)
  }

  /// The EDITED (playlist) tick path caps its edited sample through the same `clamped` helper, so an
  /// edited overshoot stops at the finish sample and a nil ceiling passes through untouched. This
  /// pins the edited axis to the ceiling too — the source-only tests above would still pass if the
  /// edited branch dropped the clamp.
  @Test func clampedCapsAnEditedOvershootAndPassesNilThrough() {
    #expect(AudioPlayerClient.clamped(30_000, ceiling: 25_000) == 25_000)
    #expect(AudioPlayerClient.clamped(20_000, ceiling: 25_000) == 20_000)
    #expect(AudioPlayerClient.clamped(1_000_000, ceiling: nil) == 1_000_000)
  }
}
