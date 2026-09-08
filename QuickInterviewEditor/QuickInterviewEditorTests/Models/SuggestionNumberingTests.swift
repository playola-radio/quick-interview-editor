import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct SuggestionNumberingTests {
  @Test(arguments: ["1.2", "12abc", "+", "-", "+7", "0", "-1", "1 2", "１２", "", " ", "\(Int.max)0"])
  func startingNumberRequiresTheEntireInputToBePositiveDigits(input: String) {
    #expect(throws: SuggestionNumberingError.invalidStart) {
      try parseSuggestionStartingNumber(input)
    }
  }

  @Test(arguments: ["7", "007", " 7 ", "\t7\n", String(Int.max)])
  func startingNumberAcceptsPositiveIntegersAndSurroundingWhitespace(input: String) throws {
    expectNoDifference(
      try parseSuggestionStartingNumber(input), input == String(Int.max) ? Int.max : 7)
  }

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
