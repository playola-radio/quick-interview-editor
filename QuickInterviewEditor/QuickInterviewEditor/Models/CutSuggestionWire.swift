import Foundation

/// The wire shape the Python cutter emits (`CutCandidate.to_dict()` in
/// `cut_suggester/models.py`) and the pure mapping into a Swift `CutSuggestion`.
///
/// Kept separate from the network/subprocess plumbing so it is unit-tested with no
/// spawn: bad or missing fields fail the decode loudly rather than producing a
/// half-built suggestion. The LLM's own duration guess is display-only here — sample
/// bounds already come from the transcript words on the Python side.
extension CutSuggestion {

  /// One decoded Python candidate. `title` reads the Python `label` field; the
  /// product type is validated on the way into `CutSuggestion`, not here.
  struct Wire: Decodable, Equatable, Sendable {
    var productType: String
    var title: String
    var song: String?
    var songVerified: Bool
    var wordIDs: [Word.ID]
    var startSample: Int
    var endSample: Int
    var startSec: Double
    var endSec: Double
    var durationSec: Double
    var rank: Int
    var score: Double

    enum CodingKeys: String, CodingKey {
      case productType = "product_type"
      case title = "label"
      case song
      case songVerified = "song_verified"
      case wordIDs = "word_ids"
      case startSample = "start_sample"
      case endSample = "end_sample"
      case startSec = "start_sec"
      case endSec = "end_sec"
      case durationSec = "duration_sec"
      case rank
      case score
    }
  }

  /// The full `suggest` response: the ranked candidates plus opaque run metadata
  /// (counts) the app currently ignores.
  struct WireResponse: Decodable, Sendable {
    var suggestions: [Wire]
    var meta: WireMeta?
  }

  /// Diagnostic counts emitted by `cut_suggester.cli`. These stay optional so an older
  /// helper can still decode; when present, empty runs become explainable in the UI.
  struct WireMeta: Decodable, Equatable, Sendable {
    var nSentences: Int?
    var nPartitions: Int?
    var nRawClips: Int?
    var nInvalidClips: Int?
    var nDroppedDuration: Int?

    enum CodingKeys: String, CodingKey {
      case nSentences = "n_sentences"
      case nPartitions = "n_partitions"
      case nRawClips = "n_raw_clips"
      case nInvalidClips = "n_invalid_clips"
      case nDroppedDuration = "n_dropped_duration"
    }

    var diagnosticDescription: String {
      var parts: [String] = []
      if let nSentences { parts.append("\(nSentences) transcript unit(s)") }
      if let nPartitions { parts.append("\(nPartitions) topic partition(s)") }
      if let nRawClips { parts.append("\(nRawClips) raw clip(s) from the model") }
      if let nInvalidClips { parts.append("\(nInvalidClips) malformed clip(s)") }
      if let nDroppedDuration { parts.append("\(nDroppedDuration) clip(s) outside duration limits") }
      return parts.isEmpty
        ? "The helper returned an empty suggestions array without diagnostics."
        : parts.joined(separator: "; ") + "."
    }
  }

  /// Build a `CutSuggestion` from a decoded wire candidate. `id` is injected (a fresh
  /// UUID live; a deterministic value in tests). `status` starts `.pending`; provenance
  /// is stamped by the caller from the request. An unknown `product_type` throws so a
  /// malformed candidate never becomes a silently-wrong suggestion.
  init(wire: Wire, id: UUID, provenance: Provenance) throws {
    guard let productType = ProductType(rawValue: wire.productType) else {
      throw CutSuggestClientError.decodeFailed(
        "unknown product_type '\(wire.productType)' in suggestion '\(wire.title)'")
    }
    self.init(
      id: id,
      productType: productType,
      title: wire.title,
      song: wire.song,
      songVerified: wire.songVerified,
      wordIDs: wire.wordIDs,
      startSample: wire.startSample,
      endSample: wire.endSample,
      startSec: wire.startSec,
      endSec: wire.endSec,
      durationSec: wire.durationSec,
      rank: wire.rank,
      score: wire.score,
      status: .pending,
      provenance: provenance)
  }

  /// Decode the whole `suggest` stdout payload into stamped, pending suggestions.
  /// `makeID` supplies each suggestion's id (so tests stay deterministic). A decode
  /// failure — non-JSON, or a candidate missing a required field — throws
  /// `CutSuggestClientError.decodeFailed`, failing the whole batch rather than
  /// returning partial garbage.
  static func decodeSuggestions(
    from data: Data, provenance: Provenance, makeID: () -> UUID
  ) throws -> [CutSuggestion] {
    let payload = try decodeSuggestionPayload(from: data, provenance: provenance, makeID: makeID)
    return payload.suggestions
  }

  static func decodeSuggestionPayload(
    from data: Data, provenance: Provenance, makeID: () -> UUID
  ) throws -> (suggestions: [CutSuggestion], meta: WireMeta?) {
    let response: WireResponse
    do {
      response = try JSONDecoder().decode(WireResponse.self, from: data)
    } catch {
      // swiftlint:disable:next optional_data_string_conversion
      let preview = String(decoding: data.prefix(500), as: UTF8.self)
      throw CutSuggestClientError.decodeFailed(
        "\(error)\n\nOutput was not valid suggestion JSON. It began with:\n\(preview)")
    }
    let suggestions = try response.suggestions.map {
      try CutSuggestion(wire: $0, id: makeID(), provenance: provenance)
    }
    return (suggestions, response.meta)
  }
}
