import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct CrossfadeRendererTests {
  private func expectClose(_ lhs: [Float], _ rhs: [Float], tolerance: Float = 1e-4) {
    expectNoDifference(lhs.count, rhs.count)
    for (index, (lhsValue, rhsValue)) in zip(lhs, rhs).enumerated() {
      #expect(abs(lhsValue - rhsValue) < tolerance, "index \(index): \(lhsValue) !~= \(rhsValue)")
    }
  }

  @Test func equalPowerGainsMatchKnownVector() {
    let (out, in_) = CrossfadeRenderer.gains(count: 5, curve: .equalPower)
    expectClose(out, [1.0, 0.92388, 0.70711, 0.38268, 0.0])
    expectClose(in_, [0.0, 0.38268, 0.70711, 0.92388, 1.0])
  }

  @Test func linearGainsMatchKnownVector() {
    let (out, in_) = CrossfadeRenderer.gains(count: 5, curve: .linear)
    expectNoDifference(out, [1.0, 0.75, 0.5, 0.25, 0.0])
    expectNoDifference(in_, [0.0, 0.25, 0.5, 0.75, 1.0])
  }

  @Test func equalPowerIsPowerPreservingForCountFive() {
    let (out, in_) = CrossfadeRenderer.gains(count: 5, curve: .equalPower)
    for index in out.indices {
      #expect(abs(out[index] * out[index] + in_[index] * in_[index] - 1.0) < 1e-4)
    }
  }

  @Test func equalPowerIsPowerPreservingForCountNine() {
    let (out, in_) = CrossfadeRenderer.gains(count: 9, curve: .equalPower)
    for index in out.indices {
      #expect(abs(out[index] * out[index] + in_[index] * in_[index] - 1.0) < 1e-4)
    }
  }

  @Test func equalPowerEndpointsAreExact() {
    let (out, in_) = CrossfadeRenderer.gains(count: 5, curve: .equalPower)
    #expect(out.first == 1.0)
    #expect(in_.first == 0.0)
    #expect(abs(out.last! - 0.0) < 1e-4)
    #expect(in_.last == 1.0)
  }

  @Test func linearEndpointsAreExact() {
    let (out, in_) = CrossfadeRenderer.gains(count: 5, curve: .linear)
    #expect(out.first == 1.0)
    #expect(in_.first == 0.0)
    #expect(abs(out.last! - 0.0) < 1e-4)
    #expect(in_.last == 1.0)
  }

  @Test func countOneReturnsSingleGainsFavoringOut() {
    for curve in [CrossfadeCurve.equalPower, .linear] {
      let (out, in_) = CrossfadeRenderer.gains(count: 1, curve: curve)
      expectNoDifference(out, [1.0])
      expectNoDifference(in_, [0.0])
    }
  }

  @Test func countZeroReturnsEmptyArrays() {
    for curve in [CrossfadeCurve.equalPower, .linear] {
      let (out, in_) = CrossfadeRenderer.gains(count: 0, curve: curve)
      expectNoDifference(out, [])
      expectNoDifference(in_, [])
    }
  }

  @Test func blendSingleChannelEqualPowerMatchesKnownVector() {
    let result = CrossfadeRenderer.blend(
      out: [[1, 1, 1, 1, 1]], incoming: [[1, 1, 1, 1, 1]], curve: .equalPower)
    expectNoDifference(result.count, 1)
    expectClose(result[0], [1.0, 1.30656, 1.41421, 1.30656, 1.0])
  }

  @Test func blendSingleChannelLinearMatchesKnownVector() {
    let result = CrossfadeRenderer.blend(
      out: [[1, 1, 1, 1, 1]], incoming: [[1, 1, 1, 1, 1]], curve: .linear)
    expectNoDifference(result.count, 1)
    expectClose(result[0], [1, 1, 1, 1, 1])
  }

  @Test func blendAppliesSameGainsPerChannel() {
    let result = CrossfadeRenderer.blend(
      out: [[1, 1], [0, 0]], incoming: [[0, 0], [1, 1]], curve: .linear)
    expectNoDifference(result.count, 2)
    expectClose(result[0], [1.0, 0.0])
    expectClose(result[1], [0.0, 1.0])
  }
}
