import Foundation

extension EditorDocumentState {
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
  case reservationConflict

  var errorDescription: String? {
    switch self {
    case .stale(let message), .invalid(let message): message
    case .reservationConflict:
      "This suggestion's number belongs to another suggestion. Renumber it before accepting."
    }
  }
}

func suggestionSliceForAcceptance(
  id: UUID, state: EditorDocumentState, plan: EditPlan, sourceFingerprint: String
) throws -> Slice {
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
  guard let candidate = state.cutSuggestions[id: id] else { return slice }
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
  if let reservation = candidate.naming?.reservation {
    let occupied =
      state.issuedSuggestionNumbers
      + state.cutSuggestions.compactMap { $0.naming?.reservation }
    guard
      !occupied.contains(where: {
        $0.key == reservation.key && $0.number == reservation.number && $0.candidateID != id
      })
    else { throw SuggestionDocumentMutationError.reservationConflict }
  }
  var named = slice
  named.suggestionNaming = candidate.naming
  named.suggestionTypeID =
    candidate.naming?.typeID
    ?? SuggestionDefaults.types.first(where: { $0.id == candidate.productType.rawValue })?.id
  return named
}
