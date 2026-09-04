import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct SliceRenderPlanTests {
  private func removal(_ lower: Int, _ upper: Int, length: Int, id: UInt = 1) -> TimelineRemoval {
    TimelineRemoval(
      id: self.id(id),
      removedRange: lower..<upper,
      crossfade: Crossfade(lengthSamples: length, curve: .equalPower))
  }

  private func id(_ number: UInt) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02u", number))")!
  }

  // MARK: - Interior classification (shared with the slice sheet's stretch handles)

  /// A removal with kept audio on both sides inside the slice renders its crossfade as stored —
  /// the slice-local timeline leaves it uncollapsed — so the slice sheet may offer stretch handles.
  @Test func removalStrictlyInsideTheSliceIsInterior() {
    let inside = removal(1400, 1500, length: 50)
    #expect(SliceRenderPlanBuilder.isInterior(inside.removedRange, in: 1000..<2000))
    let local = SliceRenderPlanBuilder.localTimeline(sliceRange: 1000..<2000, removals: [inside])
    expectNoDifference(local.seams.map(\.crossfadeLength), [50])
  }

  @Test func removalStraddlingTheSliceStartIsNotInterior() {
    #expect(!SliceRenderPlanBuilder.isInterior(900..<1100, in: 1000..<2000))
  }

  @Test func removalStraddlingTheSliceEndIsNotInterior() {
    #expect(!SliceRenderPlanBuilder.isInterior(1900..<2100, in: 1000..<2000))
  }

  /// Clipping leaves a removal that merely TOUCHES a slice edge unchanged, but the slice-local
  /// timeline has no kept audio on that side, so the crossfade collapses to a hard cut there. It is
  /// therefore not interior: a handle would author a fade the slice can't play.
  @Test func removalAbuttingTheSliceStartIsNotInterior() {
    let abutting = removal(1000, 1100, length: 50)
    #expect(!SliceRenderPlanBuilder.isInterior(abutting.removedRange, in: 1000..<2000))
    let local = SliceRenderPlanBuilder.localTimeline(sliceRange: 1000..<2000, removals: [abutting])
    expectNoDifference(local.seams.map(\.crossfadeLength), [0])
  }

  @Test func removalAbuttingTheSliceEndIsNotInterior() {
    let abutting = removal(1900, 2000, length: 50)
    #expect(!SliceRenderPlanBuilder.isInterior(abutting.removedRange, in: 1000..<2000))
    let local = SliceRenderPlanBuilder.localTimeline(sliceRange: 1000..<2000, removals: [abutting])
    expectNoDifference(local.seams.map(\.crossfadeLength), [0])
  }

  // MARK: - Plan geometry

  @Test func removalInsideTheSliceKeepsSourceRangesAbsolute() {
    // Slice [1000,2000); removal [1400,1500) L=50 → local removal [400,500).
    // K0=[0,400) K1=[500,1000); editedDur = 1000 - 100 - 50 = 850.
    let built = SliceRenderPlanBuilder.plan(
      sliceRange: 1000..<2000, removals: [removal(1400, 1500, length: 50)])

    expectNoDifference(built.sliceStart, 1000)
    expectNoDifference(built.editedDurationSamples, 850)
    expectNoDifference(built.localTimeline.editedDurationSamples, 850)
    expectNoDifference(
      built.plan.items,
      [
        .segment(source: 1000..<1350, editedStart: 0),
        .seam(
          id: id(1), leftTail: 1350..<1400, rightHead: 1500..<1550, length: 50, editedStart: 350,
          fadeOffset: 0),
        .segment(source: 1550..<2000, editedStart: 400),
      ])
  }

  @Test func crossfadeShorterThanBothHandlesKeepsItsLength() {
    let built = SliceRenderPlanBuilder.plan(
      sliceRange: 1000..<2000, removals: [removal(1400, 1500, length: 50)])
    expectNoDifference(built.localTimeline.removals.map(\.crossfade.lengthSamples), [50])
    expectNoDifference(built.localTimeline.seams.map(\.crossfadeLength), [50])
  }

  @Test func removalStraddlingTheSliceStartCollapsesToAHardCut() {
    // Removal [900,1200) clips to [1000,1200) → local [0,200): no left handle.
    let built = SliceRenderPlanBuilder.plan(
      sliceRange: 1000..<2000, removals: [removal(900, 1200, length: 50)])

    expectNoDifference(built.localTimeline.removals.map(\.removedRange), [0..<200])
    expectNoDifference(built.localTimeline.seams.map(\.crossfadeLength), [0])
    expectNoDifference(built.editedDurationSamples, 800)
    expectNoDifference(built.plan.items, [.segment(source: 1200..<2000, editedStart: 0)])
  }

  @Test func removalStraddlingTheSliceEndCollapsesToAHardCut() {
    // Removal [1800,2200) clips to [1800,2000) → local [800,1000): no right handle.
    let built = SliceRenderPlanBuilder.plan(
      sliceRange: 1000..<2000, removals: [removal(1800, 2200, length: 50)])

    expectNoDifference(built.localTimeline.removals.map(\.removedRange), [800..<1000])
    expectNoDifference(built.localTimeline.seams.map(\.crossfadeLength), [0])
    expectNoDifference(built.editedDurationSamples, 800)
    expectNoDifference(built.plan.items, [.segment(source: 1000..<1800, editedStart: 0)])
  }

  @Test func removalCoveringTheWholeSliceLeavesNothingToRender() {
    let built = SliceRenderPlanBuilder.plan(
      sliceRange: 1000..<2000, removals: [removal(500, 3000, length: 50)])

    expectNoDifference(built.editedDurationSamples, 0)
    expectNoDifference(built.plan.items, [])
  }

  @Test func removalOutsideTheSliceIsIgnored() {
    let built = SliceRenderPlanBuilder.plan(
      sliceRange: 1000..<2000, removals: [removal(100, 200, length: 50)])

    expectNoDifference(built.localTimeline.removals, [])
    expectNoDifference(built.editedDurationSamples, 1000)
    expectNoDifference(built.plan.items, [.segment(source: 1000..<2000, editedStart: 0)])
  }

  @Test func twoRemovalsSharingAShortIslandMatchAGlobalTimelineOnTheSameRebasedRemovals() {
    // Island [480,520) (40 samples) between local removals [400,480) and [520,600),
    // both requesting L=100: the first seam claims the island, the second collapses.
    let sliceRange = 1000..<2000
    let removals = [
      removal(1400, 1480, length: 100, id: 1),
      removal(1520, 1600, length: 100, id: 2),
    ]
    let local = SliceRenderPlanBuilder.localTimeline(sliceRange: sliceRange, removals: removals)
    let expected = EditedTimeline(
      sourceDurationSamples: 1000,
      removals: [
        removal(400, 480, length: 100, id: 1),
        removal(520, 600, length: 100, id: 2),
      ])

    expectNoDifference(local, expected)
    expectNoDifference(local.seams.map(\.crossfadeLength), [40, 0])
  }

  @Test func offsettingSourcesShiftsSourceRangesAndLeavesTheEditedAxisAlone() {
    let timeline = EditedTimeline(
      sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    let plan = AudioEditRenderPlan(timeline: timeline, startEditedSample: 33)

    expectNoDifference(
      plan.offsettingSources(by: 500).items,
      [
        .seam(
          id: id(1), leftTail: 533..<540, rightHead: 563..<570, length: 7, editedStart: 33,
          fadeOffset: 3),
        .segment(source: 570..<600, editedStart: 40),
      ])
  }

  // MARK: - Markers

  /// The timeline from `removalInsideTheSliceKeepsSourceRangesAbsolute`: slice
  /// [1000,2000), removal [1400,1500) L=50, editedDur 850. Source samples after the
  /// removal shift left by 150 (100 removed + 50 crossfaded).
  private var markerTimeline: EditedTimeline {
    SliceRenderPlanBuilder.localTimeline(
      sliceRange: 1000..<2000, removals: [removal(1400, 1500, length: 50)])
  }

  @Test func markersMapToSliceRelativeEditedPositions() {
    let mapped = SliceRenderPlanBuilder.markers(
      [
        RenderMarker(position: 1000, name: "first"),
        RenderMarker(position: 1200, name: "before"),
        RenderMarker(position: 1600, name: "after"),
      ],
      sliceRange: 1000..<2000,
      localTimeline: markerTimeline)

    expectNoDifference(
      mapped,
      [
        RenderMarker(position: 0, name: "first"),
        RenderMarker(position: 200, name: "before"),
        RenderMarker(position: 450, name: "after"),
      ])
  }

  @Test func markersInsideARemovalAreDropped() {
    let mapped = SliceRenderPlanBuilder.markers(
      [
        RenderMarker(position: 1450, name: "cut"),
        RenderMarker(position: 1600, name: "kept"),
      ],
      sliceRange: 1000..<2000,
      localTimeline: markerTimeline)

    expectNoDifference(mapped, [RenderMarker(position: 450, name: "kept")])
  }

  @Test func markersOutsideTheSliceAreExcludedAtTheUpperBoundOnly() {
    let mapped = SliceRenderPlanBuilder.markers(
      [
        RenderMarker(position: 999, name: "before slice"),
        RenderMarker(position: 1000, name: "lower bound"),
        RenderMarker(position: 2000, name: "upper bound"),
      ],
      sliceRange: 1000..<2000,
      localTimeline: markerTimeline)

    expectNoDifference(mapped, [RenderMarker(position: 0, name: "lower bound")])
  }

  @Test func tiedMarkersAreNudgedForwardInEditedSpace() {
    let mapped = SliceRenderPlanBuilder.markers(
      [
        RenderMarker(position: 1200, name: "one"),
        RenderMarker(position: 1200, name: "two"),
        RenderMarker(position: 1200, name: "three"),
      ],
      sliceRange: 1000..<2000,
      localTimeline: markerTimeline)

    expectNoDifference(
      mapped,
      [
        RenderMarker(position: 200, name: "one"),
        RenderMarker(position: 201, name: "two"),
        RenderMarker(position: 202, name: "three"),
      ])
  }

  @Test func aMarkerNudgedPastTheEndOfTheRenderedAudioIsDropped() {
    // Source 1999 → edited 849, the last renderable sample (editedDur 850). Its tie
    // partner nudges to 850, which no longer exists in the file.
    let mapped = SliceRenderPlanBuilder.markers(
      [
        RenderMarker(position: 1999, name: "last"),
        RenderMarker(position: 1999, name: "past end"),
      ],
      sliceRange: 1000..<2000,
      localTimeline: markerTimeline)

    expectNoDifference(mapped, [RenderMarker(position: 849, name: "last")])
  }

  @Test func mappedMarkersAreStrictlyIncreasing() {
    let mapped = SliceRenderPlanBuilder.markers(
      [
        RenderMarker(position: 1000, name: "a"),
        RenderMarker(position: 1200, name: "b"),
        RenderMarker(position: 1200, name: "c"),
        RenderMarker(position: 1450, name: "cut"),
        RenderMarker(position: 1600, name: "d"),
        RenderMarker(position: 1999, name: "e"),
      ],
      sliceRange: 1000..<2000,
      localTimeline: markerTimeline)

    expectNoDifference(mapped.map(\.name), ["a", "b", "c", "d", "e"])
    for (previous, next) in zip(mapped, mapped.dropFirst()) {
      #expect(previous.position < next.position)
    }
  }
}
