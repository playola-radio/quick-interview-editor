import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct SuggestionRecoveryClientTests {
  @Test func canonicalPythonIntegrityUsesOriginalMemberBytes() throws {
    let payload = Data(
      #"{"key":"value","response":"escaped \" quote { }","value":{"integrity":"nested"}}"#.utf8)
    let digest = SuggestionRecoveryArchive.sha256(payload)
    let full = Data(
      ("{\"integrity\":\"" + digest + "\"," + String(bytes: payload.dropFirst(), encoding: .utf8)!)
        .utf8)
    try RecoveryPythonBytes.verifyIntegrity(full)
    let tampered = Data(
      String(data: full, encoding: .utf8)!.replacingOccurrences(of: "value", with: "other").utf8)
    #expect(throws: (any Error).self) { try RecoveryPythonBytes.verifyIntegrity(tampered) }
  }

  @Test func manifestOnlyCaptureReopensThroughIndependentStore() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try RecoveryFixture()
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    let directory = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    expectNoDifference(directory.lastPathComponent, fixture.snapshot.runID.uuidString)
    let capture = try await SuggestionRecoveryStore(root: root, uuid: { UUID() }).capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: nil)
    expectNoDifference(capture.checkpoint.snapshot, fixture.snapshot)
    expectNoDifference(capture.checkpoint.pythonRevision, 0)
    let restoredRoot = root.appending(component: "restored")
    let restored = SuggestionRecoveryStore(root: restoredRoot, uuid: { UUID() })
    try await restored.restore(fixture.owner, archive: capture.archive)
    let reopened = try await restored.load(fixture.owner)
    expectNoDifference(reopened, capture.checkpoint)
  }

  @Test func controlChecksRevisionAndFailedWriteDoesNotAdvance() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try RecoveryFixture()
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    _ = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    let failing = SuggestionRecoveryStore(
      root: root, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    var control = fixture.preparation.control
    control.isPaused = true
    await #expect(throws: (any Error).self) {
      try await failing.updateControl(
        fixture.owner, runID: fixture.snapshot.runID, control: control, expectedRevision: 0)
    }
    let before = try await store.load(fixture.owner)
    expectNoDifference(before?.controlRevision, 0)
    try await store.updateControl(
      fixture.owner, runID: fixture.snapshot.runID, control: control, expectedRevision: 0)
    let after = try await store.load(fixture.owner)
    expectNoDifference(after?.phase, .paused)
    await #expect(throws: SuggestionRecoveryError.staleControl) {
      try await store.updateControl(
        fixture.owner, runID: fixture.snapshot.runID, control: control, expectedRevision: 0)
    }
  }
}

struct RecoveryFixture {
  var owner: SuggestionRecoveryOwner
  var snapshot: SuggestionRunSnapshot
  var preparation: SuggestionRecoveryPreparation

  init(documentURL: URL? = nil) throws {
    snapshot = SuggestionRunSnapshot(
      runID: Fixtures.uuid(50), configuration: SuggestionDefaults.configuration,
      configurationHash: try SuggestionRecoveryArchive.configurationHash(
        SuggestionDefaults.configuration), model: "test",
      discoveryPromptVersion: "v1", extractionPromptVersion: "v1", productSpecVersion: "v1",
      transcriptHash: "transcript", sourceFingerprint: "source", sampleRate: 48000)
    owner = SuggestionRecoveryOwner(
      id: Fixtures.uuid(51), documentURL: documentURL, sourceFingerprint: "source",
      transcriptHash: "transcript")
    let request = CutSuggestRequest(
      transcriptUnits: [], diarization: nil, productSpecs: [], options: .init(),
      transcriptHash: "transcript", sourceFingerprint: "source", sampleRate: 48000,
      snapshot: snapshot)
    preparation = SuggestionRecoveryPreparation(
      snapshot: snapshot, originalRequest: try LiveCutSuggester.encodedRequest(request),
      control: .init(
        revision: 0, proposedStarts: .init(), originalBatchFingerprint: nil, isPaused: false))
  }
}

extension RecoveryFixture {
  static func matching(file: ProjectFile, plan: EditPlan) throws -> Self {
    var result = try Self()
    result.snapshot.transcriptHash = plan.transcriptHash
    result.snapshot.sourceFingerprint = file.source.originalFingerprint
    result.snapshot.sampleRate = plan.source.sampleRate
    result.owner.transcriptHash = plan.transcriptHash
    result.owner.sourceFingerprint = file.source.originalFingerprint
    result.preparation.snapshot = result.snapshot
    result.preparation.originalRequest = try LiveCutSuggester.encodedRequest(
      .init(
        transcriptUnits: [],
        diarization: nil, productSpecs: [], options: .init(), transcriptHash: plan.transcriptHash,
        sourceFingerprint: file.source.originalFingerprint, sampleRate: plan.source.sampleRate,
        snapshot: result.snapshot))
    return result
  }

