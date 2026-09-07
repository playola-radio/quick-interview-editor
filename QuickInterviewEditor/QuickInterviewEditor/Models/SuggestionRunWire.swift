import Foundation

struct SuggestionRunWireCandidate: Decodable, Sendable {
  var id: UUID
  var evidence: CutSuggestion.Wire
  var fields: [String: String?]

  enum CodingKeys: String, CodingKey {
    case id = "candidate_id"
    case fields
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    let decoded = try values.decodeIfPresent([String: String?].self, forKey: .fields) ?? [:]
    fields = decoded.mapValues { value in
      guard let value else { return nil }
      let trimmed = value.trimmingCharacters(
        in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}")))
      return trimmed.isEmpty ? nil : trimmed
    }
    evidence = try CutSuggestion.Wire(from: decoder)
  }

  func candidate(snapshot: SuggestionRunSnapshot, requiresCompleteFields: Bool) throws
    -> CutSuggestion
  {
    guard let type = snapshot.configuration.types.first(where: { $0.id == evidence.productType })
    else {
      throw CutSuggestClientError.decodeFailed("Candidate has an unrequested type.")
    }
    let required = Set(type.sequenceFieldIDs).union(
      type.template.compactMap { $0.kind == .field ? $0.value : nil })
    guard !requiresCompleteFields || required.isSubset(of: Set(fields.keys)),
      Set(fields.keys).isSubset(of: required)
    else { throw CutSuggestClientError.decodeFailed("Candidate has invalid or unfinished fields.") }
    var candidate = try CutSuggestion(
      wire: evidence, id: id,
      provenance: .init(
        model: snapshot.model, promptVersion: snapshot.discoveryPromptVersion,
        productSpecVersion: snapshot.productSpecVersion, transcriptHash: snapshot.transcriptHash,
        sourceFingerprint: snapshot.sourceFingerprint, diarizationHash: nil),
      allowedProductTypeIDs: Set(snapshot.configuration.types.map(\.id)))
    candidate.naming = SuggestionNamingRecord(
      runID: snapshot.runID, typeID: type.id,
      typeName: type.name, typeGroup: type.group, discoveryLabel: evidence.title,
      extractedValues: fields.compactMapValues { $0 },
      missingFieldIDs: fields.filter { $0.value == nil }.map(\.key).sorted(),
      correctedValues: [:], reservation: nil)
    return candidate
  }
}

struct SuggestionRunWireResult: Sendable {
  enum Status: String, Decodable, Sendable {
    case ready
    case needsRetry = "needs_retry"
  }

  var checkpointRevision: Int
  var status: Status
  var candidates: [CutSuggestion]
  var failedRequestKeys: [String]
  var meta: CutSuggestion.WireMeta?
  var failureMessage: String

  private struct Envelope: Decodable {
    var schemaVersion: Int
    var runID: UUID
    var checkpointRevision: Int
    var status: Status
    var suggestions: [SuggestionRunWireCandidate]
    var failedBatches: [SuggestionRunWireFailure]?
    var meta: CutSuggestion.WireMeta?
    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case runID = "run_id"
      case checkpointRevision = "checkpoint_revision"
      case failedBatches = "failed_batches"
      case status, suggestions, meta
    }
  }

  static func decode(from data: Data, snapshot: SuggestionRunSnapshot) throws -> Self {
    do {
      guard String(data: data, encoding: .utf8) != nil else {
        throw CutSuggestClientError.decodeFailed("Output is not UTF-8.")
      }
      let wire = try JSONDecoder().decode(Envelope.self, from: data)
      guard wire.schemaVersion == 2, wire.runID == snapshot.runID, wire.checkpointRevision > 0
      else {
        throw CutSuggestClientError.decodeFailed(
          "Result schema, run ID, or revision does not match.")
      }
      return Self(
        checkpointRevision: wire.checkpointRevision, status: wire.status,
        candidates: try convertCandidates(
          wire.suggestions, snapshot: snapshot, complete: wire.status == .ready),
        failedRequestKeys: wire.failedBatches?.compactMap(\.requestKey) ?? [], meta: wire.meta,
        failureMessage: suggestionFailureMessage(wire.failedBatches ?? []))
    } catch let error as CutSuggestClientError {
      throw error
    } catch {
      throw CutSuggestClientError.decodeFailed("Invalid suggestion result: \(error)")
    }
  }
}

struct SuggestionRunWireCheckpoint: Decodable, Sendable {
  enum Phase: String, Decodable, Sendable {
    case discovering
    case extracting
    case needsRetry = "needs_retry"
    case ready

    var checkpointPhase: SuggestionRunCheckpoint.Phase {
      switch self {
      case .discovering: .discovering
      case .extracting: .extracting
      case .needsRetry: .needsRetry
      case .ready: .ready
      }
    }
  }

  var schemaVersion: Int
  var runID: UUID
  var revision: Int
  var requestIdentity: String
  var phase: Phase
  var suggestions: [SuggestionRunWireCandidate]
  var completedRequestKeys: [String]
  var failedRequestKeys: [String]
  var failedBatches: [SuggestionRunWireFailure]?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case runID = "run_id"
    case requestIdentity = "request_identity"
    case completedRequestKeys = "completed_request_keys"
    case failedRequestKeys = "failed_request_keys"
    case failedBatches = "failed_batches"
    case revision, phase, suggestions
  }

  func checkpoint(
    snapshot: SuggestionRunSnapshot, proposedStarts: SuggestionStarts,
    controlRevision: Int, originalBatchFingerprint: String? = nil, isPaused: Bool = false
  ) throws -> SuggestionRunCheckpoint {
    guard schemaVersion == 1, runID == snapshot.runID, revision > 0, controlRevision >= 0,
      !requestIdentity.isEmpty
    else {
      throw CutSuggestClientError.decodeFailed(
        "Checkpoint schema, run ID, or revision does not match.")
    }
    return SuggestionRunCheckpoint(
      pythonRevision: revision, controlRevision: controlRevision,
      originalBatchFingerprint: originalBatchFingerprint, snapshot: snapshot,
      phase: isPaused ? .paused : phase.checkpointPhase,
      candidates: try convertCandidates(suggestions, snapshot: snapshot, complete: phase == .ready),
      completedRequestKeys: completedRequestKeys, failedRequestKeys: failedRequestKeys,
      proposedStarts: proposedStarts,
      failureMessage: phase == .needsRetry ? suggestionFailureMessage(failedBatches ?? []) : nil)
  }
}

private func convertCandidates(
  _ wires: [SuggestionRunWireCandidate], snapshot: SuggestionRunSnapshot,
  complete: Bool
) throws -> [CutSuggestion] {
  guard Set(wires.map(\.id)).count == wires.count else {
    throw CutSuggestClientError.decodeFailed("Duplicate candidate IDs in suggestion output.")
  }
  return try wires.map { try $0.candidate(snapshot: snapshot, requiresCompleteFields: complete) }
}

struct SuggestionRunWireFailure: Decodable, Sendable {
  var kind: String
  var requestKey: String?
  var retryable: Bool
  enum CodingKeys: String, CodingKey {
    case kind, retryable
    case requestKey = "request_key"
  }
}

private func suggestionFailureMessage(_ failures: [SuggestionRunWireFailure]) -> String {
  if failures.contains(where: { $0.kind == "input_size" && !$0.retryable }) {
    return "Some candidates exceed the extraction input limit. "
      + "Retrying unchanged input cannot complete them; "
      + "discard this run and start a new search with adjusted settings."
  }
  return "Some requests failed. Resume to retry the unfinished requests."
}
