import Foundation

enum SuggestionFilterState: Equatable {
  case all, some, none

  var accessibilityValue: String {
    switch self {
    case .all: "All selected"
    case .some: "Some selected"
    case .none: "None selected"
    }
  }

  var image: String {
    switch self {
    case .all: "checkmark.square"
    case .some: "minus.square"
    case .none: "square"
    }
  }
}

struct SuggestionTypeFilterRow: Identifiable {
  var id: String
  var title: String
  var group: SuggestionGroup
  var state: SuggestionFilterState
}

struct SuggestionFilterGroup: Identifiable {
  var id: SuggestionGroup
  var title: String
  var types: [SuggestionTypeFilterRow]
  var state: SuggestionFilterState {
    if types.allSatisfy({ $0.state == .all }) { return .all }
    if types.allSatisfy({ $0.state == .none }) { return .none }
    return .some
  }
}

func visibleSuggestions(_ suggestions: [CutSuggestion], selected: Set<String>?) -> [CutSuggestion] {
  guard let selected else { return suggestions }
  return suggestions.filter { selected.contains($0.productType.rawValue) }
}

/// One row in the position-ordered cut-suggestion list. Every string and flag is precomputed
/// here so the view renders it directly (CLAUDE.md's "zero logic in views"). Built by
/// ``suggestionRows(from:currentTranscriptHash:currentFingerprint:fieldNames:)``.
struct SuggestionRow: Identifiable, Equatable, Sendable {
  var id: CutSuggestion.ID
  /// The product-type name (e.g. "Artist Spotlight"), shown per row now that the list is
  /// ordered by position rather than grouped under per-type headers.
  var typeLabel: String
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
  /// Render the title as an editable field only while the suggestion is still pending — once
  /// accepted its clip already exists (rename it in the sidebar), and rejected rows are inert.
  var showsEditableTitle: Bool
  /// Keep the static title inside the row's reveal control after a suggestion is completed.
  var showsRevealableTitle: Bool
  /// The product-type fallback shown as the title field's placeholder, so a pending suggestion
  /// whose generated title is blank still shows the name its clip would take.
  var titlePlaceholder: String
  var showsReviewButton = false
  var missingFieldsMessage: String?
}

/// Ranked suggestions flattened into one list ordered by position in the audio (earliest
/// start first), so the list mirrors the transcript/waveform order rather than grouping by
/// product type. `endSample` then `id` break ties for a deterministic ordering.
func suggestionRows(
  from suggestions: [CutSuggestion], currentTranscriptHash: String, currentFingerprint: String,
  fieldNames: [String: String] = [:]
) -> [SuggestionRow] {
  suggestions
    .sorted {
      ($0.startSample, $0.endSample, $0.id.uuidString)
        < ($1.startSample, $1.endSample, $1.id.uuidString)
    }
    .map {
      suggestionRow(
        $0, currentTranscriptHash: currentTranscriptHash,
        currentFingerprint: currentFingerprint, fieldNames: fieldNames)
    }
}

/// Builds one display row, deriving freshness by comparing the suggestion's provenance
/// against the current transcript hash and source fingerprint.
func suggestionRow(
  _ suggestion: CutSuggestion, currentTranscriptHash: String, currentFingerprint: String,
  fieldNames: [String: String] = [:]
) -> SuggestionRow {
  let stale =
    suggestion.provenance.transcriptHash != currentTranscriptHash
    || suggestion.provenance.sourceFingerprint != currentFingerprint
  let pending = suggestion.isPending
  let trimmedTitle = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
  return SuggestionRow(
    id: suggestion.id,
    typeLabel: suggestion.naming?.typeName ?? suggestion.productType.displayLabel,
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
    showsFreshnessWarning: stale && pending,
    showsEditableTitle: pending && suggestion.naming == nil,
    showsRevealableTitle: !pending || suggestion.naming != nil,
    titlePlaceholder: suggestion.productType.displayLabel,
    showsReviewButton: pending && suggestion.naming != nil,
    missingFieldsMessage: missingSuggestionFields(suggestion.naming, fieldNames: fieldNames)
  )
}

private func missingSuggestionFields(
  _ naming: SuggestionNamingRecord?, fieldNames: [String: String]
) -> String? {
  guard let naming else { return nil }
  let values = naming.extractedValues.merging(naming.correctedValues) { _, value in value }
  let missing = Set(naming.missingFieldIDs).union(values.keys).filter {
    (values[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }.sorted()
  return missing.isEmpty
    ? nil : "Missing fields: " + missing.map { fieldNames[$0] ?? $0 }.joined(separator: ", ")
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
