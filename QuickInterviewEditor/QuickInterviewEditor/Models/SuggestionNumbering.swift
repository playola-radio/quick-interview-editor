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
    var display: GroupDisplay?
  }

  struct GroupDisplay: Codable, Equatable, Sendable {
    var typeName: String
    var fieldNames: [String: String]
    var canonicalValues: [String: String]
  }

  var types: [String: SuggestionStart] = [:]
  var groups: [GroupStart] = []
}

enum SuggestionReviewIntent {
  case fields(candidateID: UUID, runID: UUID, values: [String: String])
  case spelling(key: SuggestionSequenceKey, runID: UUID, values: [String: String])
  case futureType(typeID: String, start: Int)
  case futureGroup(key: SuggestionSequenceKey, start: Int, display: SuggestionStarts.GroupDisplay?)
  case resetGroup(SuggestionSequenceKey)
  case resetType(String)
}

enum SuggestionReviewChange {
  case batch([CutSuggestion], SuggestionBatch)
  case starts(SuggestionStarts)
}

enum SuggestionReviewError: Error, LocalizedError {
  case unavailable, locked, groupChanged

  var errorDescription: String? {
    switch self {
    case .unavailable: "This suggestion or search has changed. Close this review and open it again."
    case .locked:
      "Finish or discard the unfinished search before changing suggestion names or starts."
    case .groupChanged:
      "Group spelling must name the same song and artist. Change an individual suggestion to move it to another group."
    }
  }
}

func suggestionReviewChange(
  _ intent: SuggestionReviewIntent, document: EditorDocumentState
) throws -> SuggestionReviewChange {
  switch intent {
  case .futureType(let typeID, let start):
    guard start > 0 else { throw SuggestionNumberingError.invalidStart }
    var starts = document.suggestionStarts
    starts.types[typeID] = .init(number: start, isExplicit: true)
    return .starts(starts)
  case .futureGroup(let key, let start, let display):
    guard start > 0 else { throw SuggestionNumberingError.invalidStart }
    var starts = document.suggestionStarts
    starts.groups.removeAll { $0.key == key }
    starts.groups.append(
      .init(key: key, start: .init(number: start, isExplicit: true), display: display))
    return .starts(starts)
  case .resetGroup(let key):
    var starts = document.suggestionStarts
    starts.groups.removeAll { $0.key == key }
    return .starts(starts)
  case .resetType(let typeID):
    var starts = document.suggestionStarts
    starts.types[typeID] = nil
    return .starts(starts)
  case .fields(let candidateID, let runID, let values):
    return try fieldReviewChange(
      candidateID: candidateID, runID: runID, values: values, document: document)
  case .spelling(let key, let runID, let values):
    return try spellingReviewChange(key: key, runID: runID, values: values, document: document)
  }
}

private func fieldReviewChange(
  candidateID: UUID, runID: UUID, values: [String: String], document: EditorDocumentState
) throws -> SuggestionReviewChange {
  let batch = try reviewBatch(document, runID: runID)
  var candidates = Array(document.cutSuggestions)
  guard let index = candidates.firstIndex(where: { $0.id == candidateID && $0.isPending }),
    let naming = candidates[index].naming,
    let type = batch.snapshot.configuration.types.first(where: { $0.id == naming.typeID }),
    Set(values.keys).isSubset(of: Set(batch.snapshot.configuration.fields.map(\.id)))
  else { throw SuggestionReviewError.unavailable }
  let referenced = Set(type.template.compactMap { $0.kind == .field ? $0.value : nil })
    .union(type.sequenceFieldIDs)
  guard Set(values.keys).isSubset(of: referenced) else { throw SuggestionReviewError.unavailable }
  candidates[index].naming?.correctedValues.merge(values) { _, corrected in corrected }
  let key = reviewSequenceKey(candidates[index], batch: batch)
  if let reservation = candidates[index].naming?.reservation,
    reservation.key != key
      || !document.issuedSuggestionNumbers.contains(where: { $0.identity == reservation.identity })
  {
    candidates[index].naming?.reservation = nil
  }
  candidates[index].title = naming.discoveryLabel
  return .batch(candidates, batch)
}

func reviewSequenceKey(_ candidate: CutSuggestion, batch: SuggestionBatch) -> SuggestionSequenceKey?
{
  guard let naming = candidate.naming,
    let type = batch.snapshot.configuration.types.first(where: { $0.id == naming.typeID })
  else { return nil }
  return suggestionSequenceKey(
    type: type,
    values: naming.extractedValues.merging(naming.correctedValues) { _, value in value },
    candidateID: candidate.id)
}

private func reviewBatch(_ document: EditorDocumentState, runID: UUID) throws -> SuggestionBatch {
  guard let batch = document.suggestionBatch, batch.snapshot.runID == runID else {
    throw SuggestionReviewError.unavailable
  }
  try validateSuggestionRunApplication(candidates: Array(document.cutSuggestions), batch: batch)
  return batch
}

private func spellingReviewChange(
  key: SuggestionSequenceKey, runID: UUID, values: [String: String], document: EditorDocumentState
) throws -> SuggestionReviewChange {
  var batch = try reviewBatch(document, runID: runID)
  guard let type = batch.snapshot.configuration.types.first(where: { $0.id == key.typeID }),
    Set(values.keys) == Set(type.sequenceFieldIDs),
    suggestionSequenceKey(
      type: type, values: values, candidateID: key.provisionalCandidateID ?? runID) == key
  else { throw SuggestionReviewError.groupChanged }
  batch.canonicalGroups.removeAll { $0.key == key }
  batch.canonicalGroups.append(.init(key: key, values: values))
  let candidates = document.cutSuggestions.map { original in
    guard original.isPending, reviewSequenceKey(original, batch: batch) == key,
      let naming = original.naming
    else { return original }
    var candidate = original
    candidate.title = naming.discoveryLabel
    return candidate
  }
  return .batch(candidates, batch)
}

enum SuggestionNumberingError: Error, Equatable, LocalizedError {
  case invalidStart
  case minimumSafeStart(Int)
  case exhausted

  var errorDescription: String? {
    switch self {
    case .invalidStart: "Enter a positive whole number for the starting count."
    case .minimumSafeStart(let minimum): "The next available number is \(minimum)."
    case .exhausted:
      "This group's numbering has reached the largest supported number. No clip was added."
    }
  }
}

func parseSuggestionStartingNumber(_ text: String) throws -> Int {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
    let number = Int(trimmed), number > 0
  else { throw SuggestionNumberingError.invalidStart }
  return number
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
