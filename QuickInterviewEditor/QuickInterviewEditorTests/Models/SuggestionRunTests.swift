import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct SuggestionRunTests {
  @Test func freshNumberingUsesSnapshotTemplateAndSourceOrder() throws {
    let snapshot = introSnapshot()
    let late = candidate(
      id: Fixtures.uuid(2), startSample: 200,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let early = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])

    let result = try numberSuggestions(
      [late, early], snapshot: snapshot, starts: .init(), issued: [], retained: [])

    expectNoDifference(result.candidates.map(\.title), ["Song 2, Artist", "Song 1, Artist"])
    expectNoDifference(result.candidates.map { $0.naming?.reservation?.number }, [2, 1])
  }

  @Test func numberingCanonicalizesGroupDisplayAndKeepsDifferentPerformersSeparate() throws {
    let snapshot = introSnapshot()
    let first = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let caseVariant = candidate(
      id: Fixtures.uuid(2), startSample: 200,
      values: ["song-title": "song", "artist-name": "ARTIST"])
    let otherPerformer = candidate(
      id: Fixtures.uuid(3), startSample: 300,
      values: ["song-title": "Song", "artist-name": "Other"])

    let result = try numberSuggestions(
      [first, caseVariant, otherPerformer], snapshot: snapshot, starts: .init(), issued: [],
      retained: [])

    expectNoDifference(
      result.candidates.map(\.title), ["Song 1, Artist", "Song 2, Artist", "Song 1, Other"])
    expectNoDifference(result.batch.canonicalGroups.count, 2)
  }

  @Test func freshExplicitStartCannotReuseIssuedNumberButPendingRenumberSkipsIt() throws {
    let snapshot = introSnapshot()
    let candidate = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let key = suggestionSequenceKey(
      type: SuggestionDefaults.types[0],
      values: ["song-title": "Song", "artist-name": "Artist"], candidateID: candidate.id)
    let issued = [
      SequenceReservation(candidateID: Fixtures.uuid(8), key: key, number: 4, canonicalValues: [:])
    ]
    let starts = SuggestionStarts(groups: [
      .init(key: key, start: .init(number: 4, isExplicit: true))
    ])

    #expect(throws: SuggestionNumberingError.minimumSafeStart(5)) {
      try numberSuggestions(
        [candidate], snapshot: snapshot, starts: starts, issued: issued, retained: [])
    }
    let pending = try numberSuggestions(
      [candidate], snapshot: snapshot, starts: starts, issued: issued, retained: [],
      mode: .pendingRenumber(selectedCandidateIDs: [candidate.id]))
    expectNoDifference(pending.candidates[0].naming?.reservation?.number, 5)

    var prior = candidate
    prior.naming?.reservation = .init(
      candidateID: prior.id, key: key, number: 9, canonicalValues: [:])
    let renumbered = try numberSuggestions(
      [prior], snapshot: snapshot,
      starts: .init(groups: [.init(key: key, start: .init(number: 1, isExplicit: true))]),
      issued: [], retained: [prior.naming!.reservation!],
      mode: .pendingRenumber(selectedCandidateIDs: [prior.id]))
    expectNoDifference(renumbered.candidates[0].naming?.reservation?.number, 1)
  }

  @Test func automaticStartsRecordResolvedIssuedContinuation() throws {
    let snapshot = introSnapshot()
    let candidate = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let key = suggestionSequenceKey(
      type: SuggestionDefaults.types[0],
      values: ["song-title": "Song", "artist-name": "Artist"], candidateID: candidate.id)
    let result = try numberSuggestions(
      [candidate], snapshot: snapshot, starts: .init(),
      issued: [.init(candidateID: Fixtures.uuid(8), key: key, number: 7, canonicalValues: [:])],
      retained: [])
    expectNoDifference(result.candidates[0].naming?.reservation?.number, 8)
    expectNoDifference(
      result.batch.actualStarts.groups,
      [.init(key: key, start: .init(number: 8, isExplicit: false))])
  }

  @Test func issuedReservationSuppliesCanonicalGroupSpelling() throws {
    let snapshot = introSnapshot()
    let candidate = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "song", "artist-name": "artist"])
    let key = suggestionSequenceKey(
      type: SuggestionDefaults.types[0],
      values: ["song-title": "song", "artist-name": "artist"], candidateID: candidate.id)
    let result = try numberSuggestions(
      [candidate], snapshot: snapshot, starts: .init(),
      issued: [
        .init(
          candidateID: Fixtures.uuid(8), key: key, number: 1,
          canonicalValues: ["song-title": "Issued Song", "artist-name": "Issued Artist"])
      ],
      retained: [])
    expectNoDifference(result.candidates[0].title, "Issued Song 2, Issued Artist")
    expectNoDifference(result.batch.canonicalGroups[0].values["song-title"], "Issued Song")
  }

  @Test func correctionKeepsSameKeyReservationAndNoSequenceDoesNotAllocate() throws {
    let snapshot = introSnapshot()
    var candidate = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let key = suggestionSequenceKey(
      type: SuggestionDefaults.types[0],
      values: ["song-title": "Song", "artist-name": "Artist"], candidateID: candidate.id)
    candidate.naming?.reservation = .init(
      candidateID: candidate.id, key: key, number: 9, canonicalValues: [:])
    let corrected = try numberSuggestions(
      [candidate], snapshot: snapshot, starts: .init(), issued: [],
      retained: [candidate.naming!.reservation!],
      mode: .correction(candidateID: candidate.id))
    expectNoDifference(corrected.candidates[0].naming?.reservation?.number, 9)

    let spotlight = Fixtures.cutSuggestion(
      id: Fixtures.uuid(2), productType: .spotlight, title: "A story")
    let noSequenceSnapshot = makingSnapshot(
      with: [type("spotlight", template: [.init(kind: .literal, value: "Story")])])
    let noSequence = try numberSuggestions(
      [spotlight], snapshot: noSequenceSnapshot,
      starts: .init(types: ["spotlight": .init(number: Int.max, isExplicit: true)]),
      issued: [], retained: [])
    expectNoDifference(noSequence.candidates[0].title, "Story")
    expectNoDifference(noSequence.candidates[0].naming?.reservation, nil)
  }

  @Test func missingTemplateValueFallsBackAndEmptyBatchDoesNotOverflow() throws {
    let snapshot = introSnapshot()
    let missing = candidate(id: Fixtures.uuid(1), startSample: 100, values: ["song-title": "Song"])
    let fallback = try numberSuggestions(
      [missing], snapshot: snapshot, starts: .init(), issued: [], retained: [])
    expectNoDifference(fallback.candidates[0].title, "Original label")

    let key = SuggestionSequenceKey(typeID: "intro", fields: [], provisionalCandidateID: nil)
    let empty = try numberSuggestions(
      [], snapshot: snapshot, starts: .init(),
      issued: [.init(candidateID: Fixtures.uuid(9), key: key, number: .max, canonicalValues: [:])],
      retained: [])
    expectNoDifference(empty.candidates, [])
  }

  @Test func oldBatchSnapshotRemainsCanonicalForCorrectionAndRunValidation() throws {
    let snapshot = introSnapshot()
    var candidate = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let numbered = try numberSuggestions(
      [candidate], snapshot: snapshot, starts: .init(), issued: [], retained: [])
    candidate = numbered.candidates[0]
    candidate.naming?.correctedValues["artist-name"] = "Corrected"
    let corrected = try numberSuggestions(
      [candidate], snapshot: snapshot, starts: .init(), issued: [], retained: [],
      mode: .correction(candidateID: candidate.id), existingBatch: numbered.batch)
    expectNoDifference(corrected.candidates[0].title, "Song 1, Corrected")
    try validateSuggestionRunApplication(candidates: corrected.candidates, batch: corrected.batch)

    #expect(throws: SuggestionRunValidationError.missingOwningSnapshot(snapshot.runID)) {
      try validateSuggestionRunApplication(candidates: corrected.candidates, batch: nil)
    }
    var malformed = corrected.candidates[0]
    malformed.naming?.typeName = "Wrong"
    #expect(throws: SuggestionRunValidationError.invalidNaming(candidateID: malformed.id)) {
      try validateSuggestionRunApplication(candidates: [malformed], batch: corrected.batch)
    }
  }

  @Test func malformedPresentNamingMetadataDoesNotDecodeAsLegacy() throws {
    var object = try #require(
      JSONSerialization.jsonObject(
        with: encode(
          candidate(
            id: Fixtures.uuid(1), startSample: 100,
            values: ["song-title": "Song", "artist-name": "Artist"]))) as? [String: Any])
    object["naming"] = ["runID": Fixtures.uuid(10).uuidString]
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(CutSuggestion.self, from: data)
    }
  }

  @Test func runRecordsRoundTripIndependentRevisionsAndHistoricalLabels() throws {
    let snapshot = SuggestionRunSnapshot(
      runID: Fixtures.uuid(10), configuration: SuggestionDefaults.configuration,
      configurationHash: "rules-v1", model: "model", discoveryPromptVersion: "discovery-v1",
      extractionPromptVersion: "extraction-v1", productSpecVersion: "spec-v1",
      transcriptHash: "transcript", sourceFingerprint: "source", sampleRate: 48_000)
    let naming = SuggestionNamingRecord(
      runID: snapshot.runID, typeID: "retired-custom", typeName: "Historical Name",
      typeGroup: .audioImages, discoveryLabel: "Discovery label",
      extractedValues: ["artist": "Artist"], missingFieldIDs: ["title"],
      correctedValues: ["artist": "Corrected"], reservation: nil)
    let checkpoint = SuggestionRunCheckpoint(
      pythonRevision: 7, controlRevision: 3, originalBatchFingerprint: "original",
      snapshot: snapshot, phase: .needsNumbering,
      candidates: [Fixtures.cutSuggestion(id: Fixtures.uuid(1))],
      completedRequestKeys: ["discover"], failedRequestKeys: ["extract"],
      proposedStarts: SuggestionStarts(types: ["retired-custom": .init(number: 4, isExplicit: true)]
      ))
    let batch = SuggestionBatch(
      snapshot: snapshot, actualStarts: checkpoint.proposedStarts,
      canonicalGroups: [
        .init(
          key: SuggestionSequenceKey(
            typeID: naming.typeID, fields: [], provisionalCandidateID: nil),
          values: ["artist": "Artist"])
      ])

    expectNoDifference(try decode(encode(naming)), naming)
    expectNoDifference(try decode(encode(batch)), batch)
    expectNoDifference(try decode(encode(checkpoint)), checkpoint)
    expectNoDifference(checkpoint.pythonRevision, 7)
    expectNoDifference(checkpoint.controlRevision, 3)
  }

  private func encode<Value: Encodable>(_ value: Value) throws -> Data {
    try JSONEncoder().encode(value)
  }

  private func decode<Value: Decodable>(_ data: Data) throws -> Value {
    try JSONDecoder().decode(Value.self, from: data)
  }

  private func introSnapshot() -> SuggestionRunSnapshot {
    SuggestionRunSnapshot(
      runID: Fixtures.uuid(10), configuration: SuggestionDefaults.configuration,
      configurationHash: "rules-v1", model: "model", discoveryPromptVersion: "discovery-v1",
      extractionPromptVersion: "extraction-v1", productSpecVersion: "spec-v1",
      transcriptHash: "transcript", sourceFingerprint: "source", sampleRate: 48_000)
  }

  private func makingSnapshot(with types: [SuggestionTypeDefinition]) -> SuggestionRunSnapshot {
    SuggestionRunSnapshot(
      runID: Fixtures.uuid(10),
      configuration: .init(types: types, fields: SuggestionDefaults.fields),
      configurationHash: "rules-v1", model: "model", discoveryPromptVersion: "discovery-v1",
      extractionPromptVersion: "extraction-v1", productSpecVersion: "spec-v1",
      transcriptHash: "transcript", sourceFingerprint: "source", sampleRate: 48_000)
  }

  private func type(_ id: String, template: [NamingComponent]) -> SuggestionTypeDefinition {
    .init(
      id: id, name: id, group: .spotlights, guidelines: "guidelines", template: template,
      sequenceFieldIDs: [])
  }

  private func candidate(
    id: UUID, startSample: Int, values: [String: String]
  ) -> CutSuggestion {
    var candidate = Fixtures.cutSuggestion(
      id: id, productType: .intro, title: "Original label", startSample: startSample,
      endSample: startSample + 10)
    candidate.naming = SuggestionNamingRecord(
      runID: Fixtures.uuid(10), typeID: "intro", typeName: "Song Intro", typeGroup: .songIntros,
      discoveryLabel: "Original label", extractedValues: values, missingFieldIDs: [],
      correctedValues: [:], reservation: nil)
    return candidate
  }
}
