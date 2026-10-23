import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

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

  @Test func unknownProductTypeDoesNotExposeCandidateValues() {
    let bad = Data(
      """
      {"suggestions": [{"product_type": "private-bumper", "label": "confidential harbour", "song": null,
        "song_verified": false, "word_ids": [1], "start_sample": 0, "end_sample": 1,
        "start_sec": 0, "end_sec": 1, "duration_sec": 1, "rank": 1, "score": 1}]}
      """.utf8)
    do {
      _ = try CutSuggestion.decodeSuggestions(
        from: bad, provenance: Self.provenance, makeID: UUID.init)
      Issue.record("Expected decode failure")
    } catch {
      expectNoDifference(
        error.localizedDescription,
        "The cut-suggester returned output that could not be read.\n\n"
          + "unknown product_type in cut suggestion.")
    }
  }

  @Test func configuredFutureProductTypeIsAllowedByRequestMembership() throws {
    let future = Data(
      """
      {"suggestions": [{"product_type": "future-v2", "label": "x", "song": null,
        "song_verified": false, "word_ids": [1], "start_sample": 0, "end_sample": 1,
        "start_sec": 0, "end_sec": 1, "duration_sec": 1, "rank": 1, "score": 1}]}
      """.utf8)

    let suggestions = try CutSuggestion.decodeSuggestions(
      from: future, provenance: Self.provenance, makeID: UUID.init,
      allowedProductTypeIDs: ["future-v2"])
    expectNoDifference(suggestions.map(\.productType), [ProductType(rawValue: "future-v2")!])
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

  @Test func unreadableOutputErrorNeverEchoesTheOutput() {
    let junk = Data("confidential harbour".utf8)
    do {
      _ = try CutSuggestion.decodeSuggestions(
        from: junk, provenance: Self.provenance, makeID: UUID.init)
      Issue.record("Expected decode failure")
    } catch {
      expectNoDifference(
        error.localizedDescription,
        "The cut-suggester returned output that could not be read.\n\nnot valid JSON (20 bytes of output)"
      )
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

extension CutSuggestionWireTests {
  @Test func v2ResultPreservesIDsEvidenceNamingAndExplicitMissingFields() throws {
    let result = try SuggestionRunWireResult.decode(
      from: suggestionContractFixture("suggestion-result-v2"), snapshot: suggestionResultSnapshot())
    expectNoDifference(result.checkpointRevision, 3)
    let custom = try #require(result.candidates.last)
    expectNoDifference(custom.id, UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    expectNoDifference(custom.title, "Artist reflection")
    expectNoDifference(custom.wordIDs, [201, 202])
    expectNoDifference(custom.naming?.typeName, "Custom Voice")
    expectNoDifference(custom.naming?.discoveryLabel, "Artist reflection")
    expectNoDifference(custom.naming?.extractedValues, ["descriptive-title": "Artist reflection"])
    expectNoDifference(custom.naming?.missingFieldIDs, ["artist-name"])
    expectNoDifference(custom.provenance.model, "fixture-model")
  }

  @Test func checkpointUsesIndependentControlRevisionAndAllowsUnfinishedFields() throws {
    var object = try resultObject()
    object["schema_version"] = 1
    object["revision"] = 7
    object["request_identity"] = "python-owned-identity"
    object["failed_batches"] = [["kind": "input_size", "retryable": false]]
    object["phase"] = "needs_retry"
    object["completed_request_keys"] = ["done"]
    object["failed_request_keys"] = ["retry"]
    var candidates = try #require(object["suggestions"] as? [[String: Any]])
    candidates[1].removeValue(forKey: "fields")
    object["suggestions"] = candidates
    let wire = try JSONDecoder().decode(
      SuggestionRunWireCheckpoint.self, from: JSONSerialization.data(withJSONObject: object))
    expectNoDifference(wire.requestIdentity, "python-owned-identity")
    let snapshot = suggestionResultSnapshot()
    let checkpoint = try wire.checkpoint(
      snapshot: snapshot, proposedStarts: .init(), controlRevision: 99,
      originalBatchFingerprint: "original")
    expectNoDifference(checkpoint.pythonRevision, 7)
    expectNoDifference(
      checkpoint.failures,
      [
        SuggestionRunFailure(
          kind: "input_size", category: .inputSize, message: nil, statusCode: nil,
          requestID: nil, retryAfter: nil, retryable: false, errorType: nil)
      ])
    #expect(checkpoint.failureMessage == nil)
    expectNoDifference(
      try JSONDecoder().decode(
        SuggestionRunCheckpoint.self,
        from: JSONEncoder().encode(checkpoint)), checkpoint)
    expectNoDifference(checkpoint.controlRevision, 99)
    expectNoDifference(checkpoint.phase, .needsRetry)
    expectNoDifference(checkpoint.snapshot.configurationHash, "opaque-swift-hash")
    expectNoDifference(checkpoint.originalBatchFingerprint, "original")
    expectNoDifference(checkpoint.candidates.last?.naming?.missingFieldIDs, [])
    expectNoDifference(
      try wire.checkpoint(
        snapshot: snapshot, proposedStarts: .init(), controlRevision: 100, isPaused: true
      ).phase, .paused)
    object["phase"] = "ready"
    let ready = try JSONDecoder().decode(
      SuggestionRunWireCheckpoint.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: CutSuggestClientError.self) {
      try ready.checkpoint(snapshot: snapshot, proposedStarts: .init(), controlRevision: 99)
    }
  }

  @Test(arguments: [
    "schema", "run", "duplicate", "unknownType", "missingField", "missingEvidence", "missingID",
    "invalidID", "invalidField", "unknownStatus", "zeroRevision",
  ])
  // swiftlint:disable:next cyclomatic_complexity
  func rejectsInvalidV2AsWholeResult(mutation: String) throws {
    var object = try resultObject()
    var candidates = try #require(object["suggestions"] as? [[String: Any]])
    switch mutation {
    case "schema": object["schema_version"] = 9
    case "zeroRevision": object["checkpoint_revision"] = 0
    case "run": object["run_id"] = UUID().uuidString
    case "duplicate": candidates[1]["candidate_id"] = candidates[0]["candidate_id"]
    case "unknownType": candidates[1]["product_type"] = "not-requested"
    case "missingField": candidates[1]["fields"] = ["descriptive-title": "Reflection"]
    case "missingEvidence": candidates[1].removeValue(forKey: "word_ids")
    case "missingID": candidates[1].removeValue(forKey: "candidate_id")
    case "invalidID": candidates[1]["candidate_id"] = "invalid"
    case "invalidField": candidates[1]["fields"] = ["artist-name": 42]
    default: object["status"] = "surprise"
    }
    object["suggestions"] = candidates
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: CutSuggestClientError.self) {
      try SuggestionRunWireResult.decode(from: data, snapshot: suggestionResultSnapshot())
    }
  }

  @Test(arguments: [Data([0xFF, 0xFE]), Data("{broken".utf8)])
  func rejectsMalformedV2(data: Data) {
    #expect(throws: CutSuggestClientError.self) {
      try SuggestionRunWireResult.decode(from: data, snapshot: suggestionResultSnapshot())
    }
  }

  private func resultObject() throws -> [String: Any] {
    try #require(
      JSONSerialization.jsonObject(with: suggestionContractFixture("suggestion-result-v2"))
        as? [String: Any])
  }
}

extension CutSuggestionWireTests {
  @Test func whitespaceFieldsRemainMissingAndInteriorTextIsPreserved() throws {
    var object = try resultObject()
    var candidates = try #require(object["suggestions"] as? [[String: Any]])
    candidates[1]["fields"] = [
      "descriptive-title": "  Artist  reflection ", "artist-name": " \t\n\u{200B}",
    ]
    object["suggestions"] = candidates
    let result = try SuggestionRunWireResult.decode(
      from: JSONSerialization.data(withJSONObject: object), snapshot: suggestionResultSnapshot())
    expectNoDifference(
      result.candidates.last?.naming?.extractedValues, ["descriptive-title": "Artist  reflection"])
    expectNoDifference(result.candidates.last?.naming?.missingFieldIDs, ["artist-name"])
  }
}

extension CutSuggestionWireTests {
  @Test(arguments: ["schema", "run", "revision", "missingIdentity", "emptyIdentity"])
  func checkpointRejectsInvalidEnvelope(mutation: String) throws {
    var object = try resultObject()
    object["schema_version"] = 1
    object["revision"] = 1
    object["phase"] = "ready"
    object["request_identity"] = "python-owned-identity"
    object["completed_request_keys"] = []
    object["failed_request_keys"] = []
    switch mutation {
    case "schema": object["schema_version"] = 2
    case "run": object["run_id"] = UUID().uuidString
    case "revision": object["revision"] = 0
    case "missingIdentity": object.removeValue(forKey: "request_identity")
    default: object["request_identity"] = ""
    }
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) {
      let wire = try JSONDecoder().decode(SuggestionRunWireCheckpoint.self, from: data)
      _ = try wire.checkpoint(
        snapshot: suggestionResultSnapshot(), proposedStarts: .init(), controlRevision: 0)
    }
  }
}

