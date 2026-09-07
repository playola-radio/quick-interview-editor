import Foundation

struct SuggestionRunSnapshot: Codable, Equatable, Sendable {
  var runID: UUID
  var configuration: SuggestionConfiguration
  var configurationHash: String
  var model: String
  var discoveryPromptVersion: String
  var extractionPromptVersion: String
  var productSpecVersion: String
  var transcriptHash: String
  var sourceFingerprint: String
  var sampleRate: Int
}

struct SuggestionNamingRecord: Codable, Equatable, Sendable {
  var runID: UUID
  var typeID: String
  var typeName: String
  var typeGroup: SuggestionGroup
  var discoveryLabel: String
  var extractedValues: [String: String]
  var missingFieldIDs: [String]
  var correctedValues: [String: String]
  var reservation: SequenceReservation?
}

struct SuggestionBatch: Codable, Equatable, Sendable {
  struct CanonicalGroup: Codable, Equatable, Sendable {
    var key: SuggestionSequenceKey
    var values: [String: String]
  }

  var snapshot: SuggestionRunSnapshot
  var actualStarts: SuggestionStarts
  var canonicalGroups: [CanonicalGroup]
}

struct SuggestionRunCheckpoint: Codable, Equatable, Sendable {
  enum Phase: String, Codable, Equatable, Sendable {
    case discovering
    case extracting
    case paused
    case needsRetry
    case needsNumbering
    case ready
  }

  var schemaVersion: Int = 1
  var pythonRevision: Int
  var controlRevision: Int
  var originalBatchFingerprint: String?
  var snapshot: SuggestionRunSnapshot
  var phase: Phase
  var candidates: [CutSuggestion]
  var completedRequestKeys: [String]
  var failedRequestKeys: [String]
  var proposedStarts: SuggestionStarts
}

enum SuggestionNumberingMode: Sendable {
  case fresh
  case pendingRenumber(selectedCandidateIDs: Set<UUID>)
  case correction(candidateID: UUID)
}

enum SuggestionBatchNumberingError: Error, Equatable {
  case unknownType(String)
  case invalidNaming(candidateID: UUID)
  case conflictingReservation(SequenceReservationIdentity)
  case duplicateCandidateID(UUID)
  case duplicateTypeID(String)
  case duplicateGroupStart(SuggestionSequenceKey)
}

enum SuggestionRunValidationError: Error, Equatable {
  case missingOwningSnapshot(UUID)
  case invalidNaming(candidateID: UUID)
}

func validateSuggestionRunApplication(
  candidates: [CutSuggestion], batch: SuggestionBatch?
) throws {
  for candidate in candidates {
    guard let naming = candidate.naming else { continue }
    guard let batch else { throw SuggestionRunValidationError.missingOwningSnapshot(naming.runID) }
    guard naming.runID == batch.snapshot.runID,
      let type = batch.snapshot.configuration.types.first(where: { $0.id == naming.typeID }),
      naming.typeName == type.name,
      naming.typeGroup == type.group,
      candidate.productType.rawValue == type.id
    else { throw SuggestionRunValidationError.invalidNaming(candidateID: candidate.id) }
    if let reservation = naming.reservation {
      let values = naming.extractedValues.merging(naming.correctedValues) { _, corrected in
        corrected
      }
      guard reservation.candidateID == candidate.id,
        reservation.number > 0,
        reservation.key
          == suggestionSequenceKey(type: type, values: values, candidateID: candidate.id)
      else { throw SuggestionRunValidationError.invalidNaming(candidateID: candidate.id) }
    }
  }
}

