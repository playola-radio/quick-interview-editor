import Foundation
import IdentifiedCollections

/// The unified, Swift-owned per-file project sidecar (design decision #4). ONE store
/// per source file, keyed by source fingerprint, that survives engine re-runs and is
/// never written into `edit-plan.json`.
///
/// Holds `cutSuggestions` (this feature) plus the paragraph/speaker spec's per-file
/// overrides — `speakerCountOverride` and `speakerDisplayNames` — reserved here now
/// and populated by the paragraph PRs later, since all three share one sidecar.
struct ProjectState: Codable, Equatable, Sendable {
  /// Ranked LLM cut candidates a human accepts/edits.
  var cutSuggestions: IdentifiedArrayOf<CutSuggestion>

  /// Paragraph/speaker spec: per-file `override ?? auto_speaker_count`. Reserved.
  var speakerCountOverride: Int?

  /// Paragraph/speaker spec: `SPEAKER_00` → "Host" display-name overrides. Reserved.
  var speakerDisplayNames: [String: String]

  init(
    cutSuggestions: IdentifiedArrayOf<CutSuggestion> = [],
    speakerCountOverride: Int? = nil,
    speakerDisplayNames: [String: String] = [:]
  ) {
    self.cutSuggestions = cutSuggestions
    self.speakerCountOverride = speakerCountOverride
    self.speakerDisplayNames = speakerDisplayNames
  }

  enum CodingKeys: String, CodingKey {
    case cutSuggestions, speakerCountOverride, speakerDisplayNames
  }

  /// Lenient decode: every section is optional and defaults to empty. This store is
  /// shared across features that land in separate PRs (cut suggestions here; speaker
  /// override/names later), so a sidecar written by an older or partial build must
  /// still decode — otherwise `@Shared(.fileStorage(..., default:))` would fall back
  /// to an empty default and the next write would clobber real user state. A malformed
  /// *suggestion* still fails loudly; only missing top-level sections are tolerated.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      cutSuggestions: try container.decodeIfPresent(
        IdentifiedArrayOf<CutSuggestion>.self, forKey: .cutSuggestions) ?? [],
      speakerCountOverride: try container.decodeIfPresent(
        Int.self, forKey: .speakerCountOverride),
      speakerDisplayNames: try container.decodeIfPresent(
        [String: String].self, forKey: .speakerDisplayNames) ?? [:]
    )
  }
}

// MARK: - Suggestion operations (pure, no I/O)

extension ProjectState {
  mutating func acceptSuggestion(_ id: CutSuggestion.ID) {
    cutSuggestions[id: id]?.accept()
  }

  mutating func rejectSuggestion(_ id: CutSuggestion.ID) {
    cutSuggestions[id: id]?.reject()
  }

  mutating func resetSuggestion(_ id: CutSuggestion.ID) {
    cutSuggestions[id: id]?.resetToPending()
  }

  /// Suggestions ordered for display: pending first, then by ascending `rank`, with
  /// higher `score` breaking ties. `id` is the final tie-break for a stable order.
  var rankedSuggestions: [CutSuggestion] {
    cutSuggestions.sorted { lhs, rhs in
      if lhs.statusSortOrder != rhs.statusSortOrder {
        return lhs.statusSortOrder < rhs.statusSortOrder
      }
      if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
      // A NaN score would make `!=` true while both `>` are false, breaking the
      // strict-weak-ordering `sorted` requires (undefined behavior). Sink NaN to the
      // bottom so the comparator stays a total order.
      let leftScore = lhs.score.isNaN ? -.infinity : lhs.score
      let rightScore = rhs.score.isNaN ? -.infinity : rhs.score
      if leftScore != rightScore { return leftScore > rightScore }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  /// Just the still-undecided candidates, in ranked order.
  var pendingSuggestions: [CutSuggestion] {
    rankedSuggestions.filter(\.isPending)
  }
}

extension CutSuggestion {
  /// Pending sorts before decided suggestions (accepted before rejected).
  fileprivate var statusSortOrder: Int {
    switch status {
    case .pending: 0
    case .accepted: 1
    case .rejected: 2
    }
  }
}
