import Foundation

/// The outcome of accepting a cut suggestion against the current `EditPlan`. Accepting
/// is transactional: on success it yields both the `Slice` (for the render pipeline) and
/// the `ProjectState` with the suggestion flipped to `.accepted`, so a caller can never
/// end up with a slice but an un-flipped suggestion (or vice versa). Stale and invalid
/// inputs return a typed reason instead of a bad `Slice` — the accept path never crashes.
enum AcceptResult: Equatable {
  /// The slice to render, plus the project state with this suggestion marked accepted.
  case accepted(Slice, ProjectState)
  /// The suggestion no longer matches the current transcript; regenerate it.
  case stale(StaleReason)
  /// The suggestion is internally malformed; it can't become a slice.
  case invalid(InvalidReason)
}

/// Why a suggestion is stale: the transcript changed under it (an engine re-run), so it
/// should be regenerated rather than forced into a slice.
enum StaleReason: Equatable {
  /// The suggestion was generated against a different source file than the current one.
  case sourceFingerprintChanged
  /// One or more of the suggestion's words no longer exist in the plan (IDs shifted).
  case missingWords([Word.ID])
}

/// Why a suggestion can't become a slice regardless of the plan — a malformed candidate.
enum InvalidReason: Equatable {
  case unknownSuggestion
  case noWords
  case duplicateWords([Word.ID])
  case wordsNotContiguous
  /// A referenced word ID appears more than once in the plan, so which occurrence's audio
  /// the cut means is ambiguous (a corrupt/externally-decoded plan) — refuse to guess.
  case ambiguousPlanWords([Word.ID])
  /// Listed words lack usable (present, positive-length) sample bounds.
  case wordsMissingSampleBounds([Word.ID])
  /// The words run backwards in audio (starts not non-decreasing), so a tight range
  /// can't be derived (a corrupt or misaligned plan) — `min…max` would span unrelated
  /// audio.
  case wordsOutOfOrder
  /// The derived range falls outside the file `0..<durationSamples`; the engine would
  /// reject the cut.
  case samplesOutOfBounds
  /// Re-deriving membership from the word-derived range disagreed with the suggestion's
  /// words (a loose/overlapping neighbour would join, or a word would drop) — refusing
  /// avoids silently accepting a different cut than the one suggested.
  case wordMembershipMismatch
}

/// Converts an accepted cut suggestion into a `Slice` against the current `EditPlan`,
/// then marks it accepted in a returned copy of `ProjectState`.
///
/// Sample bounds are derived from the suggestion's **words** located in the plan, never
/// from the suggestion's own (possibly stale) `startSample`/`endSample`. The slice is
/// built by the shared `buildSlice`, so its name-free derivation (word membership,
/// snippet, warnings) is identical to a slice made in the editor. `Slice.id` is set to
/// the suggestion's id so a re-accept is idempotent and a caller can link the two.
///
/// - Parameters:
///   - id: The suggestion to accept.
///   - state: The project sidecar holding the suggestion.
///   - plan: The current edit plan (source of truth for words/samples/silences).
///   - sourceFingerprint: The current source file's fingerprint, to detect a stale
///     suggestion generated against a different file.
func acceptCutSuggestion(
  _ id: CutSuggestion.ID, in state: ProjectState, plan: EditPlan, sourceFingerprint: String
) -> AcceptResult {
  guard let suggestion = state.cutSuggestions[id: id] else {
    return .invalid(.unknownSuggestion)
  }
  guard suggestion.provenance.sourceFingerprint == sourceFingerprint else {
    return .stale(.sourceFingerprintChanged)
  }
  // NOTE: `provenance.transcriptHash` is intentionally not compared here. There is no
  // canonical transcript-hash producer yet (that lands with `CutSuggestClient` in a later
  // PR), so the transcript-drift check is deferred. The real re-run hazard — word IDs
  // shifting — is already caught structurally by the missing-words / contiguity /
  // membership checks below, and `sourceFingerprint` catches a changed source file.
  guard !suggestion.wordIDs.isEmpty else {
    return .invalid(.noWords)
  }

  let words: [Word]
  let range: Range<Int>
  switch resolveWords(suggestion.wordIDs, in: plan) {
  case .resolved(let resolved, let resolvedRange):
    words = resolved
    range = resolvedRange
  case .failed(let result): return result
  }

  let slice = buildSlice(
    id: suggestion.id, name: sliceName(for: suggestion), range: range, plan: plan)

  // `buildSlice` recomputes membership by audio midpoint over the derived range. For a
  // clean disjoint span that's exactly the validated words; if it isn't, the accepted
  // slice would silently differ from the suggestion — refuse rather than mislead.
  guard slice.wordIDs == words.map(\.id) else {
    return .invalid(.wordMembershipMismatch)
  }

  var newState = state
  newState.acceptSuggestion(id)
  return .accepted(slice, newState)
}