// swiftlint:disable:next function_body_length cyclomatic_complexity
func numberSuggestions(
  _ candidates: [CutSuggestion],
  snapshot: SuggestionRunSnapshot,
  starts: SuggestionStarts,
  issued: [SequenceReservation],
  retained: [SequenceReservation],
  mode: SuggestionNumberingMode = .fresh,
  existingBatch: SuggestionBatch? = nil
) throws -> (candidates: [CutSuggestion], batch: SuggestionBatch) {
  let rulesSnapshot: SuggestionRunSnapshot
  switch mode {
  case .fresh:
    rulesSnapshot = snapshot
  case .pendingRenumber, .correction:
    rulesSnapshot = existingBatch?.snapshot ?? snapshot
  }
  try validateNumberingInput(candidates: candidates, snapshot: rulesSnapshot, starts: starts)
  let selectedIDs = selectedCandidateIDs(in: candidates, mode: mode)
  let types = Dictionary(
    uniqueKeysWithValues: rulesSnapshot.configuration.types.map { ($0.id, $0) })
  let ordered = try candidates.sorted { lhs, rhs in
    let left = try typeID(for: lhs)
    let right = try typeID(for: rhs)
    return (lhs.startSample, lhs.endSample, left, lhs.id.uuidString)
      < (rhs.startSample, rhs.endSample, right, rhs.id.uuidString)
  }

  var occupied = [SuggestionSequenceKey: Set<Int>]()
  var issuedMaximum = [SuggestionSequenceKey: Int]()
  var owners = [SuggestionSequenceKey: [Int: Set<UUID>]]()
  for reservation in issued {
    insert(reservation, into: &occupied, owners: &owners)
    issuedMaximum[reservation.key] = max(
      issuedMaximum[reservation.key] ?? reservation.number, reservation.number)
  }
  for reservation in retained where !selectedIDs.contains(reservation.candidateID) {
    insert(reservation, into: &occupied, owners: &owners)
  }

  var canonicalGroups = Dictionary(
    (existingBatch?.canonicalGroups ?? []).map { ($0.key, $0.values) },
    uniquingKeysWith: { first, _ in first })
  let issuedCanonicalGroups = Dictionary(
    issued.compactMap { reservation in
      reservation.canonicalValues.isEmpty ? nil : (reservation.key, reservation.canonicalValues)
    }, uniquingKeysWith: { first, _ in first })
  var result = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
  var actualStarts = existingBatch?.actualStarts ?? starts

  for original in ordered where selectedIDs.contains(original.id) {
    let typeID = try typeID(for: original)
    guard let type = types[typeID] else { throw SuggestionBatchNumberingError.unknownType(typeID) }
    let source = try sourceNaming(for: original, type: type, snapshot: rulesSnapshot)
    let values = source.extractedValues.merging(source.correctedValues) { _, corrected in corrected
    }
    let key = suggestionSequenceKey(type: type, values: values, candidateID: original.id)
    let groupValues = Dictionary(
      uniqueKeysWithValues: type.sequenceFieldIDs.compactMap { fieldID in
        values[fieldID].map { (fieldID, $0) }
      })
    let canonicalValues: [String: String]
    if let stored = canonicalGroups[key] {
      canonicalValues = stored
    } else if let issuedValues = issuedCanonicalGroups[key] {
      let filtered = Dictionary(
        uniqueKeysWithValues: type.sequenceFieldIDs.compactMap { fieldID in
          issuedValues[fieldID].map { (fieldID, $0) }
        })
      canonicalGroups[key] = filtered
      canonicalValues = filtered
    } else {
      canonicalGroups[key] = groupValues
      canonicalValues = groupValues
    }
    let renderingValues = values.merging(canonicalValues) { _, canonical in canonical }
    let hasSequence = type.template.contains { $0.kind == .sequence }
    let reservation: SequenceReservation?
    if hasSequence {
      if shouldPreserveExistingReservation(source.reservation, mode: mode, owners: owners),
        let existing = source.reservation, existing.key == key,
        !hasAnotherOwner(existing, in: owners)
      {
        reservation = SequenceReservation(
          candidateID: original.id, key: key, number: existing.number,
          canonicalValues: canonicalValues)
        insert(reservation!, into: &occupied, owners: &owners)
      } else {
        let configured = configuredStart(for: key, typeID: type.id, starts: starts)
        let start = try allocationStart(
          configured, issuedMaximum: issuedMaximum[key], occupiedMaximum: occupied[key]?.max(),
          mode: mode)
        if modeRecordsActualStart(mode) {
          actualStarts.groups.removeAll { $0.key == key }
          actualStarts.groups.append(
            .init(key: key, start: .init(number: start, isExplicit: configured.isExplicit)))
        }
        let number = try nextSuggestionNumber(start: start, occupied: occupied[key] ?? [])
        reservation = SequenceReservation(
          candidateID: original.id, key: key, number: number, canonicalValues: canonicalValues)
        insert(reservation!, into: &occupied, owners: &owners)
      }
    } else {
      reservation = nil
    }

    var candidate = original
    candidate.title = renderSuggestionName(
      template: type.template, values: renderingValues, sequence: reservation?.number,
      fallback: source.discoveryLabel)
    candidate.naming = SuggestionNamingRecord(
      runID: rulesSnapshot.runID, typeID: type.id, typeName: type.name, typeGroup: type.group,
      discoveryLabel: source.discoveryLabel, extractedValues: source.extractedValues,
      missingFieldIDs: source.missingFieldIDs, correctedValues: source.correctedValues,
      reservation: reservation)
    result[candidate.id] = candidate
  }

  return (
    candidates: candidates.compactMap { result[$0.id] },
    batch: SuggestionBatch(
      snapshot: rulesSnapshot, actualStarts: actualStarts,
      canonicalGroups:
        canonicalGroups
        .map { .init(key: $0.key, values: $0.value) }
        .sorted {
          $0.key.typeID < $1.key.typeID
            || ($0.key.typeID == $1.key.typeID
              && $0.key.fields.description < $1.key.fields.description)
        })
  )
}

private func modeRecordsActualStart(_ mode: SuggestionNumberingMode) -> Bool {
  switch mode {
  case .fresh, .pendingRenumber: true
  case .correction: false
  }
}

