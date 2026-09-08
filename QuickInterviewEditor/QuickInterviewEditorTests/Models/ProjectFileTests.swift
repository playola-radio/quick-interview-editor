import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct ProjectFileTests {
  @Test func interviewArtistPersistsAndOldDocumentsDefaultToAbsent() throws {
    var file = Fixtures.projectFile()
    file.content.interviewArtist = "Björk"
    let data = try ProjectPackage.projectEncoder().encode(file)
    expectNoDifference(
      try ProjectPackage.projectDecoder().decode(ProjectFile.self, from: data), file)
    let old = Data(#"{"slices":[],"timelineRemovals":[]}"#.utf8)
    expectNoDifference(
      try JSONDecoder().decode(EditorDocumentState.self, from: old).interviewArtist, nil)
    expectNoDifference(file.content.rekeyed(to: Fixtures.editPlan()).interviewArtist, "Björk")
  }

  @Test func projectFileRoundTrips() throws {
    let file = Fixtures.projectFile()
    let data = try JSONEncoder().encode(file)
    expectNoDifference(try JSONDecoder().decode(ProjectFile.self, from: data), file)
  }

  @Test func v2RoundTripsUnicodeCustomFieldsAndHistoricalSnapshotLabels() throws {
    let type = SuggestionTypeDefinition(
      id: "deleted-custom-type", name: "Émission", group: .audioImages,
      guidelines: "A historical rule",
      template: [.init(kind: .field, value: "custom-field"), .init(kind: .sequence, value: nil)],
      sequenceFieldIDs: ["custom-field"])
    let configuration = SuggestionConfiguration(
      types: [type],
      fields: [
        SuggestionField(
          id: "custom-field", name: "Titre", instructions: "The original custom field")
      ])
    let snapshot = SuggestionRunSnapshot(
      runID: Fixtures.uuid(12), configuration: configuration,
      configurationHash: "historical-config",
      model: "saved-model", discoveryPromptVersion: "discovery",
      extractionPromptVersion: "extraction",
      productSpecVersion: "products", transcriptHash: "transcript", sourceFingerprint: "source",
      sampleRate: 44100, stage1Window: 200, stage1Step: 160)
    let key = suggestionSequenceKey(
      type: type, values: ["custom-field": "Café 東京"], candidateID: Fixtures.uuid(1))
    let reservation = SequenceReservation(
      candidateID: Fixtures.uuid(1), key: key, number: 7,
      canonicalValues: ["custom-field": "Café 東京"])
    var candidate = Fixtures.cutSuggestion(id: Fixtures.uuid(1))
    candidate.productType = ProductType(rawValue: type.id)!
    candidate.naming = SuggestionNamingRecord(
      runID: snapshot.runID, typeID: type.id, typeName: type.name, typeGroup: type.group,
      discoveryLabel: "A saved label", extractedValues: ["custom-field": "Café 東京"],
      missingFieldIDs: [],
      correctedValues: ["custom-field": "CAFÉ 東京"], reservation: reservation)
    let starts = SuggestionStarts(groups: [
      .init(key: key, start: .init(number: 9, isExplicit: true))
    ])
    var file = Fixtures.projectFile()
    file.content = EditorDocumentState(
      cutSuggestions: [candidate], suggestionStarts: starts,
      suggestionBatch: .init(
        snapshot: snapshot, actualStarts: SuggestionStarts(),
        canonicalGroups: [.init(key: key, values: reservation.canonicalValues)]),
      issuedSuggestionNumbers: [reservation],
      unfinishedSuggestionRun: .init(
        pythonRevision: 6, controlRevision: 3, originalBatchFingerprint: "original",
        snapshot: snapshot,
        phase: .needsRetry, candidates: [candidate], completedRequestKeys: ["done"],
        failedRequestKeys: ["failed"],
        proposedStarts: starts, failureMessage: "Needs field extraction"),
      lastAppliedSuggestionRunID: Fixtures.uuid(10), suggestionRecoveryOwnerID: Fixtures.uuid(11))
    let data = try ProjectPackage.projectEncoder().encode(file)
    expectNoDifference(
      try ProjectPackage.projectDecoder().decode(ProjectFile.self, from: data), file)
  }

  @Test func currentSchemaVersionIsTwo() {
    expectNoDifference(ProjectFile.currentSchemaVersion, 2)
  }

  @Test func decodesLeniently_missingOriginalPath() throws {
    let json = Data(
      """
      {
        "schemaVersion": 1,
        "source": {
          "originalFileName": "interview.mp3",
          "originalFingerprint": "orig-fp",
          "canonicalFingerprint": "canonical-fp",
          "canonicalByteCount": 4096,
          "importedAt": 1700000000,
          "sampleRate": 44100,
          "channels": 1,
          "durationSamples": 441000
        },
        "engine": { "engineFingerprint": "engine-fp" },
        "content": { "slices": [], "timelineRemovals": [] }
      }
      """.utf8)
    let file = try JSONDecoder().decode(ProjectFile.self, from: json)
    expectNoDifference(file.source.originalPath, nil)
  }
}
