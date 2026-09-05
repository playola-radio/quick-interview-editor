import Foundation
import IdentifiedCollections

/// The editor's undoable document: everything a saved project package persists
/// (slices, timeline removals, cut suggestions, speaker overrides) moves together, so
/// undo/redo restores all of it in one step. Deliberately excludes everything else the
/// editor tracks (selection, zoom, playback, export phase) — only the document itself.
struct EditorDocumentState: Equatable, Codable, Sendable {
  var slices: IdentifiedArrayOf<Slice>
  var timelineRemovals: IdentifiedArrayOf<TimelineRemoval>
  var cutSuggestions: IdentifiedArrayOf<CutSuggestion>
  var speakerCountOverride: Int?
  var speakerDisplayNames: [String: String]

  init(
    slices: IdentifiedArrayOf<Slice>,
    timelineRemovals: IdentifiedArrayOf<TimelineRemoval>,
    cutSuggestions: IdentifiedArrayOf<CutSuggestion> = [],
    speakerCountOverride: Int? = nil,
    speakerDisplayNames: [String: String] = [:]
  ) {
    self.slices = slices
    self.timelineRemovals = timelineRemovals
    self.cutSuggestions = cutSuggestions
    self.speakerCountOverride = speakerCountOverride
    self.speakerDisplayNames = speakerDisplayNames
  }

  enum CodingKeys: String, CodingKey {
    case slices, timelineRemovals, cutSuggestions, speakerCountOverride, speakerDisplayNames
  }

  /// Lenient decode: a project persisted before cut suggestions / speaker overrides
  /// joined the document is missing those keys — default them rather than failing the
  /// whole decode (mirrors `ProjectState`'s lenient decoder).
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      slices: try container.decode(IdentifiedArrayOf<Slice>.self, forKey: .slices),
      timelineRemovals: try container.decode(
        IdentifiedArrayOf<TimelineRemoval>.self, forKey: .timelineRemovals),
      cutSuggestions: try container.decodeIfPresent(
        IdentifiedArrayOf<CutSuggestion>.self, forKey: .cutSuggestions) ?? [],
      speakerCountOverride: try container.decodeIfPresent(
        Int.self, forKey: .speakerCountOverride),
      speakerDisplayNames: try container.decodeIfPresent(
        [String: String].self, forKey: .speakerDisplayNames) ?? [:]
    )
  }
}
