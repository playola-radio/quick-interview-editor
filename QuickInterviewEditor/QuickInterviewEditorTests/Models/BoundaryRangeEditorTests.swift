import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct BoundaryRangeEditorTests {
  private func editor(
    duration: Int = 48_000, rate: Int = 48_000, minDur: Int = 2_400,
    threshold: Int = 1_920, silences: [EditPlan.Silence] = []
  ) -> BoundaryRangeEditor {
    BoundaryRangeEditor(
      fileDurationSamples: duration, sampleRate: rate, minDurationSamples: minDur,
      snapThresholdSamples: threshold, silences: silences)
  }

  @Test func moveStartClampsToFileFloor() {
    let sut = editor()
    expectNoDifference(sut.moveStart(of: 1_000..<10_000, to: -500, snap: false), 0..<10_000)
  }

  @Test func moveStartRespectsMinDurationAgainstOppositeEdge() {
    let sut = editor(minDur: 2_400)
    // Trying to push start within < minDur of the fixed end (10_000) clamps to end - minDur.
    expectNoDifference(sut.moveStart(of: 1_000..<10_000, to: 9_999, snap: false), 7_600..<10_000)
  }

  @Test func moveEndClampsToFileCeiling() {
    let sut = editor(duration: 48_000)
    expectNoDifference(sut.moveEnd(of: 1_000..<10_000, to: 60_000, snap: false), 1_000..<48_000)
  }

  @Test func moveEndRespectsMinDurationAgainstOppositeEdge() {
    let sut = editor(minDur: 2_400)
    expectNoDifference(sut.moveEnd(of: 1_000..<10_000, to: 1_001, snap: false), 1_000..<3_400)
  }

  @Test func nudgeStartMatchesTenMsRounding() {
    let sut = editor(rate: 48_000)  // 10 ms = 480 samples
    expectNoDifference(sut.nudgeStart(of: 1_000..<10_000, byMs: -10), 520..<10_000)
    expectNoDifference(sut.nudgeStart(of: 1_000..<10_000, byMs: 10), 1_480..<10_000)
  }

  @Test func nudgeEndMatchesTenMsRounding() {
    let sut = editor(rate: 48_000)
    expectNoDifference(sut.nudgeEnd(of: 1_000..<10_000, byMs: 10), 1_000..<10_480)
    expectNoDifference(sut.nudgeEnd(of: 1_000..<10_000, byMs: -10), 1_000..<9_520)
  }

  @Test func snapTrueSnapsToNearbySilenceEdge() {
    // A silence edge at 5_050 within threshold of a moveEnd target 5_000 → snaps to 5_050.
    let sut = editor(
      threshold: 1_920, silences: [EditPlan.Silence(startSample: 5_050, endSample: 6_000)])
    expectNoDifference(sut.moveEnd(of: 1_000..<9_000, to: 5_000, snap: true), 1_000..<5_050)
    // snap:false leaves the raw target.
    expectNoDifference(sut.moveEnd(of: 1_000..<9_000, to: 5_000, snap: false), 1_000..<5_000)
  }
}
