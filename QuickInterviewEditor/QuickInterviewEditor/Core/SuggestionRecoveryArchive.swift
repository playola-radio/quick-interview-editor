import CryptoKit
import Foundation
import os

struct SuggestionRecoveryManifest: Codable, Equatable, Sendable {
  var schemaVersion = 1
  var owner: SuggestionRecoveryOwner
  var snapshot: SuggestionRunSnapshot
  var originalRequest: Data
  var control: SuggestionRecoveryControl
  var retainedAppliedRunIDs: [UUID] = []
}

struct SuggestionRecoveryArchive: Codable, Equatable, Sendable {
  var schemaVersion = 1
  var manifest: SuggestionRecoveryManifest
  var identity: Data?
  var checkpoint: Data?
  var records: [String: Data]
  var retainedAppliedRuns: [SuggestionRecoveryRunArchive] = []

  static func decode(_ data: Data) throws -> Self {
    let json = try RecoveryJSON.read(data)
    try json.keys(
      allowed: [
        "schemaVersion", "manifest", "identity", "checkpoint", "records", "retainedAppliedRuns",
      ],
      required: ["schemaVersion", "manifest", "records"], in: "archive")
    try validateManifestShape(json["manifest"])
    if case .array(let retained)? = json["retainedAppliedRuns"] {
      for run in retained {
        try run.keys(
          allowed: ["manifest", "identity", "checkpoint", "records"],
          required: ["manifest", "records"], in: "retained applied search")
        try validateManifestShape(run["manifest"], in: "retained applied search manifest")
      }
    }
    let result = try JSONDecoder().decode(Self.self, from: data)
    _ = try result.validatedCheckpoint()
    try result.validateRetainedRuns()
    return result
  }

  var singleRun: SuggestionRecoveryRunArchive {
    SuggestionRecoveryRunArchive(
      manifest: manifest, identity: identity, checkpoint: checkpoint, records: records)
  }

  func validateRetainedRuns() throws {
    try validateLineageShape()
    for run in retainedAppliedRuns {
      let phase = try run.archive.validatedCheckpoint().phase
      guard phase == .ready else {
        throw SuggestionRecoveryError.invalid(
          "Retained applied search \(run.manifest.snapshot.runID.uuidString) is in phase \(phase), not ready."
        )
      }
    }
  }

  func validateLineageShape() throws {
    let ids = retainedAppliedRuns.map { $0.manifest.snapshot.runID }
    guard ids == manifest.retainedAppliedRunIDs else {
      throw SuggestionRecoveryError.invalid(
        "The manifest lists \(manifest.retainedAppliedRunIDs.count) applied searches "
          + "but the archive holds \(ids.count) in a different order or set."
      )
    }
    guard Set(ids).count == ids.count else {
      throw SuggestionRecoveryError.invalid("An applied search appears more than once.")
    }
    guard !ids.contains(manifest.snapshot.runID) else {
      throw SuggestionRecoveryError.invalid(
        "Current search \(manifest.snapshot.runID.uuidString) is also listed as already applied.")
    }
    for (index, run) in retainedAppliedRuns.enumerated() {
      let runID = run.manifest.snapshot.runID.uuidString
      guard run.manifest.owner.id == manifest.owner.id,
        run.manifest.owner.sourceFingerprint == manifest.owner.sourceFingerprint,
        run.manifest.owner.transcriptHash == manifest.owner.transcriptHash
      else {
        throw SuggestionRecoveryError.invalid(
          "Retained applied search \(runID) (position \(index)) belongs to a different owner, "
            + "source file or transcript."
        )
      }
      guard run.manifest.retainedAppliedRunIDs == Array(ids.prefix(index)) else {
        throw SuggestionRecoveryError.invalid(
          "Retained applied search \(runID) (position \(index)) has an inconsistent applied history."
        )
      }
    }
  }