/// Either the contiguous, sample-bounded words a suggestion resolved to (with the tight
/// sample range they occupy), or the `AcceptResult` explaining why it couldn't.
private enum WordResolution {
  case resolved([Word], Range<Int>)
  case failed(AcceptResult)
}

/// Resolves a suggestion's word IDs against the current plan into a contiguous run of
/// words that all carry usable sample bounds — or the `AcceptResult` that explains why
/// it couldn't. Kept separate so `acceptCutSuggestion` reads as accept-and-flip.
private func resolveWords(_ wordIDs: [Word.ID], in plan: EditPlan) -> WordResolution {
  // Duplicate IDs would corrupt the contiguity check and signal a malformed suggestion.
  let duplicates = duplicatedIDs(wordIDs)
  guard duplicates.isEmpty else {
    return .failed(.invalid(.duplicateWords(duplicates)))
  }

  // Locate every referenced word in the current plan.
  let indices: [Int]
  switch locateWords(wordIDs, in: plan) {
  case .located(let located): indices = located
  case .failed(let result): return .failed(result)
  }

  // A slice is one sample range; its words must be a contiguous run in transcript order.
  let sortedIndices = indices.sorted()
  guard sortedIndices.last! - sortedIndices.first! == sortedIndices.count - 1 else {
    return .failed(.invalid(.wordsNotContiguous))
  }

  // Real bounds need every selected word to carry a usable, positive-length sample span.
  let words = sortedIndices.map { plan.words[$0] }
  let unusable = words.filter { word in
    guard let start = word.startSample, let end = word.endSample else { return true }
    return start >= end
  }
  guard unusable.isEmpty else {
    return .failed(.invalid(.wordsMissingSampleBounds(unusable.map(\.id))))
  }

  // In transcript order the words must also run in audio order (non-decreasing starts).
  // Forced alignment guarantees this; a corrupt/misaligned plan with backwards timing
  // would not, and then min/max bounds would span unrelated audio into one wide slice.
  // Checking starts (not end-to-end disjointness) tolerates the slight end-overlaps
  // alignment can produce between neighbouring words.
  let inAudioOrder = zip(words, words.dropFirst()).allSatisfy { previous, next in
    previous.startSample! <= next.startSample!
  }
  guard inAudioOrder else {
    return .failed(.invalid(.wordsOutOfOrder))
  }

  // Tight bounds over the ordered run. min/max (not first/last) keeps a long word that
  // overshoots its neighbour inside the slice.
  let start = words.compactMap(\.startSample).min()!
  let end = words.compactMap(\.endSample).max()!
  guard start >= 0, end <= plan.source.durationSamples else {
    return .failed(.invalid(.samplesOutOfBounds))
  }

  return .resolved(words, start..<end)
}

/// The plan positions of a suggestion's words, or the `AcceptResult` explaining why they
/// couldn't be located unambiguously.
private enum WordLocation {
  case located([Int])
  case failed(AcceptResult)
}

/// Maps each referenced word ID to its single position in the plan. A missing ID means the
/// transcript changed under the suggestion (an engine re-run) — stale. An ID present at more
/// than one position means a corrupt/ambiguous plan — invalid; picking one silently could cut
/// the wrong audio.
private func locateWords(_ wordIDs: [Word.ID], in plan: EditPlan) -> WordLocation {
  var offsetsByID: [Word.ID: [Int]] = [:]
  for (offset, word) in plan.words.enumerated() {
    offsetsByID[word.id, default: []].append(offset)
  }
  var indices: [Int] = []
  var missing: [Word.ID] = []
  var ambiguous: [Word.ID] = []
  for wordID in wordIDs {
    switch offsetsByID[wordID]?.count ?? 0 {
    case 0: missing.append(wordID)
    case 1: indices.append(offsetsByID[wordID]![0])
    default: ambiguous.append(wordID)
    }
  }
  guard ambiguous.isEmpty else {
    return .failed(.invalid(.ambiguousPlanWords(ambiguous)))
  }
  guard missing.isEmpty else {
    return .failed(.stale(.missingWords(missing)))
  }
  return .located(indices)
}

/// The IDs that appear more than once, in first-duplicate order.
private func duplicatedIDs(_ ids: [Word.ID]) -> [Word.ID] {
  var seen: Set<Word.ID> = []
  var reported: Set<Word.ID> = []
  var duplicates: [Word.ID] = []
  for id in ids where !seen.insert(id).inserted {
    if reported.insert(id).inserted { duplicates.append(id) }
  }
  return duplicates
}

/// The slice name for an accepted suggestion: its trimmed title, or the product-type
/// label when the title is blank.
private func sliceName(for suggestion: CutSuggestion) -> String {
  let trimmed = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? suggestion.productType.displayLabel : trimmed
}
