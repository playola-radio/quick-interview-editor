import Foundation

struct SequenceFieldValue: Codable, Hashable, Sendable {
  var fieldID: String
  var value: String
}

struct SuggestionSequenceKey: Codable, Hashable, Sendable {
  var typeID: String
  var fields: [SequenceFieldValue]
  var provisionalCandidateID: UUID?
}

struct SequenceReservationIdentity: Codable, Hashable, Sendable {
  var candidateID: UUID
  var key: SuggestionSequenceKey
  var number: Int
}

struct SequenceReservation: Codable, Equatable, Sendable {
  var candidateID: UUID
  var key: SuggestionSequenceKey
  var number: Int
  var canonicalValues: [String: String]

  var identity: SequenceReservationIdentity {
    SequenceReservationIdentity(candidateID: candidateID, key: key, number: number)
  }
}

struct SuggestionStart: Codable, Equatable, Sendable {
  var number: Int
  var isExplicit: Bool
}

struct SuggestionStarts: Codable, Equatable, Sendable {
  struct GroupStart: Codable, Equatable, Sendable {
    var key: SuggestionSequenceKey
    var start: SuggestionStart
  }

  var types: [String: SuggestionStart] = [:]
  var groups: [GroupStart] = []
}

enum SuggestionNumberingError: Error, Equatable {
  case invalidStart
  case minimumSafeStart(Int)
  case exhausted
}

func nextSuggestionNumber(start: Int, occupied: Set<Int>) throws -> Int {
  guard start > 0 else { throw SuggestionNumberingError.invalidStart }
  var number = start
  while occupied.contains(number) {
    let result = number.addingReportingOverflow(1)
    guard !result.overflow else { throw SuggestionNumberingError.exhausted }
    number = result.partialValue
  }
  return number
}

func allocateSuggestionNumbers(count: Int, start: Int, occupied: Set<Int>) throws -> [Int] {
  guard count >= 0, start > 0 else { throw SuggestionNumberingError.invalidStart }
  var reserved = occupied
  var cursor = start
  var numbers: [Int] = []
  numbers.reserveCapacity(count)

  for index in 0..<count {
    let number = try nextSuggestionNumber(start: cursor, occupied: reserved)
    numbers.append(number)
    reserved.insert(number)
    if index < count - 1 {
      let result = number.addingReportingOverflow(1)
      guard !result.overflow else { throw SuggestionNumberingError.exhausted }
      cursor = result.partialValue
    }
  }
  return numbers
}