  static func validateManifestShape(_ json: RecoveryJSON?, in context: String = "manifest") throws {
    guard let json else { throw SuggestionRecoveryError.invalid("Missing \(context).") }
    try json.keys(
      allowed: [
        "schemaVersion", "owner", "snapshot", "originalRequest", "control", "retainedAppliedRunIDs",
      ],
      required: ["schemaVersion", "owner", "snapshot", "originalRequest", "control"], in: context)
    try json["owner"]?.keys(
      allowed: ["id", "documentURL", "sourceFingerprint", "transcriptHash"],
      required: ["id", "sourceFingerprint", "transcriptHash"], in: "\(context) owner")
    try json["control"]?.keys(
      allowed: ["revision", "proposedStarts", "originalBatchFingerprint", "isPaused"],
      required: ["revision", "proposedStarts", "isPaused"], in: "\(context) control")
    let snapshotFields: Set<String> = [
      "runID", "configuration", "configurationHash", "model", "discoveryPromptVersion",
      "extractionPromptVersion", "productSpecVersion", "transcriptHash", "sourceFingerprint",
      "sampleRate", "stage1Window", "stage1Step", "interviewArtist",
    ]
    try json["snapshot"]?.keys(
      allowed: snapshotFields,
      required: snapshotFields.subtracting(["stage1Window", "stage1Step", "interviewArtist"]),
      in: "\(context) snapshot")
  }

  func validatedCheckpoint(requireReferencedRecords: Bool = true) throws -> SuggestionRunCheckpoint
  {
    try validateManifest()
    let control = manifest.control
    let base = SuggestionRunCheckpoint(
      pythonRevision: 0, controlRevision: control.revision,
      originalBatchFingerprint: control.originalBatchFingerprint, snapshot: manifest.snapshot,
      phase: control.isPaused ? .paused : .discovering, candidates: [], completedRequestKeys: [],
      failedRequestKeys: [], proposedStarts: control.proposedStarts)
    guard let identity else {
      guard checkpoint == nil, records.isEmpty else {
        throw SuggestionRecoveryError.invalid(
          "Missing Python identity for a search that has \(checkpoint == nil ? "no" : "a") checkpoint "
            + "and \(records.count) provider records."
        )
      }
      return base
    }
    let digest = try validateIdentity(identity)
    let completed = try completedKeys(identity: digest)
    guard let checkpoint else { return base }
    let wire = try decodeValidatedWire(checkpoint, digest: digest)
    if requireReferencedRecords { try requireRecords(for: wire, completed: completed) }
    return try wire.checkpoint(
      snapshot: manifest.snapshot, proposedStarts: control.proposedStarts,
      controlRevision: control.revision, originalBatchFingerprint: control.originalBatchFingerprint,
      isPaused: control.isPaused)
  }

  private func decodeValidatedWire(_ checkpoint: Data, digest: String) throws
    -> SuggestionRunWireCheckpoint
  {
    let json = try RecoveryJSON.read(checkpoint)
    try json.keys(
      allowed: [
        "schema_version", "run_id", "request_identity", "revision", "phase", "suggestions",
        "completed_request_keys", "failed_request_keys", "failed_batches", "integrity",
      ], in: "Python checkpoint")
    guard json["request_identity"] == .string(digest) else {
      throw SuggestionRecoveryError.invalid(
        "Python checkpoint request_identity does not match the saved Python identity.")
    }
    guard Self.isDigest(json["integrity"]?.string ?? "") else {
      throw SuggestionRecoveryError.invalid("Python checkpoint integrity is not a valid digest.")
    }
    guard case .array? = json["failed_batches"] else {
      throw SuggestionRecoveryError.invalid("Python checkpoint failed_batches is not a list.")
    }
    try Self.verifyIntegrity(checkpoint, of: "Python checkpoint")
    let wire = try JSONDecoder().decode(SuggestionRunWireCheckpoint.self, from: checkpoint)
    for (name, keys) in [
      ("completed_request_keys", wire.completedRequestKeys),
      ("failed_request_keys", wire.failedRequestKeys),
    ] {
      guard Set(keys).count == keys.count else {
        throw SuggestionRecoveryError.invalid("Python checkpoint \(name) contains duplicates.")
      }
      if let bad = keys.first(where: { !Self.isDigest($0) }) {
        throw SuggestionRecoveryError.invalid(
          "Python checkpoint \(name) contains an invalid request key (\(bad.prefix(80))).")
      }
    }
    return wire
  }

  private func requireRecords(
    for wire: SuggestionRunWireCheckpoint, completed: Set<String>
  ) throws {
    let missingCompleted = Set(wire.completedRequestKeys).subtracting(completed)
    guard missingCompleted.isEmpty else {
      throw SuggestionRecoveryError.invalid(
        "Missing completed provider response for request "
          + missingCompleted.sorted().joined(separator: ", ") + ".")
    }
    let missingFailed = Set(wire.failedRequestKeys).subtracting(Set(records.keys))
    guard missingFailed.isEmpty else {
      throw SuggestionRecoveryError.invalid(
        "Missing failed provider request record for request "
          + missingFailed.sorted().joined(separator: ", ") + ".")
    }
  }