private func selectedCandidateIDs(
  in candidates: [CutSuggestion], mode: SuggestionNumberingMode
) -> Set<UUID> {
  switch mode {
  case .fresh: Set(candidates.map(\.id))
  case .pendingRenumber(let selectedCandidateIDs):
    Set(
      candidates.filter { $0.status == .pending && selectedCandidateIDs.contains($0.id) }.map(\.id))
  case .correction(let candidateID):
    Set(candidates.filter { $0.status == .pending && $0.id == candidateID }.map(\.id))
  }
}

private func validateNumberingInput(
  candidates: [CutSuggestion], snapshot: SuggestionRunSnapshot, starts: SuggestionStarts
) throws {
  var candidateIDs = Set<UUID>()
  for candidate in candidates where !candidateIDs.insert(candidate.id).inserted {
    throw SuggestionBatchNumberingError.duplicateCandidateID(candidate.id)
  }
  var typeIDs = Set<String>()
  for type in snapshot.configuration.types where !typeIDs.insert(type.id).inserted {
    throw SuggestionBatchNumberingError.duplicateTypeID(type.id)
  }
  var groupKeys = Set<SuggestionSequenceKey>()
  for group in starts.groups where !groupKeys.insert(group.key).inserted {
    throw SuggestionBatchNumberingError.duplicateGroupStart(group.key)
  }
}

private func shouldPreserveExistingReservation(
  _ reservation: SequenceReservation?, mode: SuggestionNumberingMode,
  owners: [SuggestionSequenceKey: [Int: Set<UUID>]]
) -> Bool {
  guard let reservation else { return false }
  switch mode {
  case .correction: return true
  case .pendingRenumber: return false
  case .fresh:
    return owners[reservation.key]?[reservation.number, default: []].contains(
      reservation.candidateID) == true
  }
}

private func typeID(for candidate: CutSuggestion) throws -> String {
  let id = candidate.naming?.typeID ?? candidate.productType.rawValue
  guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw SuggestionBatchNumberingError.invalidNaming(candidateID: candidate.id)
  }
  return id
}

private func sourceNaming(
  for candidate: CutSuggestion, type: SuggestionTypeDefinition, snapshot: SuggestionRunSnapshot
) throws -> SuggestionNamingRecord {
  guard let record = candidate.naming else {
    return SuggestionNamingRecord(
      runID: snapshot.runID, typeID: type.id, typeName: type.name, typeGroup: type.group,
      discoveryLabel: candidate.title, extractedValues: [:], missingFieldIDs: [],
      correctedValues: [:], reservation: nil)
  }
  guard record.runID == snapshot.runID,
    record.typeID == type.id, record.typeName == type.name, record.typeGroup == type.group
  else {
    throw SuggestionBatchNumberingError.invalidNaming(candidateID: candidate.id)
  }
  if let reservation = record.reservation,
    reservation.candidateID != candidate.id || reservation.number <= 0
  {
    throw SuggestionBatchNumberingError.invalidNaming(candidateID: candidate.id)
  }
  return record
}

private func configuredStart(
  for key: SuggestionSequenceKey, typeID: String, starts: SuggestionStarts
) -> SuggestionStart {
  starts.groups.first(where: { $0.key == key })?.start
    ?? starts.types[typeID]
    ?? SuggestionStart(number: 1, isExplicit: false)
}

private func allocationStart(
  _ configured: SuggestionStart, issuedMaximum: Int?, occupiedMaximum: Int?,
  mode: SuggestionNumberingMode
) throws -> Int {
  if case .correction = mode {
    guard let occupiedMaximum else { return 1 }
    let next = occupiedMaximum.addingReportingOverflow(1)
    guard !next.overflow else { throw SuggestionNumberingError.exhausted }
    return next.partialValue
  }
  guard case .fresh = mode else { return configured.number }
  guard let issuedMaximum else { return configured.number }
  let next = issuedMaximum.addingReportingOverflow(1)
  guard !next.overflow else { throw SuggestionNumberingError.exhausted }
  if configured.isExplicit, configured.number <= issuedMaximum {
    throw SuggestionNumberingError.minimumSafeStart(next.partialValue)
  }
  return configured.isExplicit ? configured.number : max(configured.number, next.partialValue)
}

private func insert(
  _ reservation: SequenceReservation,
  into occupied: inout [SuggestionSequenceKey: Set<Int>],
  owners: inout [SuggestionSequenceKey: [Int: Set<UUID>]]
) {
  occupied[reservation.key, default: []].insert(reservation.number)
  owners[reservation.key, default: [:]][reservation.number, default: []].insert(
    reservation.candidateID)
}

private func hasAnotherOwner(
  _ reservation: SequenceReservation, in owners: [SuggestionSequenceKey: [Int: Set<UUID>]]
) -> Bool {
  owners[reservation.key]?[reservation.number, default: []].contains {
    $0 != reservation.candidateID
  } ?? false
}
