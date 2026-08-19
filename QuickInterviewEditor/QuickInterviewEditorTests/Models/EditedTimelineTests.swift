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
}