  private func validateIdentity(_ identity: Data) throws -> String {
    let identityJSON = try RecoveryJSON.read(identity)
    try identityJSON.keys(
      allowed: ["schema_version", "request_identity", "immutable_request"], in: "Python identity")
    guard identityJSON["schema_version"] == .integer(1) else {
      throw SuggestionRecoveryError.invalid("Python identity has an unsupported schema_version.")
    }
    guard let digest = identityJSON["request_identity"]?.string, Self.isDigest(digest) else {
      throw SuggestionRecoveryError.invalid(
        "Python identity request_identity is not a valid digest.")
    }
    guard identityJSON["immutable_request"] == (try immutableRequest()) else {
      throw SuggestionRecoveryError.invalid(
        "Python identity immutable_request does not match the original request.")
    }
    guard
      SuggestionRecoveryArchive.sha256(
        try RecoveryPythonBytes.value("immutable_request", in: identity)) == digest
    else {
      throw SuggestionRecoveryError.invalid("Immutable Python identity digest is corrupt.")
    }
    return digest
  }

  private func completedKeys(identity digest: String) throws -> Set<String> {
    var completed = Set<String>()
    for (key, data) in records {
      let record = try Self.validateRecord(data, key: key, identity: digest)
      if record["status"] == .string("completed") { completed.insert(key) }
    }
    return completed
  }

  func validateManifest() throws {
    try validateManifestOwnership()
    try validateOriginalRequest()
  }

  private func validateManifestOwnership() throws {
    guard Set(manifest.retainedAppliedRunIDs).count == manifest.retainedAppliedRunIDs.count else {
      throw SuggestionRecoveryError.invalid("The manifest lists an applied search more than once.")
    }
    guard !manifest.retainedAppliedRunIDs.contains(manifest.snapshot.runID) else {
      throw SuggestionRecoveryError.invalid(
        "Current search \(manifest.snapshot.runID.uuidString) is also listed as already applied.")
    }
    guard schemaVersion == 1, manifest.schemaVersion == 1 else {
      throw SuggestionRecoveryError.invalid(
        "Unsupported schema version (archive \(schemaVersion), manifest \(manifest.schemaVersion))."
      )
    }
    guard manifest.control.revision >= 0 else {
      throw SuggestionRecoveryError.invalid(
        "Control revision \(manifest.control.revision) is negative.")
    }
    guard manifest.owner.sourceFingerprint == manifest.snapshot.sourceFingerprint else {
      throw SuggestionRecoveryError.invalid(
        "The owner's source fingerprint differs from the search snapshot's.")
    }
    guard manifest.owner.transcriptHash == manifest.snapshot.transcriptHash else {
      throw SuggestionRecoveryError.invalid(
        "The owner's transcript hash differs from the search snapshot's.")
    }
    let configurationProblems = manifest.snapshot.configuration.validationMessages()
    guard configurationProblems.isEmpty else {
      throw SuggestionRecoveryError.invalid(
        "The search snapshot's configuration is invalid: \(configurationProblems.joined(separator: " "))"
      )
    }
  }

