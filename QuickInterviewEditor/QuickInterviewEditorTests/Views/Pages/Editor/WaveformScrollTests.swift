import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct WaveformScrollTests {

  // MARK: - Helpers

  private func makeModel(
    totalSamples: Int, viewportWidth: CGFloat, samplesPerPixel: Double, start: Int = 0
  ) -> WaveformModel {
    let model = WaveformModel()
    model.totalSamples = totalSamples
    model.viewportWidth = viewportWidth
    model.samplesPerPixel = samplesPerPixel
    model.visibleStartSample = start
    return model
  }

  private struct WaveformSnapshot: Equatable {
    var samplesPerPixel: Double
    var visibleStartSample: Int
  }

  private func snapshot(_ model: WaveformModel) -> WaveformSnapshot {
    WaveformSnapshot(
      samplesPerPixel: model.samplesPerPixel, visibleStartSample: model.visibleStartSample)
  }

  // MARK: - scrolled

  @Test func scrolledWithCommandDownZoomsAnchoredAtX() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 200_000)
    expectDifference(snapshot(model)) {
      model.scrolled(
        deltaX: 0, deltaY: 300, hasPreciseDeltas: true, optionDown: false, commandDown: true,
        atX: 400)
    } changes: {
      $0.samplesPerPixel = 50
      $0.visibleStartSample = 220_000
    }
  }

  @Test func scrolledWithoutCommandDownPansAndLeavesZoomUnchanged() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 200_000)
    expectDifference(snapshot(model)) {
      model.scrolled(
        deltaX: 10, deltaY: 0, hasPreciseDeltas: true, optionDown: false, commandDown: false,
        atX: 0)
    } changes: {
      $0.visibleStartSample = 199_000
    }
  }

  @Test func scrolledIgnoresNonFiniteDeltas() {
    let model = makeModel(
      totalSamples: 1_000_000, viewportWidth: 1000, samplesPerPixel: 100, start: 200_000)
    let before = snapshot(model)
    model.scrolled(
      deltaX: CGFloat.nan, deltaY: 0, hasPreciseDeltas: true, optionDown: false,
      commandDown: false, atX: 0)
    expectNoDifference(snapshot(model), before)
  }
}
