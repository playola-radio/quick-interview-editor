// swiftlint:disable inclusive_language
import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct MasterReturnMatchingTests {
  @Test func preservesAmbiguityAndExcludesTheFiveSecondBoundary() {
    let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let parts = [(id: first, frameCount: 600 * 44_100), (id: second, frameCount: 604 * 44_100)]
    expectNoDifference(
      MasterReturnMatching.candidates(durationSeconds: 602, parts: parts), [first, second])
    expectNoDifference(MasterReturnMatching.candidates(durationSeconds: 609, parts: parts), [])
    expectNoDifference(
      MasterReturnMatching.candidates(durationSeconds: 609 - 1.0 / 44_100, parts: parts), [second])
    expectNoDifference(MasterReturnMatching.candidates(durationSeconds: .nan, parts: parts), [])
  }
}

// swiftlint:enable inclusive_language
