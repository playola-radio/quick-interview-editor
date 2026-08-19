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
