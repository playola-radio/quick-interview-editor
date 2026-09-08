import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct SuggestionRunTests {
  @Test func acceptanceUsesCurrentFloorAndPermanentOccupancyInsteadOfPendingReservations() throws {
    let snapshot = introSnapshot()
    var original = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let key = suggestionSequenceKey(
      type: snapshot.configuration.types[0],
      values: original.naming!.extractedValues, candidateID: original.id)
    original.naming?.reservation = .init(
      candidateID: original.id, key: key, number: 99, canonicalValues: [:])
    let batch = SuggestionBatch(snapshot: snapshot, actualStarts: .init(), canonicalGroups: [])
    let issued = SequenceReservation(
      candidateID: Fixtures.uuid(9), key: key, number: 4,
      canonicalValues: ["song-title": "SONG", "artist-name": "Artist"])
    let starts = SuggestionStarts(groups: [
      .init(key: key, start: .init(number: 7, isExplicit: true))
    ])
    let next = try suggestionForAcceptance(original, batch: batch, starts: starts, issued: [issued])
    expectNoDifference(next.candidate.title, "SONG 7, Artist")
    expectNoDifference(next.candidate.naming?.reservation?.number, 7)
    expectNoDifference(original.naming?.reservation?.number, 99)
    let assigned = try #require(next.candidate.naming?.reservation)
    var afterUndo = original
    afterUndo.naming?.reservation = nil
    let restored = try suggestionForAcceptance(
      afterUndo, batch: next.batch,
      starts: .init(types: ["intro": .init(number: 30, isExplicit: true)]),
      issued: [issued, assigned])
    expectNoDifference(restored.candidate.naming?.reservation?.identity, assigned.identity)
    expectNoDifference(restored.candidate.title, next.candidate.title)
  }

  @Test func acceptanceOrderUsesIndependentSongPerformersAndCanonicalFirstAcceptedSpelling() throws
  {
    let snapshot = introSnapshot()
    let batch = SuggestionBatch(snapshot: snapshot, actualStarts: .init(), canonicalGroups: [])
    let late = candidate(
      id: Fixtures.uuid(2), startSample: 200,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let early = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "song", "artist-name": "ARTIST"])
    let other = candidate(
      id: Fixtures.uuid(3), startSample: 300,
      values: ["song-title": "Song", "artist-name": "Other"])
    let starts = SuggestionStarts(types: ["intro": .init(number: 7, isExplicit: true)])
    let first = try suggestionForAcceptance(late, batch: batch, starts: starts, issued: [])
    let ledger = [try #require(first.candidate.naming?.reservation)]
    let second = try suggestionForAcceptance(
      early, batch: first.batch, starts: starts, issued: ledger)
    let separate = try suggestionForAcceptance(
      other, batch: second.batch, starts: starts, issued: ledger)
    expectNoDifference(
      [first.candidate.title, second.candidate.title, separate.candidate.title],
      ["Song 7, Artist", "Song 8, Artist", "Song 7, Other"])
    expectNoDifference(first.batch.actualStarts.groups.first?.start.number, 7)
    expectNoDifference(second.batch.actualStarts.groups.first?.start.number, 7)
  }

  @Test func acceptanceRendersSequenceFreeCapturedTemplateWithoutIssuingNumber() throws {
    var snapshot = introSnapshot()
    snapshot.configuration.types[0].template = [
      .init(kind: .field, value: "artist-name"), .init(kind: .literal, value: " — "),
      .init(kind: .field, value: "song-title"),
    ]
    let original = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let prepared = try preparePendingSuggestions(
      [original], snapshot: snapshot, starts: .init(), issued: [])
    expectNoDifference(prepared.candidates[0].title, original.naming?.discoveryLabel)
    let result = try suggestionForAcceptance(
      prepared.candidates[0], batch: prepared.batch,
      starts: .init(), issued: [])
    expectNoDifference(result.candidate.title, "Artist — Song")
    expectNoDifference(result.candidate.naming?.reservation, nil)
    expectNoDifference(result.batch.snapshot, snapshot)
  }

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

  @Test func correctionRejectsSameKeyReservationOwnedByAnotherCandidate() throws {
    let snapshot = introSnapshot()
    var candidate = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let key = suggestionSequenceKey(
      type: SuggestionDefaults.types[0],
      values: ["song-title": "Song", "artist-name": "Artist"], candidateID: candidate.id)
    candidate.naming?.reservation = .init(
      candidateID: candidate.id, key: key, number: 4, canonicalValues: [:])
    let otherOwner = SequenceReservation(
      candidateID: Fixtures.uuid(2), key: key, number: 4, canonicalValues: [:])
    let expected = SuggestionBatchNumberingError.conflictingReservation(
      candidate.naming!.reservation!.identity)

    for (issued, retained) in [([otherOwner], []), ([], [otherOwner])] {
      #expect(throws: expected) {
        try numberSuggestions(
          [candidate], snapshot: snapshot, starts: .init(), issued: issued, retained: retained,
          mode: .correction(candidateID: candidate.id))
      }
    }
    expectNoDifference(candidate.naming?.reservation?.number, 4)
  }

  @Test func allocatorRejectsDecodedConfigurationWithDuplicateSequenceFields() throws {
    var corrupted = introSnapshot()
    corrupted.configuration.types[0].sequenceFieldIDs = ["song-title", "song-title"]
    let decoded: SuggestionRunSnapshot = try decode(encode(corrupted))
    let candidate = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])

    #expect(
      throws: SuggestionBatchNumberingError.invalidConfiguration(
        decoded.configuration.validationMessages()
      )
    ) {
      try numberSuggestions(
        [candidate], snapshot: decoded, starts: .init(), issued: [], retained: [])
    }
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

  @Test func provisionalCanonicalGroupsHaveStableOrderWhenInputIsReordered() throws {
    let snapshot = introSnapshot()
    let first = candidate(
      id: Fixtures.uuid(1), startSample: 100, values: ["artist-name": "Artist"])
    let second = candidate(
      id: Fixtures.uuid(2), startSample: 100, values: ["artist-name": "Artist"])

    let forward = try numberSuggestions(
      [first, second], snapshot: snapshot, starts: .init(), issued: [], retained: [])
    let reverse = try numberSuggestions(
      [second, first], snapshot: snapshot, starts: .init(), issued: [], retained: [])

    expectNoDifference(forward.batch.canonicalGroups, reverse.batch.canonicalGroups)
    expectNoDifference(
      forward.batch.canonicalGroups.map { $0.key.provisionalCandidateID }, [first.id, second.id])
  }

  @Test(arguments: [false, true], [false, true])
  func pendingApplicationAllowsUnissuedSequenceButRejectsReservationWithoutSequence(
    hasSequence: Bool, hasReservation: Bool
  ) throws {
    let snapshot = introSnapshot()
    let original = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let numbered = try numberSuggestions(
      [original], snapshot: snapshot, starts: .init(), issued: [], retained: [])
    var candidate = numbered.candidates[0]
    var batch = numbered.batch
    if !hasReservation { candidate.naming?.reservation = nil }
    if !hasSequence {
      batch.snapshot.configuration.types[0].template = [.init(kind: .literal, value: "Song")]
    }
    if hasSequence || !hasReservation {
      try validateSuggestionRunApplication(candidates: [candidate], batch: batch)
    } else {
      #expect(throws: SuggestionRunValidationError.invalidNaming(candidateID: candidate.id)) {
        try validateSuggestionRunApplication(candidates: [candidate], batch: batch)
      }
    }
  }

  @Test func applicationStillAcceptsLegacyCandidateWithoutNamingOrBatch() throws {
    try validateSuggestionRunApplication(
      candidates: [Fixtures.cutSuggestion(id: Fixtures.uuid(1))], batch: nil)
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

  @Test func correctionUsesOwningBatchSnapshotAfterGlobalTemplateChanges() throws {
    let oldSnapshot = introSnapshot()
    let original = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let batch = try numberSuggestions(
      [original], snapshot: oldSnapshot, starts: .init(), issued: [], retained: [])
    var laterGlobalConfiguration = SuggestionDefaults.configuration
    laterGlobalConfiguration.types[0].template = [.init(kind: .literal, value: "New template ")]
    let newerSnapshot = SuggestionRunSnapshot(
      runID: Fixtures.uuid(99), configuration: laterGlobalConfiguration,
      configurationHash: "new-rules", model: "model", discoveryPromptVersion: "discovery-v2",
      extractionPromptVersion: "extraction-v2", productSpecVersion: "spec-v1",
      transcriptHash: "transcript", sourceFingerprint: "source", sampleRate: 48_000)
    var correction = batch.candidates[0]
    correction.naming?.correctedValues["artist-name"] = "Corrected"

    let result = try numberSuggestions(
      [correction], snapshot: newerSnapshot,
      starts: .init(types: ["intro": .init(number: 99, isExplicit: true)]), issued: [],
      retained: [],
      mode: .correction(candidateID: correction.id), existingBatch: batch.batch)

    expectNoDifference(result.candidates[0].title, "Song 1, Corrected")
    expectNoDifference(result.batch.snapshot, oldSnapshot)
    expectNoDifference(result.batch.actualStarts, batch.batch.actualStarts)
  }

  @Test func independentImageTypesReceiveIndependentCounters() throws {
    let imageA = type(
      "image-a", template: [.init(kind: .literal, value: "A "), .init(kind: .sequence)])
    let imageB = type(
      "image-b", template: [.init(kind: .literal, value: "B "), .init(kind: .sequence)])
    let snapshot = makingSnapshot(with: [imageA, imageB])
    let result = try numberSuggestions(
      [
        imageCandidate(id: Fixtures.uuid(1), type: imageA),
        imageCandidate(id: Fixtures.uuid(2), type: imageB),
      ],
      snapshot: snapshot, starts: .init(), issued: [], retained: [])

    expectNoDifference(result.candidates.map(\.title), ["A 1", "B 1"])
    expectNoDifference(result.candidates.map { $0.naming?.reservation?.number }, [1, 1])
  }

  @Test func pendingRenumberKeepsRejectedAndUnselectedGapsAndLeavesNonPendingSelectionUntouched()
    throws
  {
    let snapshot = introSnapshot()
    var selected = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])
    var unselected = candidate(
      id: Fixtures.uuid(2), startSample: 200,
      values: ["song-title": "Song", "artist-name": "Artist"])
    var accepted = candidate(
      id: Fixtures.uuid(3), startSample: 300,
      values: ["song-title": "Song", "artist-name": "Artist"])
    var rejected = candidate(
      id: Fixtures.uuid(4), startSample: 400,
      values: ["song-title": "Song", "artist-name": "Artist"])
    accepted.status = .accepted
    rejected.status = .rejected
    let key = suggestionSequenceKey(
      type: SuggestionDefaults.types[0], values: ["song-title": "Song", "artist-name": "Artist"],
      candidateID: selected.id)
    selected.naming?.reservation = .init(
      candidateID: selected.id, key: key, number: 1, canonicalValues: [:])
    unselected.naming?.reservation = .init(
      candidateID: unselected.id, key: key, number: 2, canonicalValues: [:])
    accepted.naming?.reservation = .init(
      candidateID: accepted.id, key: key, number: 3, canonicalValues: [:])
    rejected.naming?.reservation = .init(
      candidateID: rejected.id, key: key, number: 4, canonicalValues: [:])
    let beforeAccepted = accepted
    let beforeRejected = rejected
    let result = try numberSuggestions(
      [selected, unselected, accepted, rejected], snapshot: snapshot,
      starts: .init(groups: [.init(key: key, start: .init(number: 2, isExplicit: true))]),
      issued: [],
      retained: [
        selected.naming!.reservation!, unselected.naming!.reservation!,
        accepted.naming!.reservation!, rejected.naming!.reservation!,
      ],
      mode: .pendingRenumber(selectedCandidateIDs: [selected.id, accepted.id, rejected.id]))

    expectNoDifference(result.candidates[0].naming?.reservation?.number, 5)
    expectNoDifference(result.candidates[1], unselected)
    expectNoDifference(result.candidates[2], beforeAccepted)
    expectNoDifference(result.candidates[3], beforeRejected)
  }

  @Test func sameOwnerIssuedReservationRetainsIdentityAcrossCanonicalSpellingChange() throws {
    let snapshot = introSnapshot()
    var candidate = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "song", "artist-name": "artist"])
    let key = suggestionSequenceKey(
      type: SuggestionDefaults.types[0], values: ["song-title": "song", "artist-name": "artist"],
      candidateID: candidate.id)
    candidate.naming?.reservation = .init(
      candidateID: candidate.id, key: key, number: 4,
      canonicalValues: ["song-title": "Old Song", "artist-name": "Old Artist"])
    let issued = SequenceReservation(
      candidateID: candidate.id, key: key, number: 4,
      canonicalValues: ["song-title": "Issued Song", "artist-name": "Issued Artist"])
    let result = try numberSuggestions(
      [candidate], snapshot: snapshot, starts: .init(), issued: [issued], retained: [])

    expectNoDifference(result.candidates[0].naming?.reservation?.identity, issued.identity)
    expectNoDifference(result.candidates[0].title, "Issued Song 4, Issued Artist")
  }

  @Test func foreignReservationOwnerIsRejectedBeforeNumbering() throws {
    let snapshot = introSnapshot()
    var candidate = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let key = suggestionSequenceKey(
      type: SuggestionDefaults.types[0],
      values: ["song-title": "Song", "artist-name": "Artist"], candidateID: candidate.id)
    candidate.naming?.reservation = .init(
      candidateID: Fixtures.uuid(2), key: key, number: 4, canonicalValues: [:])

    #expect(throws: SuggestionBatchNumberingError.invalidNaming(candidateID: candidate.id)) {
      try numberSuggestions(
        [candidate], snapshot: snapshot, starts: .init(), issued: [], retained: [])
    }
  }

  @Test func changedGroupCorrectionAllocatesAfterDestinationOccupancy() throws {
    let snapshot = introSnapshot()
    var candidate = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Old", "artist-name": "Artist"])
    let destinationValues = ["song-title": "New", "artist-name": "Artist"]
    let destinationKey = suggestionSequenceKey(
      type: SuggestionDefaults.types[0], values: destinationValues, candidateID: candidate.id)
    candidate.naming?.correctedValues = destinationValues
    let issued = SequenceReservation(
      candidateID: Fixtures.uuid(8), key: destinationKey, number: 5, canonicalValues: [:])
    let retained = SequenceReservation(
      candidateID: Fixtures.uuid(9), key: destinationKey, number: 6, canonicalValues: [:])
    let result = try numberSuggestions(
      [candidate], snapshot: snapshot, starts: .init(), issued: [issued], retained: [retained],
      mode: .correction(candidateID: candidate.id))
    expectNoDifference(result.candidates[0].naming?.reservation?.number, 7)
  }

  @Test func namingRoundTripKeepsMissingFieldsDistinctFromEmptyValues() throws {
    let naming = SuggestionNamingRecord(
      runID: Fixtures.uuid(10), typeID: "intro", typeName: "Song Intro", typeGroup: .songIntros,
      discoveryLabel: "label", extractedValues: ["song-title": ""],
      missingFieldIDs: ["artist-name"],
      correctedValues: [:], reservation: nil)
    let decoded: SuggestionNamingRecord = try decode(encode(naming))
    expectNoDifference(decoded.extractedValues, ["song-title": ""])
    expectNoDifference(decoded.missingFieldIDs, ["artist-name"])
  }

  @Test func batchOverflowThrowsWithoutChangingInput() throws {
    let snapshot = introSnapshot()
    let first = candidate(
      id: Fixtures.uuid(1), startSample: 100,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let second = candidate(
      id: Fixtures.uuid(2), startSample: 200,
      values: ["song-title": "Song", "artist-name": "Artist"])
    let original = [first, second]
    let key = suggestionSequenceKey(
      type: SuggestionDefaults.types[0], values: ["song-title": "Song", "artist-name": "Artist"],
      candidateID: first.id)
    #expect(throws: SuggestionNumberingError.exhausted) {
      try numberSuggestions(
        original, snapshot: snapshot,
        starts: .init(groups: [.init(key: key, start: .init(number: .max, isExplicit: true))]),
        issued: [], retained: [])
    }
    expectNoDifference(original, [first, second])
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

  private func imageCandidate(id: UUID, type: SuggestionTypeDefinition) -> CutSuggestion {
    var candidate = Fixtures.cutSuggestion(
      id: id, productType: ProductType(rawValue: type.id)!, title: "Original label",
      startSample: id == Fixtures.uuid(1) ? 100 : 200, endSample: id == Fixtures.uuid(1) ? 110 : 210
    )
    candidate.naming = SuggestionNamingRecord(
      runID: Fixtures.uuid(10), typeID: type.id, typeName: type.name, typeGroup: type.group,
      discoveryLabel: "Original label", extractedValues: [:], missingFieldIDs: [],
      correctedValues: [:], reservation: nil)
    return candidate
  }
}
