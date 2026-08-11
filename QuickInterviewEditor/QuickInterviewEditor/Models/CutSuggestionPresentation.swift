import Foundation

/// One row in the ranked cut-suggestion list. Every string and flag is precomputed here so
/// the view renders it directly (CLAUDE.md's "zero logic in views"). Built by
/// ``suggestionSections(from:currentTranscriptHash:currentFingerprint:)``.
struct SuggestionRow: Identifiable, Equatable, Sendable {
  var id: CutSuggestion.ID
  var title: String
  /// `"Song: …"`, marked when unverified — or `nil` when the suggestion names no song.
  var songLine: String?
  var timeRange: String
  var duration: String
  var rankLabel: String
  var statusLabel: String
  /// The provenance no longer matches the current transcript/source (an engine re-run
  /// under it): accepting would fail the staleness gate, so offer regeneration instead.
  var isStale: Bool
  var freshnessLabel: String
  /// Pending and fresh — the only state acceptable into a slice.
  var canAccept: Bool
  var canReject: Bool
  var showsAcceptButton: Bool
  var showsRejectButton: Bool
  /// Show the freshness warning only where it's actionable (a still-pending, stale row).
  var showsFreshnessWarning: Bool
}

/// A product-type group of rows (e.g. all "Artist Spotlight" candidates), in ranked order.
struct SuggestionSection: Identifiable, Equatable, Sendable {
  var id: String
  var title: String
  var rows: [SuggestionRow]
}

/// Groups ranked suggestions by product type, preserving the incoming order within each
/// group (pending-first, then rank — see `ProjectState.rankedSuggestions`). Section order
/// follows first appearance in the ranked list, so the group holding the best-ranked
/// candidate comes first.
func suggestionSections(
  from suggestions: [CutSuggestion], currentTranscriptHash: String, currentFingerprint: String
) -> [SuggestionSection] {
  var order: [ProductType] = []
  var rowsByType: [ProductType: [SuggestionRow]] = [:]
  for suggestion in suggestions {
    if rowsByType[suggestion.productType] == nil { order.append(suggestion.productType) }
    rowsByType[suggestion.productType, default: []].append(
      suggestionRow(
        suggestion, currentTranscriptHash: currentTranscriptHash,
        currentFingerprint: currentFingerprint))
  }
  return order.map { type in
    SuggestionSection(id: type.rawValue, title: type.displayLabel, rows: rowsByType[type] ?? [])
  }
}

/// Builds one display row, deriving freshness by comparing the suggestion's provenance
/// against the current transcript hash and source fingerprint.
func suggestionRow(
  _ suggestion: CutSuggestion, currentTranscriptHash: String, currentFingerprint: String
) -> SuggestionRow {
  let stale =
    suggestion.provenance.transcriptHash != currentTranscriptHash
    || suggestion.provenance.sourceFingerprint != currentFingerprint
  let pending = suggestion.isPending
  let trimmedTitle = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
  return SuggestionRow(
    id: suggestion.id,
    title: trimmedTitle.isEmpty ? suggestion.productType.displayLabel : trimmedTitle,
    songLine: suggestion.song.map { song in
      "Song: \(song)" + (suggestion.songVerified ? "" : " (unverified)")
    },
    timeRange: suggestion.timeRangeDisplay,
    duration: suggestion.durationDisplay,
    rankLabel: "#\(suggestion.rank)",
    statusLabel: suggestion.statusLabel,
    isStale: stale,
    freshnessLabel: stale ? "Transcript changed — regenerate" : "Up to date",
    canAccept: pending && !stale,
    canReject: pending,
    showsAcceptButton: pending,
    showsRejectButton: pending,
    showsFreshnessWarning: stale && pending
  )
}

// MARK: - Accept-failure messages

/// The user-facing message for a suggestion that's gone stale under the current transcript.
func cutSuggestionStaleMessage(_ reason: StaleReason) -> String {
  switch reason {
  case .sourceFingerprintChanged:
    return
      "This suggestion was made for a different source file. Regenerate suggestions to accept it."
  case .transcriptChanged:
    return
      "The transcript changed since this suggestion was made. Regenerate suggestions to accept it."
  case .missingWords:
    return
      "Some words this suggestion referenced are no longer in the transcript. Regenerate suggestions."
  }
}

/// The user-facing message for a suggestion that can't become a clip regardless of the plan.
func cutSuggestionInvalidMessage(_ reason: InvalidReason) -> String {
  switch reason {
  case .unknownSuggestion:
    return "That suggestion is no longer available."
  case .noWords, .wordsNotContiguous, .duplicateWords, .wordsOutOfOrder, .wordMembershipMismatch:
    return
      "This suggestion couldn't be turned into a clip — its words don't form one clean range. Try regenerating."
  case .ambiguousPlanWords, .wordsMissingSampleBounds, .samplesOutOfBounds:
    return
      "This suggestion couldn't be turned into a clip against the current audio. Try regenerating."
  }
}
