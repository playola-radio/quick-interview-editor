import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct SuggestionNumberingTests {
  @Test func nextNumberSkipsOccupiedAndChecksOverflow() throws {
    expectNoDifference(try nextSuggestionNumber(start: 7, occupied: [8]), 7)
    expectNoDifference(try nextSuggestionNumber(start: Int.max, occupied: []), Int.max)
    #expect(throws: SuggestionNumberingError.exhausted) {
      try nextSuggestionNumber(start: Int.max, occupied: [Int.max])
    }
  }

  @Test func allocationIsCheckedAndAllOrNothing() throws {
    expectNoDifference(
      try allocateSuggestionNumbers(count: 2, start: 7, occupied: [8]),
      [7, 9])
    expectNoDifference(
      try allocateSuggestionNumbers(count: 1, start: Int.max, occupied: []),
      [Int.max])
    #expect(throws: SuggestionNumberingError.exhausted) {
      try allocateSuggestionNumbers(count: 2, start: Int.max, occupied: [])
    }
    expectNoDifference(try allocateSuggestionNumbers(count: 0, start: 1, occupied: []), [])
    #expect(throws: SuggestionNumberingError.invalidStart) {
      try allocateSuggestionNumbers(count: -1, start: 1, occupied: [])
    }
    #expect(throws: SuggestionNumberingError.invalidStart) {
      try allocateSuggestionNumbers(count: 1, start: 0, occupied: [])
    }
  }
}