  struct Python: Decodable {
    var originalRequest: Data
    var identity: Data
    var checkpoint: Data
    var records: [String: Data]
  }

  static func python() throws -> (Self, Python) {
    let python = try JSONDecoder().decode(
      Python.self, from: suggestionContractFixture("suggestion-recovery-python"))
    var fixture = try Self()
    fixture.snapshot.runID = Fixtures.uuid(1)
    fixture.snapshot.model = "fixture-model"
    fixture.snapshot.discoveryPromptVersion = "configured-v1"
    fixture.snapshot.extractionPromptVersion = "fields-v1"
    fixture.snapshot.productSpecVersion = "configured-v1"
    fixture.snapshot.transcriptHash = "fixture-transcript"
    fixture.snapshot.sourceFingerprint = "fixture-source"
    fixture.snapshot.sampleRate = 44100
    fixture.owner.transcriptHash = fixture.snapshot.transcriptHash
    fixture.owner.sourceFingerprint = fixture.snapshot.sourceFingerprint
    fixture.preparation.snapshot = fixture.snapshot
    fixture.preparation.originalRequest = python.originalRequest
    return (fixture, python)
  }

  func writePython(_ python: Python, directory: URL) throws {
    try python.identity.write(to: directory.appending(component: "identity.json"))
    try python.checkpoint.write(to: directory.appending(component: "checkpoint.json"))
    let records = directory.appending(component: "requests")
    try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
    for (key, bytes) in python.records {
      try bytes.write(
        to: records.appending(component: SuggestionRecoveryArchive.recordFilename(key)))
    }
  }
}

