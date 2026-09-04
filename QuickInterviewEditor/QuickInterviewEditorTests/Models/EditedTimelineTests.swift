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
    // right segment start sits at overlap start
    expectNoDifference(timeline.sourceToEdited(60), 30)
    expectNoDifference(timeline.sourceToEdited(70), 40)  // 10 into right segment
    expectNoDifference(timeline.sourceToEdited(100), 70)  // right segment end == editedDuration
    expectNoDifference(timeline.sourceToEdited(50), nil)  // inside removed range
    expectNoDifference(timeline.sourceToEdited(50, bias: .leftEdge), 40)  // edited pos of a=40
    expectNoDifference(timeline.sourceToEdited(50, bias: .rightEdge), 30)  // edited pos of b=60
  }

  @Test func editedToSourceResolvesOverlapToRightSide() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    // inside overlap → right (post-cut) source
    expectNoDifference(timeline.editedToSource(35), 65)
    expectNoDifference(timeline.editedToSource(20), 20)  // pure left segment
    expectNoDifference(timeline.editedToSource(45), 75)  // right segment past overlap
  }

  @Test func seamLookup() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    let seam = timeline.seam(containingEdited: 33)
    expectNoDifference(seam?.sourceCut, 40)
    expectNoDifference(seam?.crossfadeLength, 10)
    expectNoDifference(seam?.editedCrossfadeStart, 30)
    #expect(timeline.seam(containingEdited: 5) == nil)
  }

  @Test func editedCrossfadeCenterIsMidpointOfCrossfadeStartAndLength() {
    // editedCrossfadeStart=30, crossfadeLength=10 -> center = 30 + 10/2 = 35.
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    let seam = timeline.seams[0]
    expectNoDifference(seam.editedCrossfadeCenter, 35)
  }

  @Test func crossfadeClampsToAvailableHandle() {
    // Remove [5,95) length 20 but only 5 samples of handle on the left → clamp to 5.
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(5, 95, length: 20)])
    expectNoDifference(timeline.seams.first?.crossfadeLength, 5)
    // K0=[0,5)=5, K1=[95,100)=5, minus L=5 → 5
    expectNoDifference(timeline.editedDurationSamples, 5)
  }

  private func uuid(_ id: UInt) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02u", id))")!
  }

  @Test func maxCrossfadeLengthForIsolatedSeamIsMinOfHandles() {
    // Remove [10,20). K0=[0,10)=10, K1=[20,100)=80. max = min(right 80, left 10) = 10.
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(10, 20, length: 5, id: 1)])
    expectNoDifference(timeline.maxCrossfadeLength(forSeamID: uuid(1)), 10)
  }

  @Test func maxCrossfadeLengthAccountsForPreviousSeamClaim() {
    // Two removals share island K1=[40,60)=20. K0=[0,30)=30, K2=[70,100)=30.
    // seam0 max = min(right K1=20, left K0=30) = 20.
    // seam1 max = min(right K2=30, left K1=20 − seam0 claim 5) = 15.
    let timeline = EditedTimeline(
      sourceDurationSamples: 100,
      removals: [removal(30, 40, length: 5, id: 1), removal(60, 70, length: 5, id: 2)])
    expectNoDifference(timeline.maxCrossfadeLength(forSeamID: uuid(1)), 20)
    expectNoDifference(timeline.maxCrossfadeLength(forSeamID: uuid(2)), 15)
  }

  @Test func maxCrossfadeLengthForUnknownSeamIsNil() {
    let timeline = EditedTimeline(sourceDurationSamples: 100, removals: [])
    expectNoDifference(timeline.maxCrossfadeLength(forSeamID: uuid(1)), nil)
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

  @Test func seamsSharingAShortIslandNeverOverClaimIt() {
    // Remove [40,48) and [52,60), both requesting L=10; they share the 4-sample
    // island K1=[48,52). Adjacent claims on one segment must never sum past its
    // length — otherwise both seams cover the same edited span and the rendered
    // stream outgrows editedDurationSamples. The earlier seam wins the island
    // (clamped to 4); the later seam collapses to a hard cut.
    // K0=[0,40) len40, K1=[48,52) len4, K2=[60,100) len40.
    // editedDuration = (40+4+40) - (4+0) = 80.
    let timeline = EditedTimeline(
      sourceDurationSamples: 100,
      removals: [removal(40, 48, length: 10, id: 1), removal(52, 60, length: 10, id: 2)])
    expectNoDifference(timeline.seams.map(\.crossfadeLength), [4, 0])
    expectNoDifference(timeline.editedDurationSamples, 80)
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

  /// Regression: a persisted removal whose `upperBound` outlives a shorter/re-analyzed source
  /// (e.g. `[90,150)` against `sourceDurationSamples: 100`) must not build a reversed kept-segment
  /// `Range` and trap. It's clamped to `[90,100)`, equivalent to a removal that reaches the end.
  @Test func outOfBoundsRemovalClampsInsteadOfCrashing() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(90, 150, length: 5)])
    expectNoDifference(timeline.keptSegments.count, 2)
    // K0=[0,90) len90, K1=[100,100) len0 → no handle on the right, crossfade clamps to 0.
    expectNoDifference(timeline.seams.first?.crossfadeLength, 0)
    expectNoDifference(timeline.editedDurationSamples, 90)
  }

  /// A removal entirely outside the source (both bounds past the end) clamps to empty and is
  /// dropped, leaving the timeline identity.
  @Test func removalEntirelyOutOfBoundsIsDropped() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(150, 200, length: 5)])
    expectNoDifference(timeline.keptSegments, [KeptSegment(source: 0..<100, editedStart: 0)])
    expectNoDifference(timeline.editedDurationSamples, 100)
    expectNoDifference(timeline.seams, [])
  }

  // MARK: - editedSample(forSource:)

  @Test func editedSampleForSourceMapsWithinAKeptSegment() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    expectNoDifference(timeline.editedSample(forSource: 30), 30)  // in K0
    expectNoDifference(timeline.editedSample(forSource: 70), 40)  // in K1: 30 + (70-60)
  }

  @Test func editedSampleForSourceIsNilInsideARemoval() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    expectNoDifference(timeline.editedSample(forSource: 50), nil)
  }

  @Test func editedSampleForSourceAtASegmentBoundaryBelongsToWhateverFollows() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    // source 40 is K0's upperBound / the removal's lowerBound: half-open, so it belongs to
    // the removal, not K0 -> nil.
    expectNoDifference(timeline.editedSample(forSource: 40), nil)
    // source 60 is the removal's upperBound / K1's lowerBound: half-open, so it belongs to
    // K1 -> its editedStart, 30.
    expectNoDifference(timeline.editedSample(forSource: 60), 30)
  }

  @Test func editedSampleForSourcePastSourceEndIsNil() {
    let timeline = EditedTimeline(sourceDurationSamples: 100, removals: [])
    expectNoDifference(timeline.editedSample(forSource: 100), nil)
    expectNoDifference(timeline.editedSample(forSource: 150), nil)
  }

  // MARK: - editedFootprint(ofSource:)

  @Test func editedFootprintIsIdentityWithNoRemovals() {
    let timeline = EditedTimeline(sourceDurationSamples: 100, removals: [])
    expectNoDifference(timeline.editedFootprint(ofSource: 30..<70), 30..<70)
  }

  @Test func editedFootprintOfEmptySourceIsNil() {
    let timeline = EditedTimeline(sourceDurationSamples: 100, removals: [])
    expectNoDifference(timeline.editedFootprint(ofSource: 40..<40), nil)
  }

  /// A removal interior to the range shortens the footprint by the collapsed span (minus the
  /// crossfade overlap): remove [40,60) L=10 inside [30,80) leaves kept 30..<40 (edited 30..<40)
  /// and 60..<80 (edited 30..<50), unioned to 30..<50.
  @Test func editedFootprintShrinksForAnInteriorRemoval() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    expectNoDifference(timeline.editedFootprint(ofSource: 30..<80), 30..<50)
  }

  /// When the range's UPPER bound lands inside a crossfaded removal, the footprint must still cover
  /// the kept audio's crossfade tail — the bug the `.rightEdge` endpoint bias dropped. Remove
  /// [40,60) L=10: kept K0=[0,40)@0 spans edited 0..<40. Range [10,50) keeps source 10..<40 =>
  /// edited 10..<40 (NOT 10..<30, which stopping at the post-cut segment start would give).
  @Test func editedFootprintCoversTheCrossfadeTailWhenABoundLandsInARemoval() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    expectNoDifference(timeline.editedFootprint(ofSource: 10..<50), 10..<40)
  }

  /// A range wholly inside one removal keeps no audio, so the footprint is nil — callers pin an
  /// empty lane instead of falling back to the whole timeline.
  @Test func editedFootprintOfARangeInsideARemovalIsNil() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    expectNoDifference(timeline.editedFootprint(ofSource: 45..<55), nil)
  }

  /// Spanning several removals unions every surviving segment: remove [20,30) and [60,70), both
  /// L=0. Range [10,90) keeps 10..<20, 30..<60, 70..<90 => edited 10..<70 (editedDuration is
  /// 100-20=80; the range stops 10 short on each side).
  @Test func editedFootprintSpansMultipleRemovals() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100,
      removals: [removal(20, 30, length: 0, id: 1), removal(60, 70, length: 0, id: 2)])
    expectNoDifference(timeline.editedFootprint(ofSource: 10..<90), 10..<70)
  }
}
