import Foundation

extension EditorDocumentState {
  mutating func normalizePendingSuggestionNaming() {
    for candidate in cutSuggestions where candidate.isPending {
      guard let naming = candidate.naming else { continue }
      cutSuggestions[id: candidate.id]?.title = naming.discoveryLabel
      if let reservation = naming.reservation,
        !issuedSuggestionNumbers.contains(where: { $0.identity == reservation.identity })
      {
        cutSuggestions[id: candidate.id]?.naming?.reservation = nil
      }
    }
  }

  mutating func recordPermanentReservations(_ reservations: [SequenceReservation]) {
    for reservation in reservations
    where !issuedSuggestionNumbers.contains(where: { $0.identity == reservation.identity }) {
      issuedSuggestionNumbers.append(reservation)
    }
  }
}

enum SuggestionDocumentMutationError: Error, LocalizedError {
  case stale(String)
  case invalid(String)

  var errorDescription: String? {
    switch self {
    case .stale(let message), .invalid(let message): message
    }
  }
}

struct SuggestionAcceptance {
  var slice: Slice
  var candidate: CutSuggestion
  var batch: SuggestionBatch?
}

func suggestionSliceForAcceptance(
  id: UUID, state: EditorDocumentState, plan: EditPlan, sourceFingerprint: String
) throws -> SuggestionAcceptance {
  let result = acceptCutSuggestion(
    id, in: ProjectState(cutSuggestions: state.cutSuggestions), plan: plan,
    sourceFingerprint: sourceFingerprint, transcriptHash: plan.transcriptHash)
  let slice: Slice
  switch result {
  case .accepted(let accepted, _): slice = accepted
  case .stale(let reason):
    throw SuggestionDocumentMutationError.stale(cutSuggestionStaleMessage(reason))
  case .invalid(let reason):
    throw SuggestionDocumentMutationError.invalid(cutSuggestionInvalidMessage(reason))
  }
  guard var candidate = state.cutSuggestions[id: id] else {
    throw SuggestionDocumentMutationError.invalid("This suggestion is unavailable.")
  }
  try validateSuggestionRunApplication(candidates: [candidate], batch: state.suggestionBatch)
  if candidate.naming != nil, let batch = state.suggestionBatch {
    guard batch.snapshot.transcriptHash == plan.transcriptHash,
      batch.snapshot.sourceFingerprint == sourceFingerprint,
      batch.snapshot.sampleRate == plan.source.sampleRate
    else {
      throw SuggestionDocumentMutationError.stale(
        "The suggestion's source changed. Suggest cuts again.")
    }
  }
  var batch = state.suggestionBatch
  if candidate.naming != nil, let current = batch {
    let result = try suggestionForAcceptance(
      candidate, batch: current, starts: state.suggestionStarts,
      issued: state.issuedSuggestionNumbers)
    candidate = result.candidate
    batch = result.batch
  }
  var named = slice
  if candidate.naming != nil { named.name = candidate.title }
  named.suggestionNaming = candidate.naming
  named.suggestionTypeID =
    candidate.naming?.typeID
    ?? SuggestionDefaults.types.first(where: { $0.id == candidate.productType.rawValue })?.id
  candidate.accept()
  return .init(slice: named, candidate: candidate, batch: batch)
}
