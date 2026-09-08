import Foundation

// `Slice` declares an explicit `init(from:)` (in an extension, so the synthesized memberwise
// initializer survives for existing call sites) so it can leniently default `editingComplete`
// for a per-file sidecar persisted before that field existed. That decoder still ignores
// unrecognized legacy keys — e.g. the top-level "warnings" array a sidecar persisted before the
// tight-join concept was retired still carries — see `SliceLegacySidecarDecodingTests` for the
// regression coverage.
struct Slice: Identifiable, Equatable, Codable {
  var id: UUID
  var name: String
  var startSample: Int  // inclusive
  var endSample: Int  // exclusive
  var wordIDs: [Word.ID]
  var snippet: String
  var editingComplete: Bool = false
  // swiftlint:disable:next implicit_optional_initialization
  var suggestionNaming: SuggestionNamingRecord? = nil
  // swiftlint:disable:next implicit_optional_initialization
  var suggestionTypeID: String? = nil

  enum CodingKeys: String, CodingKey {
    case id, name, startSample, endSample, wordIDs, snippet, editingComplete
    case suggestionNaming, suggestionTypeID
  }
}

extension Slice {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    startSample = try container.decode(Int.self, forKey: .startSample)
    endSample = try container.decode(Int.self, forKey: .endSample)
    wordIDs = try container.decode([Word.ID].self, forKey: .wordIDs)
    snippet = try container.decode(String.self, forKey: .snippet)
    editingComplete = try container.decodeIfPresent(Bool.self, forKey: .editingComplete) ?? false
    suggestionNaming = try container.decodeIfPresent(
      SuggestionNamingRecord.self, forKey: .suggestionNaming)
    suggestionTypeID = try container.decodeIfPresent(String.self, forKey: .suggestionTypeID)
  }
}
