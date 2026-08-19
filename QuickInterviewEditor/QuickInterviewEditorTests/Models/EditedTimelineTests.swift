import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct EditedTimelineTests {
  private func removal(_ lower: Int, _ upper: Int, length: Int, id: UInt = 1) -> TimelineRemoval {
    TimelineRemoval(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02u", id))")!,
      removedRange: lower..<upper,
      crossfade: Crossfade(lengthSamples: length, curve: .equalPower))
  }

  @Test func emptyTimelineIsIdentity() {
    let timeline = EditedTimeline(sourceDurationSamples: 100, removals: [])
    expectNoDifference(timeline.editedDurationSamples, 100)
    expectNoDifference(timeline.sourceToEdited(37), 37)
    expectNoDifference(timeline.editedToSource(37), 37)
  }

  @Test func singleRemovalCollapsesWithCrossfadeOverlap() {
    // Remove [40,60), L=10. Kept K0=[0,40) K1=[60,100). editedDur = 40 + 40 - 10 = 70.
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    expectNoDifference(timeline.editedDurationSamples, 70)
    expectNoDifference(timeline.sourceToEdited(30), 30)  // left segment, before overlap
    expectNoDifference(timeline.sourceToEdited(60), 30)  // right segment start sits at overlap start
    expectNoDifference(timeline.sourceToEdited(70), 40)  // 10 into right segment
    expectNoDifference(timeline.sourceToEdited(100), 70)  // right segment end == editedDuration
    expectNoDifference(timeline.sourceToEdited(50), nil)  // inside removed range
    expectNoDifference(timeline.sourceToEdited(50, bias: .leftEdge), 40)  // edited pos of a=40
    expectNoDifference(timeline.sourceToEdited(50, bias: .rightEdge), 30)  // edited pos of b=60
  }

  @Test func editedToSourceResolvesOverlapToRightSide() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    expectNoDifference(timeline.editedToSource(35), 65)  // inside overlap → right (post-cut) source
    expectNoDifference(timeline.editedToSource(20), 20)  // pure left segment
    expectNoDifference(timeline.editedToSource(45), 75)  // right segment past overlap
  }

  @Test func seamLookup() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    let seam = timeline.seam(containingEdited: 33)
    expectNoDifference(seam?.sourceCut, 40)
    expectNoDifference(seam?.crossfadeLength, 10)
    expectNoDifference(seam?.editedCenter, 30)
    #expect(timeline.seam(containingEdited: 5) == nil)
  }

  @Test func crossfadeClampsToAvailableHandle() {
    // Remove [5,95) length 20 but only 5 samples of handle on the left → clamp to 5.
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(5, 95, length: 20)])
    expectNoDifference(timeline.seams.first?.crossfadeLength, 5)
    expectNoDifference(timeline.editedDurationSamples, 5)  // K0=[0,5)=5, K1=[95,100)=5, minus L=5 → 5
  }

  @Test func sourceRangesForEditedSpansSeam() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    // Edited [25,45) crosses the seam at edited 30..40.
    expectNoDifference(timeline.sourceRanges(forEdited: 25..<45), [25..<40, 60..<75])
  }

  @Test func twoRemovalsWithAdequateIslandChainSeams() {
    // Remove [40,60) L=10 and [140,160) L=10; island K1=[60,140) (len 80) is
    // long enough that neither crossfade clamps.
    // K0=[0,40) len40, K1=[60,140) len80, K2=[160,200) len40.
    // editedStart(K0)=0
    // editedStart(K1)=0+40-10=30
    // editedStart(K2)=30+80-10=100
    // editedDuration = (40+80+40) - (10+10) = 140
    let timeline = EditedTimeline(
      sourceDurationSamples: 200,
      removals: [removal(40, 60, length: 10, id: 1), removal(140, 160, length: 10, id: 2)])
    expectNoDifference(timeline.keptSegments.count, 3)
    expectNoDifference(timeline.seams.count, 2)
    expectNoDifference(timeline.editedDurationSamples, 140)

    // One point per kept segment, verifying editedStart accumulation across both seams.
    expectNoDifference(timeline.sourceToEdited(20), 20)  // in K0
    expectNoDifference(timeline.sourceToEdited(100), 70)  // in K1: 30 + (100-60)
    expectNoDifference(timeline.sourceToEdited(180), 120)  // in K2: 100 + (180-160)

    expectNoDifference(timeline.editedToSource(20), 20)  // in K0's edited span
    expectNoDifference(timeline.editedToSource(70), 100)  // in K1's edited span
    expectNoDifference(timeline.editedToSource(120), 180)  // in K2's edited span
  }

  @Test func adjacentRemovalsCollapseKeptSegmentToZeroLength() {
    // Remove [40,50) and [50,60): the middle kept segment K1=[50,50) has zero
    // length, so both crossfades clamp to 0 (no handle on either side of it).
    // K0=[0,40) len40, K1=[50,50) len0, K2=[60,100) len40.
    // editedStart(K0)=0, editedStart(K1)=0+40-0=40, editedStart(K2)=40+0-0=40.
    // editedDuration = (40+0+40) - (0+0) = 80.
    let timeline = EditedTimeline(
      sourceDurationSamples: 100,
      removals: [removal(40, 50, length: 5, id: 1), removal(50, 60, length: 5, id: 2)])
    expectNoDifference(timeline.keptSegments.count, 3)
    expectNoDifference(timeline.seams.count, 2)
    expectNoDifference(timeline.seams.map(\.crossfadeLength), [0, 0])
    expectNoDifference(timeline.editedDurationSamples, 80)
    // A zero-length seam window never contains a query sample.
    #expect(timeline.seam(containingEdited: 40) == nil)
  }

  @Test func removalsAtStartAndEndClampToZeroForMissingHandle() {
    // Remove [0,20) at the very start and [80,100) at the very end: each has
    // no kept audio on its outer side, so both crossfades clamp to 0.
    // K0=[0,0) len0, K1=[20,80) len60, K2=[100,100) len0.
    // editedStart(K0)=0, editedStart(K1)=0+0-0=0, editedStart(K2)=0+60-0=60.
    // editedDuration = (0+60+0) - (0+0) = 60.
    let timeline = EditedTimeline(
      sourceDurationSamples: 100,
      removals: [removal(0, 20, length: 10, id: 1), removal(80, 100, length: 10, id: 2)])
    expectNoDifference(timeline.keptSegments.count, 3)
    expectNoDifference(timeline.seams.map(\.crossfadeLength), [0, 0])
    expectNoDifference(timeline.editedDurationSamples, 60)

    // Mapping still works through the sole non-empty kept segment K1.
    expectNoDifference(timeline.sourceToEdited(50), 30)  // 0 + (50-20)
    expectNoDifference(timeline.editedToSource(30), 50)  // 20 + (30-0)
  }
}