extension SuggestionRecoveryClientTests {
  @Test func readyPythonArchiveRestoresOriginalCandidatesAndExtraPaidRecords() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (fixture, python) = try RecoveryFixture.python()
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    let directory = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    try fixture.writePython(python, directory: directory)
    let capture = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: 1)
    expectNoDifference(capture.checkpoint.phase, .ready)
    expectNoDifference(capture.checkpoint.candidates.count, 1)
    let archive = try SuggestionRecoveryArchive.decode(capture.archive)
    expectNoDifference(archive.records, python.records)
    expectNoDifference(archive.manifest.originalRequest, python.originalRequest)
    let reopened = SuggestionRecoveryStore(
      root: root.appending(component: "restored"), uuid: { UUID() })
    try await reopened.restore(fixture.owner, archive: capture.archive)
    let restored = try await reopened.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: nil)
    expectNoDifference(restored.checkpoint, capture.checkpoint)
    expectNoDifference(
      try SuggestionRecoveryArchive.decode(restored.archive).records, python.records)
    try FileManager.default.removeItem(at: directory.appending(component: "requests"))
    try FileManager.default.removeItem(at: directory.appending(component: "identity.json"))
    try await store.restore(fixture.owner, archive: capture.archive)
    let repaired = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: 1)
    expectNoDifference(repaired.checkpoint, capture.checkpoint)
  }

  @Test(arguments: [
    "missingRecord", "corruptRecord", "corruptCheckpoint", "missingIdentity", "path",
    "unknownArchiveField",
  ])
  func rejectsDamagedRecoveryBeforeAnyRestorationWrites(kind: String) async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (fixture, python) = try RecoveryFixture.python()
    var archive = SuggestionRecoveryArchive(
      manifest: .init(
        owner: fixture.owner, snapshot: fixture.snapshot, originalRequest: python.originalRequest,
        control: fixture.preparation.control), identity: python.identity,
      checkpoint: python.checkpoint, records: python.records)
    switch kind {
    case "missingRecord": archive.records = [:]
    case "corruptRecord":
      archive.records = python.records.mapValues {
        Data(
          String(data: $0, encoding: .utf8)!.replacingOccurrences(
            of: "completed", with: "tampered"
          ).utf8)
      }
    case "corruptCheckpoint":
      archive.checkpoint = Data(
        String(data: python.checkpoint, encoding: .utf8)!.replacingOccurrences(
          of: "ready", with: "needs_retry"
        ).utf8)
    case "missingIdentity": archive.identity = nil
    case "path": archive.records["../../outside"] = python.records.values.first
    default: break
    }
    var bytes = try JSONEncoder().encode(archive)
    if kind == "unknownArchiveField" {
      var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      object["path"] = "/tmp/outside"
      bytes = try JSONSerialization.data(withJSONObject: object)
    }
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    await #expect(throws: (any Error).self) {
      try await store.restore(fixture.owner, archive: bytes)
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test func independentControlMergeKeepsPauseAndEqualRevisionConflicts() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (fixture, python) = try RecoveryFixture.python()
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    let directory = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    let initial = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: nil)
    var pause = fixture.preparation.control
    pause.isPaused = true
    try await store.updateControl(
      fixture.owner, runID: fixture.snapshot.runID, control: pause, expectedRevision: 0)
    try fixture.writePython(python, directory: directory)
    try await store.restore(fixture.owner, archive: initial.archive)
    let merged = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: 1)
    expectNoDifference(merged.checkpoint.phase, .paused)
    expectNoDifference(merged.checkpoint.controlRevision, 1)
    expectNoDifference(merged.checkpoint.pythonRevision, 1)
    var conflicting = try SuggestionRecoveryArchive.decode(merged.archive)
    conflicting.manifest.control.isPaused = false
    let conflictBytes = try JSONEncoder().encode(conflicting)
    await #expect(throws: SuggestionRecoveryError.self) {
      try await store.restore(fixture.owner, archive: conflictBytes)
    }
  }

  @Test func locationsFirstSaveMoveAndCopyKeepIndependentJournals() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try RecoveryFixture()
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    _ = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    let firstURL = root.appending(component: "first.pie")
    let first = try #require(
      try await store.resolveOwner(
        persistedID: fixture.owner.id, documentURL: firstURL, sourceFingerprint: "source",
        transcriptHash: "transcript"))
    expectNoDifference(first.id, fixture.owner.id)
    let movedURL = root.appending(component: "moved.pie")
    let moved = try #require(
      try await store.resolveOwner(
        persistedID: first.id, documentURL: movedURL, sourceFingerprint: "source",
        transcriptHash: "transcript"))
    expectNoDifference(moved.id, first.id)
    try FileManager.default.createDirectory(at: movedURL, withIntermediateDirectories: true)
    let copy = try #require(
      try await store.resolveOwner(
        persistedID: moved.id, documentURL: root.appending(component: "copy.pie"),
        sourceFingerprint: "source", transcriptHash: "transcript"))
    #expect(copy.id != moved.id)
    try await store.discard(copy, runID: fixture.snapshot.runID)
    let original = try await store.load(moved)
    expectNoDifference(original?.snapshot, fixture.snapshot)
    let indexed = try await store.resolveOwner(
      persistedID: nil, documentURL: movedURL, sourceFingerprint: "source",
      transcriptHash: "transcript")
    expectNoDifference(indexed, moved)
  }

  @Test func nilURLRequiresExplicitOrphanChoiceAndSecondLiveWindowForks() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try RecoveryFixture()
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    _ = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    let missing = try await store.resolveOwner(
      persistedID: nil, documentURL: nil, sourceFingerprint: "source", transcriptHash: "transcript")
    expectNoDifference(missing, nil)
    let orphans = try await store.recoverableOrphans(
      sourceFingerprint: "source", transcriptHash: "transcript")
    expectNoDifference(orphans, [fixture.owner])
    let first = try await store.claimOwner(fixture.owner, instanceID: Fixtures.uuid(80))
    let second = try await store.claimOwner(fixture.owner, instanceID: Fixtures.uuid(81))
    expectNoDifference(first, fixture.owner)
    #expect(second.id != first.id)
    try await store.discard(second, runID: fixture.snapshot.runID)
    let retained = try await store.load(first)
    #expect(retained != nil)
  }
}

