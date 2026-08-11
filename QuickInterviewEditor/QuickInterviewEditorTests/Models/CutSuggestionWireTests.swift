import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

/// Pure coverage for the Python↔Swift suggestion mapping — no subprocess. Proves the
/// snake-cased `CutCandidate.to_dict()` payload maps to a stamped, pending
/// `CutSuggestion`, and that malformed output fails the whole batch loudly.
struct CutSuggestionWireTests {

  private static let provenance = CutSuggestion.Provenance(
    model: "claude-sonnet-5", promptVersion: "v1", productSpecVersion: "v1",
    transcriptHash: "sha256:abc", sourceFingerprint: "fp", diarizationHash: nil)

  /// A deterministic id sequence so mapped suggestions are comparable.
  private final class IDs {
    private var next = 0
    func make() -> UUID {
      defer { next += 1 }
      return UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", next))")!
    }
  }

  private static let payload = Data(
    """
    {
      "suggestions": [
        {"product_type": "spotlight", "label": "Radney Foster story",
         "song": null, "song_verified": false, "word_ids": [4, 5, 6],
         "start_sample": 88200, "end_sample": 3616200, "start_sec": 2.0,
         "end_sec": 82.0, "duration_sec": 80.0, "rank": 1, "score": 1.0},
        {"product_type": "intro", "label": "Sets up Long Hard Look",
         "song": "Long Hard Look", "song_verified": true, "word_ids": [10],
         "start_sample": 0, "end_sample": 1323000, "start_sec": 0.0,
         "end_sec": 30.0, "duration_sec": 30.0, "rank": 2, "score": 0.9}
      ],
      "meta": {"n_sentences": 42, "n_partitions": 6}
    }
    """.utf8)

  @Test func mapsRankedCandidatesWithFreshIDsAndPendingStatus() throws {
    let ids = IDs()
    let suggestions = try CutSuggestion.decodeSuggestions(
      from: Self.payload, provenance: Self.provenance, makeID: ids.make)

    expectNoDifference(suggestions.map(\.productType), [.spotlight, .intro])
    expectNoDifference(suggestions.map(\.title), ["Radney Foster story", "Sets up Long Hard Look"])
    expectNoDifference(suggestions.map(\.rank), [1, 2])
    // Title reads the Python `label`; the intro carries its verified song.
    expectNoDifference(suggestions[1].song, "Long Hard Look")
    expectNoDifference(suggestions[1].songVerified, true)
    // Sample bounds pass through verbatim (Python derived them from the words).
    expectNoDifference(suggestions[0].startSample, 88200)
    expectNoDifference(suggestions[0].endSample, 3_616_200)
    expectNoDifference(suggestions[0].wordIDs, [4, 5, 6])
    // Every suggestion is pending and carries the request's provenance.
    #expect(suggestions.allSatisfy { $0.status == .pending })
    expectNoDifference(suggestions[0].provenance, Self.provenance)
    // ids are the injected deterministic sequence.
    expectNoDifference(
      suggestions[0].id, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
  }

  @Test func unknownProductTypeFailsTheWholeBatch() {
    let bad = Data(
      """
      {"suggestions": [{"product_type": "bumper", "label": "x", "song": null,
        "song_verified": false, "word_ids": [1], "start_sample": 0, "end_sample": 1,
        "start_sec": 0, "end_sec": 1, "duration_sec": 1, "rank": 1, "score": 1}]}
      """.utf8)
    #expect(throws: CutSuggestClientError.self) {
      _ = try CutSuggestion.decodeSuggestions(
        from: bad, provenance: Self.provenance, makeID: UUID.init)
    }
  }

  @Test func missingRequiredFieldFailsDecode() {
    // `word_ids` omitted — a partial candidate must not silently map.
    let bad = Data(
      """
      {"suggestions": [{"product_type": "spotlight", "label": "x", "song": null,
        "song_verified": false, "start_sample": 0, "end_sample": 1,
        "start_sec": 0, "end_sec": 1, "duration_sec": 1, "rank": 1, "score": 1}]}
      """.utf8)
    #expect(throws: CutSuggestClientError.self) {
      _ = try CutSuggestion.decodeSuggestions(
        from: bad, provenance: Self.provenance, makeID: UUID.init)
    }
  }

  @Test func nonJSONOutputFailsDecode() {
    let junk = Data("Traceback (most recent call last): boom".utf8)
    #expect(throws: CutSuggestClientError.self) {
      _ = try CutSuggestion.decodeSuggestions(
        from: junk, provenance: Self.provenance, makeID: UUID.init)
    }
  }

  @Test func emptySuggestionsDecodeToEmptyArray() throws {
    let empty = Data(#"{"suggestions": [], "meta": {}}"#.utf8)
    let suggestions = try CutSuggestion.decodeSuggestions(
      from: empty, provenance: Self.provenance, makeID: UUID.init)
    expectNoDifference(suggestions, [])
  }

  @Test func decodePayloadCarriesEmptyRunDiagnostics() throws {
    let empty = Data(
      """
      {"suggestions": [], "meta": {"n_sentences": 245, "n_partitions": 18,
       "n_raw_clips": 0, "n_invalid_clips": 0, "n_dropped_duration": 0}}
      """.utf8)
    let payload = try CutSuggestion.decodeSuggestionPayload(
      from: empty, provenance: Self.provenance, makeID: UUID.init)
    expectNoDifference(payload.suggestions, [])
    #expect(payload.meta?.diagnosticDescription.contains("245 transcript unit(s)") == true)
    #expect(payload.meta?.diagnosticDescription.contains("0 raw clip(s)") == true)
  }
}
