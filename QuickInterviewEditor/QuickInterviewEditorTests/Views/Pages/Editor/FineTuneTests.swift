import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct FineTuneTests {
  private let sampleRate = 44100
  private let duration = 1_800_000

  private func silence(_ start: Int, _ end: Int) -> EditPlan.Silence {
    EditPlan.Silence(startSample: start, endSample: end)
  }

  private func model(silences: [EditPlan.Silence] = []) -> FineTuneModel {
    FineTuneModel(sampleRate: sampleRate, durationSamples: duration, silences: silences)
  }

  // MARK: - Session lifecycle

  @Test func beginSetsTargetCommittedAndDraft() {
    let model = model()
    #expect(!model.isActive)
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    #expect(model.isActive)
    expectNoDifference(model.committedRange, 100_000..<300_000)
    expectNoDifference(model.draftRange, 100_000..<300_000)
    #expect(!model.hasUnsavedChange)
    #expect(model.isEditingExistingSlice)
  }

  @Test func pendingSelectionTargetIsNotAnExistingSliceEdit() {
    let model = model()
    model.begin(target: .pendingSelection, range: 100_000..<200_000)
    #expect(!model.isEditingExistingSlice)
  }

  @Test func resetDraftDropsUnsavedChange() {
    let model = model()
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    model.nudgeCutOut(byMs: 10)
    #expect(model.hasUnsavedChange)
    model.resetDraft()
    #expect(!model.hasUnsavedChange)
    expectNoDifference(model.draftRange, 100_000..<300_000)
  }

  @Test func markCommittedAdvancesTheBaseline() {
    let model = model()
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    model.nudgeCutOut(byMs: 10)
    let draft = model.draftRange!
    model.markCommitted(draft)
    expectNoDifference(model.committedRange, draft)
    #expect(!model.hasUnsavedChange)
  }

  @Test func clearEndsTheSession() {
    let model = model()
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    model.clear()
    #expect(!model.isActive)
    #expect(model.target == nil)
    #expect(model.draftRange == nil)
    #expect(model.committedRange == nil)
  }

  // MARK: - Windows & geometry

  @Test func windowsAreFixedSpanCenteredOnCommittedBoundaries() {
    let model = model()
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    let half = model.insetSpanSamples / 2
    expectNoDifference(
      model.cutInWindow, (100_000 - half)..<(100_000 - half + model.insetSpanSamples))
    expectNoDifference(
      model.cutOutWindow, (300_000 - half)..<(300_000 - half + model.insetSpanSamples))
  }

  @Test func windowExtendsPastFileStartWithoutRescaling() {
    let model = model()
    model.begin(target: .slice(UUID()), range: 1000..<300_000)
    let window = model.cutInWindow!
    #expect(window.lowerBound < 0)  // clipped, not rescaled
    // The committed boundary still maps near the inset centre.
    let posX = model.cutInLineX!
    #expect(abs(posX - model.insetWidthPixels / 2) < 2)
  }

  @Test func insetTransformsRoundTrip() {
    let model = model()
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    let window = model.cutOutWindow!
    let posX = model.insetX(forSample: 300_000, in: window)
    let back = model.sample(forInsetX: posX, in: window)
    #expect(abs(back - 300_000) <= model.insetSpanSamples / Int(model.insetWidthPixels) + 1)
  }

  // MARK: - Drag (with snap)

  @Test func dragCutOutSnapsToNearbySilenceEdge() {
    let model = model(silences: [silence(299_000, 301_000)])
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    let window = model.cutOutWindow!
    // Aim just left of the silence's end edge; within the 40 ms threshold it should snap to it.
    let posX = model.insetX(forSample: 300_600, in: window)
    model.dragCutOut(toInsetX: posX)
    expectNoDifference(model.draftRange?.upperBound, 301_000)
  }

  @Test func dragCutInSnapsToNearbySilenceEdge() {
    let model = model(silences: [silence(99_000, 101_000)])
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    let window = model.cutInWindow!
    let posX = model.insetX(forSample: 99_400, in: window)
    model.dragCutIn(toInsetX: posX)
    expectNoDifference(model.draftRange?.lowerBound, 99_000)
  }

  @Test func dragDoesNotSnapWhenNoEdgeWithinThreshold() {
    let model = model(silences: [silence(200_000, 210_000)])  // far from the cut-out window
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    let window = model.cutOutWindow!
    let target = 300_500
    let posX = model.insetX(forSample: target, in: window)
    model.dragCutOut(toInsetX: posX)
    // Lands on the floored sample, not a silence edge.
    let landed = model.draftRange!.upperBound
    #expect(abs(landed - target) < model.insetSpanSamples / Int(model.insetWidthPixels) + 1)
  }

  // MARK: - Nudge (no snap, still clamped)

  @Test func nudgeMovesByTenMillisecondsWithoutSnapping() {
    let model = model(silences: [silence(299_000, 301_000)])
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    model.nudgeCutOut(byMs: 10)
    let expected = 300_000 + Int((10.0 / 1000 * Double(sampleRate)).rounded())
    expectNoDifference(model.draftRange?.upperBound, expected)  // 300_441, not snapped to 301_000
  }

  @Test func nudgeCutInBackwardMoves() {
    let model = model()
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    model.nudgeCutIn(byMs: -10)
    let expected = 100_000 - Int((10.0 / 1000 * Double(sampleRate)).rounded())
    expectNoDifference(model.draftRange?.lowerBound, expected)
  }

  // MARK: - Clamping

  @Test func startCannotCrossEndMinusMinDuration() {
    let model = model()
    model.begin(target: .slice(UUID()), range: 100_000..<103_000)
    model.nudgeCutIn(byMs: 100)  // tries to push start well past the end
    let minSamples = Int((50.0 / 1000 * Double(sampleRate)).rounded())
    expectNoDifference(model.draftRange?.lowerBound, 103_000 - minSamples)
    #expect(model.draftRange!.lowerBound < model.draftRange!.upperBound)
  }

  @Test func endCannotExceedDuration() {
    let near = duration - 1000
    let model = model()
    model.begin(target: .slice(UUID()), range: 100_000..<near)
    model.nudgeCutOut(byMs: 1000)  // way past the file end
    expectNoDifference(model.draftRange?.upperBound, duration)
  }

  // MARK: - Live warnings

  @Test func draftWarningsRedactPerBoundary() {
    // start sits inside a silence (clean); end does not (tight).
    let model = model(silences: [silence(99_000, 101_000)])
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    expectNoDifference(model.draftWarnings, [.tightEnd])
    #expect(!model.isCutInTight)
    #expect(model.isCutOutTight)
  }

  @Test func draftWarningsFollowTheDraftAsItMoves() {
    let model = model(silences: [silence(299_000, 301_000)])
    model.begin(target: .slice(UUID()), range: 100_000..<298_800)  // end just short of the silence
    #expect(model.isCutOutTight)
    model.nudgeCutOut(byMs: 10)  // +441 → 299_241 lands inside [299_000, 301_000]
    #expect(!model.isCutOutTight)
  }

  // MARK: - Safe zones

  @Test func safeZonesSpanSilencesInsideTheWindow() {
    let model = model(silences: [silence(299_000, 301_000), silence(1_000_000, 1_001_000)])
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    // Only the near silence intersects the cut-out window.
    expectNoDifference(model.cutOutSafeZones.count, 1)
    let span = model.cutOutSafeZones[0]
    #expect(span.width > 0)
    #expect(span.positionX >= 0)
    #expect(span.positionX + span.width <= model.insetWidthPixels + 0.001)
  }

  @Test func noSafeZonesWhenSilencesAreOutsideTheWindow() {
    let model = model(silences: [silence(1_000_000, 1_001_000)])
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    expectNoDifference(model.cutOutSafeZones.count, 0)
  }

  // MARK: - Kept spans

  @Test func keptSpansFlankTheCutLine() {
    let model = model()
    model.begin(target: .slice(UUID()), range: 100_000..<300_000)
    let line = model.cutOutLineX!
    let kept = model.cutOutKeptSpan!  // Cut-out keeps the LEFT side
    expectNoDifference(kept.positionX, 0)
    #expect(abs(kept.width - line) < 0.001)
  }
}