extension SuggestionRecoveryClientTests {
  @Test func cleanupRequiresActualSavedOwnerAndAppliedRun() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appending(component: "project.pie")
    let fixture = try RecoveryFixture(documentURL: package)
    let store = SuggestionRecoveryStore(
      root: root.appending(component: "recovery"), uuid: { UUID() })
    _ = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    await #expect(throws: SuggestionRecoveryError.notSaved) {
      try await store.confirmSaved(fixture.owner, runID: fixture.snapshot.runID)
    }
    let beforeSave = try await store.load(fixture.owner)
    #expect(beforeSave != nil)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    var file = Fixtures.projectFile()
    file.content.suggestionRecoveryOwnerID = fixture.owner.id
    file.content.lastAppliedSuggestionRunID = Fixtures.uuid(99)
    try ProjectPackage.projectEncoder().encode(file).write(
      to: package.appending(component: "project.json"))
    await #expect(throws: SuggestionRecoveryError.notSaved) {
      try await store.confirmSaved(fixture.owner, runID: fixture.snapshot.runID)
    }
    file.content.lastAppliedSuggestionRunID = fixture.snapshot.runID
    try ProjectPackage.projectEncoder().encode(file).write(
      to: package.appending(component: "project.json"))
    try await store.confirmSaved(fixture.owner, runID: fixture.snapshot.runID)
    let afterSave = try await store.load(fixture.owner)
    expectNoDifference(afterSave, nil)
  }

  @Test func prepareIndexFailureThrowsAndLeavesNoLaunchAuthorization() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try RecoveryFixture(documentURL: root.appending(component: "project.pie"))
    let store = SuggestionRecoveryStore(
      root: root,
      write: { data, url in
        if url.deletingLastPathComponent().lastPathComponent == "locations" {
          throw CocoaError(.fileWriteNoPermission)
        }
        try data.write(to: url, options: .atomic)
      }, uuid: { UUID() })
    await #expect(throws: (any Error).self) {
      try await store.prepare(fixture.owner, preparation: fixture.preparation)
    }
    let recovered = try await store.load(fixture.owner)
    expectNoDifference(recovered?.pythonRevision, 0)
    let lookup = try await store.resolveOwner(
      persistedID: nil, documentURL: fixture.owner.documentURL, sourceFingerprint: "source",
      transcriptHash: "transcript")
    expectNoDifference(lookup, nil)
  }

  @Test(arguments: ["checkpoint", "completedResponse"])
  func equalRevisionOrCompletedResponseConflictsRemainVisible(component: String) async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (fixture, python) = try RecoveryFixture.python()
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    let directory = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    try fixture.writePython(python, directory: directory)
    let capture = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: nil)
    var archive = try SuggestionRecoveryArchive.decode(capture.archive)
    if component == "checkpoint" {
      var object = try #require(
        JSONSerialization.jsonObject(with: python.checkpoint) as? [String: Any])
      object["phase"] = "extracting"
      archive.checkpoint = try signedPythonObject(object)
    } else {
      let key = try #require(python.records.keys.first)
      var object = try #require(
        JSONSerialization.jsonObject(with: python.records[key]!) as? [String: Any])
      object["response"] = "a different paid response"
      object["response_sha256"] = SuggestionRecoveryArchive.sha256(
        Data("a different paid response".utf8))
      archive.records[key] = try signedPythonObject(object)
    }
    let conflicting = try JSONEncoder().encode(archive)
    await #expect(throws: SuggestionRecoveryError.self) {
      try await store.restore(fixture.owner, archive: conflicting)
    }
    let retained = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: nil)
    expectNoDifference(retained.checkpoint, capture.checkpoint)
  }

  @Test func completedResponseReplacesFailedRecordWithoutAdvancingCheckpoint() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (fixture, python) = try RecoveryFixture.python()
    let store = SuggestionRecoveryStore(root: root, uuid: { UUID() })
    let directory = try await store.prepare(fixture.owner, preparation: fixture.preparation)
    try fixture.writePython(python, directory: directory)
    let capture = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: nil)
    let key = try #require(
      python.records.keys.first { !capture.checkpoint.completedRequestKeys.contains($0) })
    let identity = try #require(RecoveryJSON.read(python.identity)["request_identity"]?.string)
    let failed = try signedPythonObject([
      "schema_version": 1, "request_identity": identity, "key": key, "status": "failed",
      "error_type": "TransientError",
    ])
    try failed.write(
      to: directory.appending(component: "requests").appending(
        component: SuggestionRecoveryArchive.recordFilename(key)))
    try await store.restore(fixture.owner, archive: capture.archive)
    let recovered = try await store.capture(
      fixture.owner, runID: fixture.snapshot.runID, minimumPythonRevision: nil)
    expectNoDifference(
      try SuggestionRecoveryArchive.decode(recovered.archive).records[key], python.records[key])
    expectNoDifference(recovered.checkpoint.pythonRevision, 1)
  }

  private func signedPythonObject(_ object: [String: Any]) throws -> Data {
    var object = object
    object.removeValue(forKey: "integrity")
    let unsigned = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    object["integrity"] = SuggestionRecoveryArchive.sha256(unsigned)
    return try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
  }
}