  private func validateOriginalRequest() throws {
    let request = try immutableRequest()
    let snapshot = manifest.snapshot
    let configuration = try RecoveryJSON.read(JSONEncoder().encode(snapshot.configuration))
    let options: RecoveryJSON = .object([
      "model": .string(snapshot.model), "sample_rate": .integer(Int64(snapshot.sampleRate)),
      "stage1_window": .integer(Int64(snapshot.stage1Window)),
      "stage1_step": .integer(Int64(snapshot.stage1Step)),
      "discovery_prompt_version": .string(snapshot.discoveryPromptVersion),
      "extraction_prompt_version": .string(snapshot.extractionPromptVersion),
      "product_spec_version": .string(snapshot.productSpecVersion),
    ])
    var hasTranscriptUnits = false
    if case .array? = request["transcript_units"] { hasTranscriptUnits = true }
    let expectedArtist = snapshot.interviewArtist.map(RecoveryJSON.string)
    let artistIsBlank =
      snapshot.interviewArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
    let checks: [(field: String, matches: Bool)] = [
      ("schema_version", request["schema_version"] == .integer(2)),
      ("run_id", request["run_id"]?.string.flatMap(UUID.init(uuidString:)) == snapshot.runID),
      ("transcript_hash", request["transcript_hash"] == .string(snapshot.transcriptHash)),
      ("source_fingerprint", request["source_fingerprint"] == .string(snapshot.sourceFingerprint)),
      ("configuration", request["configuration"] == configuration),
      ("interview_artist", request["interview_artist"] == expectedArtist && !artistIsBlank),
      ("options", request["options"] == options),
      ("transcript_units", hasTranscriptUnits),
      (
        "configurationHash",
        snapshot.configurationHash == (try Self.configurationHash(snapshot.configuration))
      ),
    ]
    if let failed = checks.first(where: { !$0.matches }) {
      throw SuggestionRecoveryError.invalid(
        "Original request field \(failed.field) does not match its immutable snapshot.")
    }
  }

  func immutableRequest() throws -> RecoveryJSON {
    let json = try RecoveryJSON.read(manifest.originalRequest)
    let required = [
      "schema_version", "run_id", "transcript_hash", "source_fingerprint", "transcript_units",
      "configuration",
    ]
    var result = [String: RecoveryJSON]()
    for key in required {
      guard let value = json[key] else {
        throw SuggestionRecoveryError.invalid("Missing request field \(key).")
      }
      result[key] = value
    }
    let options = [
      "model", "sample_rate", "stage1_window", "stage1_step", "discovery_prompt_version",
      "extraction_prompt_version", "product_spec_version",
    ]
    var values = [String: RecoveryJSON]()
    for key in options {
      guard let value = json["options"]?[key] else {
        throw SuggestionRecoveryError.invalid("Missing option \(key).")
      }
      values[key] = value
    }
    if let artist = json["interview_artist"] { result["interview_artist"] = artist }
    result["options"] = .object(values)
    return .object(result)
  }

  static func configurationHash(_ configuration: SuggestionConfiguration) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return sha256(try encoder.encode(configuration))
  }

  static func validateRecord(_ data: Data, key: String, identity: String) throws -> RecoveryJSON {
    guard isDigest(key) else {
      throw SuggestionRecoveryError.invalid("Invalid provider request key (\(key.prefix(80))).")
    }
    try verifyIntegrity(data, of: "provider record \(key)")
    let record = try RecoveryJSON.read(data)
    let common: Set<String> = ["schema_version", "request_identity", "key", "status", "integrity"]
    let complete = record["status"] == .string("completed")
    try validateRecordFields(record, key: key, common: common, complete: complete)
    guard record["schema_version"] == .integer(1) else {
      throw SuggestionRecoveryError.invalid(
        "Provider record \(key) has an unsupported schema_version.")
    }
    guard record["request_identity"] == .string(identity) else {
      throw SuggestionRecoveryError.invalid(
        "Provider record \(key) belongs to a different request identity.")
    }
    guard record["key"] == .string(key) else {
      throw SuggestionRecoveryError.invalid(
        "Provider record stored under \(key) names a different request key.")
    }
    guard isDigest(record["integrity"]?.string ?? "") else {
      throw SuggestionRecoveryError.invalid(
        "Provider record \(key) integrity is not a valid digest.")
    }
    if complete {
      guard let response = record["response"]?.string else {
        throw SuggestionRecoveryError.invalid(
          "Completed provider record \(key) has no response text.")
      }
      guard record["response_sha256"] == .string(sha256(Data(response.utf8))) else {
        throw SuggestionRecoveryError.invalid(
          "Completed provider record \(key) response does not match its digest.")
      }
    } else {
      guard record["status"] == .string("failed") else {
        throw SuggestionRecoveryError.invalid("Provider record \(key) has an unknown status.")
      }
      let errorType = try failedRecordErrorType(record, key: key)
      AppLog.suggestions.info(
        "Provider request \(key, privacy: .public) previously failed with \(errorType, privacy: .public)"
      )
    }
    return record
  }

  private static func validateRecordFields(
    _ record: RecoveryJSON, key: String, common: Set<String>, complete: Bool
  ) throws {
    if complete {
      try record.keys(
        allowed: common.union(["response", "response_sha256"]),
        required: common.union(["response", "response_sha256"]),
        in: "provider record \(key)")
    } else {
      try record.keys(
        allowed: common.union(["error_type", "rejected_response"]),
        required: common.union(["error_type"]),
        in: "provider record \(key)")
    }
  }

  private static func failedRecordErrorType(_ record: RecoveryJSON, key: String) throws -> String {
    guard let errorType = record["error_type"]?.string else {
      throw SuggestionRecoveryError.invalid("Failed provider record \(key) has no error_type.")
    }
    guard record["rejected_response"] == nil || record["rejected_response"]?.string != nil else {
      throw SuggestionRecoveryError.invalid(
        "Failed provider record \(key) rejected_response is not text.")
    }
    return errorType
  }

  static func verifyIntegrity(_ data: Data, of label: String) throws {
    do {
      try RecoveryPythonBytes.verifyIntegrity(data)
    } catch SuggestionRecoveryError.invalid(let detail) {
      throw SuggestionRecoveryError.invalid("\(label): \(detail)")
    }
  }

  static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func recordFilename(_ key: String) -> String {
    sha256(Data("\"\(key)\"".utf8)) + ".json"
  }
}