extension CutSuggestionWireTests {
  @Test func scriptedAllTypesFixtureDecodesAndAppliesConfiguredNames() throws {
    let requestData = try suggestionContractFixture("suggestion-integration-request-v2")
    let request = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
    let configuration = try JSONDecoder().decode(
      SuggestionConfiguration.self,
      from: JSONSerialization.data(withJSONObject: try #require(request["configuration"])))
    let runIDString = try #require(request["run_id"] as? String)
    let runID = try #require(UUID(uuidString: runIDString))
    let snapshot = SuggestionRunSnapshot(
      runID: runID, configuration: configuration, configurationHash: "scripted-fixture",
      model: "fixture-model", discoveryPromptVersion: "configured-v2",
      extractionPromptVersion: "fields-v1", productSpecVersion: "configured-v1",
      transcriptHash: try #require(request["transcript_hash"] as? String),
      sourceFingerprint: try #require(request["source_fingerprint"] as? String), sampleRate: 44100)
    let result = try SuggestionRunWireResult.decode(
      from: suggestionContractFixture("suggestion-integration-response-v2"), snapshot: snapshot)
    expectNoDifference(result.status, .ready)
    expectNoDifference(result.checkpointRevision, 20)
    expectNoDifference(result.candidates.count, 10)
    let pending = try preparePendingSuggestions(
      result.candidates, snapshot: snapshot, starts: .init(), issued: [])
    expectNoDifference(pending.candidates.map(\.title), result.candidates.map(\.title))
    expectNoDifference(pending.candidates.compactMap { $0.naming?.reservation }, [])
    var batch = pending.batch
    var issued: [SequenceReservation] = []
    var accepted: [CutSuggestion] = []
    for candidate in pending.candidates {
      let finalized = try suggestionForAcceptance(
        candidate, batch: batch, starts: .init(), issued: issued)
      accepted.append(finalized.candidate)
      batch = finalized.batch
      if let reservation = finalized.candidate.naming?.reservation { issued.append(reservation) }
    }
    let numbered = (candidates: accepted, batch: batch)
    expectNoDifference(
      numbered.candidates.map(\.title),
      [
        "Paper Lanterns 1, River Vale", "ID 1", "ID 2", "Promo 1", "ID 3", "Post-Com 1",
        "Harbor Lights 1, Nova Reed", "Pre-Com 1", "Neighbors build a shared studio", "Spotlight 1",
      ])
    expectNoDifference(numbered.candidates.map(\.id), result.candidates.map(\.id))
    expectNoDifference(numbered.candidates.map(\.wordIDs), result.candidates.map(\.wordIDs))
    expectNoDifference(
      numbered.candidates.map { $0.naming?.extractedValues },
      result.candidates.map { $0.naming?.extractedValues })
    expectNoDifference(numbered.batch.snapshot, snapshot)
  }
}

extension CutSuggestionWireTests {
  @Test(arguments: [
    ("auth", SuggestionFailureCategory.auth), ("credits", .credits),
    ("rate_limit", .rateLimit), ("overloaded", .overloaded), ("network", .network),
    ("timeout", .timeout), ("server", .server), ("bad_request", .badRequest),
    ("bad_response", .badResponse), ("input_size", .inputSize),
  ])
  func failureCategoryDecodesFromItsWireName(name: String, expected: SuggestionFailureCategory)
    throws
  {
    let failure = try decodeFailure(["kind": "extraction", "retryable": true, "category": name])
    expectNoDifference(failure.category, expected)
    expectNoDifference(
      try JSONDecoder().decode(
        [SuggestionFailureCategory].self, from: JSONEncoder().encode([expected])),
      [expected])
  }

  @Test func unknownFutureCategoryDecodesWithoutThrowingAndRoundTripsItsName() throws {
    let failure = try decodeFailure([
      "kind": "extraction", "retryable": false, "category": "quota_exhausted",
    ])
    expectNoDifference(failure.category, .unknown("quota_exhausted"))
    let encoded = try JSONEncoder().encode([failure.category])
    expectNoDifference(String(data: encoded, encoding: .utf8), "[\"quota_exhausted\"]")
  }

  @Test func failureWithoutCategoryFallsBackToInputSizeOrErrorTypeOrKind() throws {
    expectNoDifference(
      try decodeFailure(["kind": "input_size", "retryable": false]).category, .inputSize)
    expectNoDifference(
      try decodeFailure([
        "kind": "extraction", "retryable": true, "error_type": "ExtractionError",
      ]).category,
      .unknown("ExtractionError"))
    expectNoDifference(
      try decodeFailure(["kind": "provider", "retryable": true]).category, .unknown("provider"))
  }

  @Test(arguments: [("30", 30.0), ("12.5", 12.5)])
  func retryAfterDecodesFromIntegerAndFloat(wire: String, expected: Double) throws {
    let json = Data(
      """
      {"kind":"extraction","retryable":true,"category":"rate_limit","retry_after":\(wire)}
      """.utf8)
    let failure = try JSONDecoder().decode(SuggestionRunWireFailure.self, from: json).failure
    expectNoDifference(failure.retryAfter, expected)
  }

  @Test func failureCarriesEveryPersistedFactAndIgnoresUnknownKeys() throws {
    let failure = try decodeFailure([
      "kind": "discovery", "stage": "classify:110:239", "request_key": "digest",
      "category": "credits", "message": "Your credit balance is too low.", "status_code": 400,
      "request_id": "req_01ABC", "retry_after": NSNull(), "retryable": false,
      "error_type": "BadRequestError", "mandatory_characters": 5, "future_key": "ignored",
    ])
    expectNoDifference(
      failure,
      SuggestionRunFailure(
        kind: "discovery", category: .credits,
        message: "Your credit balance is too low.", statusCode: 400, requestID: "req_01ABC",
        retryAfter: nil, retryable: false, errorType: "BadRequestError"))
  }

  @Test func needsRetryResultCarriesStructuredFailuresInOrder() throws {
    var object = try resultObject()
    object["status"] = "needs_retry"
    object["failed_batches"] = [
      ["kind": "extraction", "request_key": "a", "category": "network", "retryable": true],
      ["kind": "discovery", "category": "auth", "retryable": false],
    ]
    let result = try SuggestionRunWireResult.decode(
      from: JSONSerialization.data(withJSONObject: object), snapshot: suggestionResultSnapshot())
    expectNoDifference(result.failures.map(\.category), [.network, .auth])
    expectNoDifference(result.failedRequestKeys, ["a"])
  }

  @Test func checkpointFailuresRoundTripAndLegacyMessageStaysNil() throws {
    var object = try resultObject()
    object["schema_version"] = 1
    object["revision"] = 2
    object["request_identity"] = "python-owned-identity"
    object["phase"] = "needs_retry"
    object["completed_request_keys"] = []
    object["failed_request_keys"] = []
    object["failed_batches"] = [
      [
        "kind": "extraction", "request_key": "k", "category": "rate_limit",
        "message": "Slow down", "status_code": 429, "request_id": "req_1", "retry_after": 30,
        "retryable": true, "error_type": "RateLimitError",
      ]
    ]
    let wire = try JSONDecoder().decode(
      SuggestionRunWireCheckpoint.self, from: JSONSerialization.data(withJSONObject: object))
    let checkpoint = try wire.checkpoint(
      snapshot: suggestionResultSnapshot(), proposedStarts: .init(), controlRevision: 0)
    expectNoDifference(
      checkpoint.failures,
      [
        SuggestionRunFailure(
          kind: "extraction", category: .rateLimit, message: "Slow down",
          statusCode: 429, requestID: "req_1", retryAfter: 30, retryable: true,
          errorType: "RateLimitError")
      ])
    #expect(checkpoint.failureMessage == nil)
    expectNoDifference(
      try JSONDecoder().decode(
        SuggestionRunCheckpoint.self, from: JSONEncoder().encode(checkpoint)), checkpoint)
  }

  private func decodeFailure(_ object: [String: Any]) throws -> SuggestionRunFailure {
    try JSONDecoder().decode(
      SuggestionRunWireFailure.self, from: JSONSerialization.data(withJSONObject: object)
    ).failure
  }
}
