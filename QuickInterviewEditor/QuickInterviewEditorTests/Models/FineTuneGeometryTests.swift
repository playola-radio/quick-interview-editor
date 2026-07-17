import CustomDump
import Testing

@testable import QuickInterviewEditor

struct FineTuneGeometryTests {
  private func silence(_ start: Int, _ end: Int) -> EditPlan.Silence {
    EditPlan.Silence(startSample: start, endSample: end)
  }

  private func word(_ id: Int, _ start: Int?, _ end: Int?, _ text: String = "w") -> Word {
    Word(id: id, text: text, start: 0, end: nil, startSample: start, endSample: end)
  }

  private func constraints(
    _ window: ClosedRange<Int>, _ durationSamples: Int, _ minDurationSamples: Int = 100
  ) -> BoundaryConstraints {
    BoundaryConstraints(
      window: window, durationSamples: durationSamples, minDurationSamples: minDurationSamples)
  }

  // MARK: - legalBoundaryRange

  @Test func legalStartRangeHonorsFileOppositeAndWindow() {
    // window is generous; the binding limit is the opposite end minus min-duration.
    let range = legalBoundaryRange(
      moving: .start, opposite: 1000, constraints: constraints(0...5000, 5000))
    expectNoDifference(range, 0...900)
  }

  @Test func legalStartRangeClampedToWindow() {
    // a tight window overrides the looser file/opposite limits.
    let range = legalBoundaryRange(
      moving: .start, opposite: 4000, constraints: constraints(1200...1800, 5000))
    expectNoDifference(range, 1200...1800)
  }

  @Test func legalEndRangeHonorsFileOppositeAndWindow() {
    let range = legalBoundaryRange(
      moving: .end, opposite: 1000, constraints: constraints(0...5000, 4000))
    expectNoDifference(range, 1100...4000)
  }

  @Test func legalRangeCollapsesRatherThanInverts() {
    // opposite - min sits below the window lower bound → single-point range, never inverted.
    let range = legalBoundaryRange(
      moving: .start, opposite: 150, constraints: constraints(1000...2000, 5000))
    #expect(range.lowerBound <= range.upperBound)
    expectNoDifference(range, 1000...1000)
  }

  // MARK: - clampedBoundary

  @Test func clampedBoundaryPullsProposalIntoLegalInterval() {
    let limits = constraints(0...5000, 5000)
    // proposal past the min-duration limit is pulled back to it.
    expectNoDifference(
      clampedBoundary(999, moving: .start, opposite: 1000, constraints: limits), 900)
    // a legal proposal is untouched.
    expectNoDifference(
      clampedBoundary(500, moving: .start, opposite: 1000, constraints: limits), 500)
    // negative proposal clamps to file start.
    expectNoDifference(
      clampedBoundary(-50, moving: .start, opposite: 1000, constraints: limits), 0)
  }

  @Test func clampedEndBoundaryRespectsDurationAndMinDuration() {
    let limits = constraints(0...10000, 8000)
    expectNoDifference(
      clampedBoundary(99999, moving: .end, opposite: 2000, constraints: limits), 8000)
    expectNoDifference(
      clampedBoundary(2050, moving: .end, opposite: 2000, constraints: limits), 2100)
  }

  // MARK: - nearestSilenceEdge

  @Test func snapsToNearestEdgeWithinThreshold() {
    let edge = nearestSilenceEdge(
      sample: 1010, thresholdSamples: 50, silences: [silence(900, 1000), silence(2000, 2100)],
      legalRange: 0...5000)
    expectNoDifference(edge, 1000)
  }

  @Test func noSnapWhenAllEdgesBeyondThreshold() {
    let edge = nearestSilenceEdge(
      sample: 1500, thresholdSamples: 50, silences: [silence(900, 1000), silence(2000, 2100)],
      legalRange: 0...5000)
    expectNoDifference(edge, nil)
  }

  @Test func ignoresEdgesOutsideLegalRange() {
    // The closest edge (1000) is illegal; the next legal edge (2000) is beyond threshold → nil.
    let edge = nearestSilenceEdge(
      sample: 1010, thresholdSamples: 50, silences: [silence(900, 1000), silence(2000, 2100)],
      legalRange: 1100...5000)
    expectNoDifference(edge, nil)
  }

  @Test func zeroThresholdStillSnapsExactMatch() {
    let edge = nearestSilenceEdge(
      sample: 1000, thresholdSamples: 0, silences: [silence(900, 1000)], legalRange: 0...5000)
    expectNoDifference(edge, 1000)
  }

  @Test func tieResolvesToSmallerSample() {
    // sample 1000 is equidistant (100) from edge 900 and edge 1100 → pick the smaller, 900.
    let edge = nearestSilenceEdge(
      sample: 1000, thresholdSamples: 200, silences: [silence(500, 900), silence(1100, 1300)],
      legalRange: 0...5000)
    expectNoDifference(edge, 900)
  }

  // MARK: - wordIDs(overlapping:)

  @Test func wordMembershipByMidpoint() {
    let words = [
      word(1, 0, 100),  // midpoint 50 — inside [40, 500)
      word(2, 100, 300),  // midpoint 200 — inside
      word(3, 300, 500),  // midpoint 400 — inside
      word(4, 480, 520),  // midpoint 500 — excluded (upper is exclusive)
    ]
    expectNoDifference(wordIDs(overlapping: 40..<500, words: words), [1, 2, 3])
  }

  @Test func wordMembershipSkipsWordsWithoutSampleBounds() {
    let words = [word(1, nil, nil), word(2, 100, 300), word(3, 300, nil)]
    expectNoDifference(wordIDs(overlapping: 0..<500, words: words), [2])
  }

  @Test func wordMembershipLowerBoundInclusive() {
    // A word whose midpoint equals the lower bound is included.
    let words = [word(1, 90, 110)]  // midpoint 100
    expectNoDifference(wordIDs(overlapping: 100..<500, words: words), [1])
  }

  // MARK: - sliceSnippet

  @Test func snippetJoinsInIDOrder() {
    let words = [word(1, 0, 1, "So"), word(2, 1, 2, "a"), word(3, 2, 3, "young")]
    expectNoDifference(sliceSnippet(for: [1, 2, 3], words: words), "So a young")
  }

  @Test func snippetSkipsUnknownIDs() {
    let words = [word(1, 0, 1, "So"), word(2, 1, 2, "a")]
    expectNoDifference(sliceSnippet(for: [1, 99, 2], words: words), "So a")
  }
}
