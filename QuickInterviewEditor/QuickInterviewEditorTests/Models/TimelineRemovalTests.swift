import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct TimelineRemovalTests {
  private func removal(_ lower: Int, _ upper: Int, length: Int = 480, id: UInt = 1)
    -> TimelineRemoval
  {
    TimelineRemoval(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02u", id))")!,
      removedRange: lower..<upper,
      crossfade: Crossfade(lengthSamples: length, curve: .equalPower))
  }

  @Test func normalizeSortsByLowerBound() {
    let out = TimelineRemovals.normalize([removal(80, 90, id: 2), removal(10, 20, id: 1)])
    expectNoDifference(out?.map(\.removedRange), [10..<20, 80..<90])
  }

  @Test func normalizeRejectsOverlap() {
    let out = TimelineRemovals.normalize([removal(10, 30, id: 1), removal(20, 40, id: 2)])
    #expect(out == nil)
  }

  @Test func normalizeAllowsAbutting() {
    let out = TimelineRemovals.normalize([removal(10, 20, id: 1), removal(20, 30, id: 2)])
    expectNoDifference(out?.map(\.removedRange), [10..<20, 20..<30])
  }

  @Test func normalizeEmptyIsEmpty() {
    expectNoDifference(TimelineRemovals.normalize([]), [])
  }
}

struct CrossfadeDecodingTests {
  @Test func legacyJSONWithoutNewFieldsDecodesWithDefaults() throws {
    // A sidecar persisted before curveAmount/centerOffsetSamples existed.
    let json = Data(#"{"lengthSamples":480,"curve":"equalPower"}"#.utf8)
    let crossfade = try JSONDecoder().decode(Crossfade.self, from: json)
    expectNoDifference(crossfade.lengthSamples, 480)
    expectNoDifference(crossfade.curve, .equalPower)
    expectNoDifference(crossfade.curveAmount, 0)
    expectNoDifference(crossfade.centerOffsetSamples, 0)
  }

  @Test func jSONWithNewFieldsDecodesThem() throws {
    let json = Data(
      #"{"lengthSamples":480,"curve":"linear","curveAmount":0.5,"centerOffsetSamples":120}"#.utf8)
    let crossfade = try JSONDecoder().decode(Crossfade.self, from: json)
    expectNoDifference(crossfade.lengthSamples, 480)
    expectNoDifference(crossfade.curve, .linear)
    expectNoDifference(crossfade.curveAmount, 0.5)
    expectNoDifference(crossfade.centerOffsetSamples, 120)
  }

  @Test func unknownOrMissingCurveFallsBackToEqualPower() throws {
    // A curve value written by a future app version (or a hand-edited sidecar)
    // must not poison the whole ProjectState decode — fall back to equalPower.
    let unknown = Data(#"{"lengthSamples":480,"curve":"sCurve"}"#.utf8)
    let fromUnknown = try JSONDecoder().decode(Crossfade.self, from: unknown)
    expectNoDifference(fromUnknown.curve, .equalPower)
    expectNoDifference(fromUnknown.lengthSamples, 480)

    let missing = Data(#"{"lengthSamples":480}"#.utf8)
    let fromMissing = try JSONDecoder().decode(Crossfade.self, from: missing)
    expectNoDifference(fromMissing.curve, .equalPower)
  }

  @Test func encodeDecodeRoundTripPreservesAllFields() throws {
    let original = Crossfade(
      lengthSamples: 240, curve: .linear, curveAmount: -0.3, centerOffsetSamples: -50)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Crossfade.self, from: data)
    expectNoDifference(decoded, original)
  }
}
