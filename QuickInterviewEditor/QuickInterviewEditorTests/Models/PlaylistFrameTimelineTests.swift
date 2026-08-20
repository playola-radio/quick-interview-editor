import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct PlaylistFrameTimelineTests {
  private func removal(_ lower: Int, _ upper: Int, length: Int) -> TimelineRemoval {
    TimelineRemoval(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      removedRange: lower..<upper,
      crossfade: Crossfade(lengthSamples: length, curve: .equalPower))
  }

  @Test func atPlanRateCursorIsStartPlusFramesPlayedAcrossSegmentsAndSeam() {
    // Plan for remove [40,60) L=10 → items span edited [0,70) contiguously.
    let plan = AudioEditRenderPlan(
      timeline: EditedTimeline(sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)]))
    let timeline = PlaylistFrameTimeline(plan: plan, ratio: 1)
    expectNoDifference(timeline.totalNativeFrames, 70)
    expectNoDifference(timeline.editedSample(forFramesPlayed: 0), 0)
    expectNoDifference(timeline.editedSample(forFramesPlayed: 25), 25)
    expectNoDifference(timeline.editedSample(forFramesPlayed: 35), 35)  // inside the seam
    expectNoDifference(timeline.editedSample(forFramesPlayed: 45), 45)
  }

  @Test func seekedPlanCursorIsOffsetFromTheSeekPoint() {
    let plan = AudioEditRenderPlan(
      timeline: EditedTimeline(sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)]),
      startEditedSample: 50)
    let timeline = PlaylistFrameTimeline(plan: plan, ratio: 1)
    expectNoDifference(timeline.totalNativeFrames, 20)  // edited [50,70)
    expectNoDifference(timeline.editedSample(forFramesPlayed: 0), 50)
    expectNoDifference(timeline.editedSample(forFramesPlayed: 10), 60)
  }

  @Test func framesPlayedIsClampedToTheEnds() {
    let plan = AudioEditRenderPlan(
      timeline: EditedTimeline(sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)]))
    let timeline = PlaylistFrameTimeline(plan: plan, ratio: 1)
    expectNoDifference(timeline.editedSample(forFramesPlayed: -5), 0)
    expectNoDifference(timeline.editedSample(forFramesPlayed: 70), 70)
    expectNoDifference(timeline.editedSample(forFramesPlayed: 9999), 70)
  }

  @Test func ratioMapsNativeFramesToPlanSamples() {
    // Identity timeline → one segment covering edited [0,100). At ratio 2 the
    // node plays 200 native frames for those 100 plan samples.
    let plan = AudioEditRenderPlan(
      timeline: EditedTimeline(sourceDurationSamples: 100, removals: []))
    let timeline = PlaylistFrameTimeline(plan: plan, ratio: 2)
    expectNoDifference(timeline.totalNativeFrames, 200)
    expectNoDifference(timeline.editedSample(forFramesPlayed: 50), 25)
    expectNoDifference(timeline.editedSample(forFramesPlayed: 200), 100)
  }

  @Test func ratioRoundingNeverReportsAnItemBoundaryEarly() {
    // At ratio 2 a 1-sample edited item schedules 2 native frames. After 1 of
    // those frames the cursor must still be INSIDE the item (edited 0), not at
    // its upper bound — the item's audio is still playing. Only exhausting the
    // whole plan may report the end.
    let plan = AudioEditRenderPlan(
      timeline: EditedTimeline(sourceDurationSamples: 1, removals: []))
    let timeline = PlaylistFrameTimeline(plan: plan, ratio: 2)
    expectNoDifference(timeline.totalNativeFrames, 2)
    expectNoDifference(timeline.editedSample(forFramesPlayed: 1), 0)
    expectNoDifference(timeline.editedSample(forFramesPlayed: 2), 1)
  }

  @Test func emptyPlanHasNoFrames() {
    let plan = AudioEditRenderPlan(
      timeline: EditedTimeline(sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)]),
      startEditedSample: 70)
    let timeline = PlaylistFrameTimeline(plan: plan, ratio: 1)
    expectNoDifference(timeline.totalNativeFrames, 0)
  }
}
