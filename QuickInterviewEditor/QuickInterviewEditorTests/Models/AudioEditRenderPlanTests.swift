import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct AudioEditRenderPlanTests {
  private func removal(_ lower: Int, _ upper: Int, length: Int, id: UInt = 1) -> TimelineRemoval {
    TimelineRemoval(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02u", id))")!,
      removedRange: lower..<upper,
      crossfade: Crossfade(lengthSamples: length, curve: .equalPower))
  }

  private func id(_ number: UInt) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02u", number))")!
  }

  @Test func emptyTimelineIsOneSegmentSpanningSource() {
    let timeline = EditedTimeline(sourceDurationSamples: 100, removals: [])
    let plan = AudioEditRenderPlan(timeline: timeline)
    expectNoDifference(plan.items, [.segment(source: 0..<100, editedStart: 0)])
  }

  @Test func singleRemovalProducesSegmentSeamSegment() {
    // Remove [40,60) L=10. K0=[0,40) K1=[60,100). editedDur=70.
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    let plan = AudioEditRenderPlan(timeline: timeline)
    expectNoDifference(
      plan.items,
      [
        .segment(source: 0..<30, editedStart: 0),
        .seam(id: id(1), leftTail: 30..<40, rightHead: 60..<70, length: 10, editedStart: 30),
        .segment(source: 70..<100, editedStart: 40),
      ])
  }

  @Test func zeroLengthCrossfadeIsAHardCutWithNoSeam() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 0)])
    let plan = AudioEditRenderPlan(timeline: timeline)
    expectNoDifference(
      plan.items,
      [
        .segment(source: 0..<40, editedStart: 0),
        .segment(source: 60..<100, editedStart: 40),
      ])
  }

  @Test func twoRemovalsInterleaveSegmentsAndSeams() {
    // Remove [30,40) L=5 and [70,80) L=5. K0=[0,30) K1=[40,70) K2=[80,100).
    let timeline = EditedTimeline(
      sourceDurationSamples: 100,
      removals: [removal(30, 40, length: 5, id: 1), removal(70, 80, length: 5, id: 2)])
    let plan = AudioEditRenderPlan(timeline: timeline)
    expectNoDifference(
      plan.items,
      [
        .segment(source: 0..<25, editedStart: 0),
        .seam(id: id(1), leftTail: 25..<30, rightHead: 40..<45, length: 5, editedStart: 25),
        .segment(source: 45..<65, editedStart: 30),
        .seam(id: id(2), leftTail: 65..<70, rightHead: 80..<85, length: 5, editedStart: 50),
        .segment(source: 85..<100, editedStart: 55),
      ])
  }

  @Test func seekIntoSegmentTruncatesTheFirstItem() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    // Seek to edited 50 — inside the trailing segment (edited [40,70) → source [70,100)).
    let plan = AudioEditRenderPlan(timeline: timeline, startEditedSample: 50)
    expectNoDifference(
      plan.items,
      [.segment(source: 80..<100, editedStart: 50)])
  }

  @Test func seekIntoSeamProducesAPartialSeamFromOffset() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    // Seam covers edited [30,40). Seek to 33 → 3 samples into the crossfade.
    let plan = AudioEditRenderPlan(timeline: timeline, startEditedSample: 33)
    expectNoDifference(
      plan.items,
      [
        .seam(id: id(1), leftTail: 33..<40, rightHead: 63..<70, length: 7, editedStart: 33),
        .segment(source: 70..<100, editedStart: 40),
      ])
  }

  @Test func seekPastEndProducesNoItems() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    let plan = AudioEditRenderPlan(timeline: timeline, startEditedSample: 70)
    expectNoDifference(plan.items, [])
  }

  @Test func sharedShortIslandDoesNotProduceReversedRanges() {
    // Two removals leaving a 4-sample island [48,52); both request L=10 but the
    // island only affords smaller handles. The plan must never emit a reversed
    // source range (would trap) even when seams over-claim the island.
    let timeline = EditedTimeline(
      sourceDurationSamples: 100,
      removals: [removal(40, 48, length: 10, id: 1), removal(52, 60, length: 10, id: 2)])
    let plan = AudioEditRenderPlan(timeline: timeline)
    for item in plan.items {
      switch item {
      case .segment(let source, _):
        #expect(source.lowerBound <= source.upperBound)
      case .seam(_, let leftTail, let rightHead, let length, _):
        #expect(leftTail.lowerBound <= leftTail.upperBound)
        #expect(rightHead.lowerBound <= rightHead.upperBound)
        #expect(length >= 0)
      }
    }
  }
}