indirect enum RecoveryJSON: Decodable, Equatable {
  case object([String: Self])
  case array([Self])
  case string(String)
  case integer(Int64)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let bool = try? value.decode(Bool.self) {
      self = .bool(bool)
    } else if let integer = try? value.decode(Int64.self) {
      self = .integer(integer)
    } else if let number = try? value.decode(Double.self) {
      self = .number(number)
    } else if let string = try? value.decode(String.self) {
      self = .string(string)
    } else if let array = try? value.decode([Self].self) {
      self = .array(array)
    } else {
      self = .object(try value.decode([String: Self].self))
    }
  }

  static func read(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
  subscript(_ key: String) -> Self? {
    if case .object(let values) = self { values[key] } else { nil }
  }
  var string: String? { if case .string(let value) = self { value } else { nil } }
  func keys(allowed: Set<String>, required: Set<String>? = nil, in context: String = "archive")
    throws
  {
    guard case .object(let values) = self else {
      throw SuggestionRecoveryError.invalid("The \(context) is not a JSON object.")
    }
    let present = Set(values.keys)
    let unexpected = present.subtracting(allowed).sorted()
    let missing = (required ?? allowed).subtracting(present).sorted()
    guard unexpected.isEmpty, missing.isEmpty else {
      var parts: [String] = []
      if !unexpected.isEmpty {
        parts.append("unexpected fields: " + unexpected.joined(separator: ", "))
      }
      if !missing.isEmpty { parts.append("missing fields: " + missing.joined(separator: ", ")) }
      throw SuggestionRecoveryError.invalid("The \(context) has \(parts.joined(separator: "; ")).")
    }
  }
}

struct SuggestionRecoveryRunArchive: Codable, Equatable, Sendable {
  var manifest: SuggestionRecoveryManifest
  var identity: Data?
  var checkpoint: Data?
  var records: [String: Data]

  var archive: SuggestionRecoveryArchive {
    SuggestionRecoveryArchive(
      manifest: manifest, identity: identity, checkpoint: checkpoint, records: records)
  }
}

extension SuggestionRecoveryManifest {
  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    owner = try values.decode(SuggestionRecoveryOwner.self, forKey: .owner)
    snapshot = try values.decode(SuggestionRunSnapshot.self, forKey: .snapshot)
    originalRequest = try values.decode(Data.self, forKey: .originalRequest)
    control = try values.decode(SuggestionRecoveryControl.self, forKey: .control)
    retainedAppliedRunIDs =
      try values.decodeIfPresent([UUID].self, forKey: .retainedAppliedRunIDs) ?? []
  }
}

extension SuggestionRecoveryArchive {
  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    manifest = try values.decode(SuggestionRecoveryManifest.self, forKey: .manifest)
    identity = try values.decodeIfPresent(Data.self, forKey: .identity)
    checkpoint = try values.decodeIfPresent(Data.self, forKey: .checkpoint)
    records = try values.decode([String: Data].self, forKey: .records)
    retainedAppliedRuns =
      try values.decodeIfPresent([SuggestionRecoveryRunArchive].self, forKey: .retainedAppliedRuns)
      ?? []
  }
}
