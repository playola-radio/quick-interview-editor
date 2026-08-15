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

  /// The editor's saved clips (manual + accepted-suggestion slices) with their boundary edits,
  /// persisted so approved clips survive a relaunch.
  var slices: IdentifiedArrayOf<Slice>

  /// Manual clips the user rejected — kept in `slices` but excluded from export.
  var rejectedManualSliceIDs: Set<Slice.ID>

  /// Paragraph/speaker spec: per-file `override ?? auto_speaker_count`. Reserved.
  var speakerCountOverride: Int?

  /// Paragraph/speaker spec: `SPEAKER_00` → "Host" display-name overrides. Reserved.
  var speakerDisplayNames: [String: String]

  init(
    cutSuggestions: IdentifiedArrayOf<CutSuggestion> = [],
    slices: IdentifiedArrayOf<Slice> = [],
    rejectedManualSliceIDs: Set<Slice.ID> = [],
    speakerCountOverride: Int? = nil,
    speakerDisplayNames: [String: String] = [:]
  ) {
    self.cutSuggestions = cutSuggestions
    self.slices = slices
    self.rejectedManualSliceIDs = rejectedManualSliceIDs
    self.speakerCountOverride = speakerCountOverride
    self.speakerDisplayNames = speakerDisplayNames
  }

  enum CodingKeys: String, CodingKey {
    case cutSuggestions, slices, rejectedManualSliceIDs, speakerCountOverride, speakerDisplayNames
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
      // The clip sections degrade instead of failing loudly like `cutSuggestions`: a malformed
      // `slices`/`rejectedManualSliceIDs` must NOT throw the whole decode, or `@Shared` would fall
      // back to an empty default and the next write would clobber the real `cutSuggestions`.
      slices: (try? container.decodeIfPresent(
        IdentifiedArrayOf<Slice>.self, forKey: .slices)) ?? [],
      rejectedManualSliceIDs: (try? container.decodeIfPresent(
        Set<Slice.ID>.self, forKey: .rejectedManualSliceIDs)) ?? [],
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

  /// Resizes a still-unaccepted suggestion's boundaries in place, keeping its status. A no-op for
  /// an unknown id or an accepted one — an accepted suggestion is edited through its minted slice,
  /// so this must never rewrite the accepted sidecar range out from under it.
  mutating func resizeSuggestion(
    _ id: CutSuggestion.ID, startSample: Int, endSample: Int, wordIDs: [Word.ID]
  ) {
    guard cutSuggestions[id: id]?.status != .accepted else { return }
    cutSuggestions[id: id]?.resize(
      startSample: startSample, endSample: endSample, wordIDs: wordIDs)
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
