import CryptoKit
import Foundation

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
      required: ["schemaVersion", "manifest", "records"])
    try validateManifestShape(json["manifest"])
    if case .array(let retained)? = json["retainedAppliedRuns"] {
      for run in retained {
        try run.keys(
          allowed: ["manifest", "identity", "checkpoint", "records"],
          required: ["manifest", "records"])
        try validateManifestShape(run["manifest"])
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
      guard try run.archive.validatedCheckpoint().phase == .ready else {
        throw SuggestionRecoveryError.invalid("Invalid retained applied search.")
      }
    }
  }

  func validateLineageShape() throws {
    let ids = retainedAppliedRuns.map { $0.manifest.snapshot.runID }
    guard ids == manifest.retainedAppliedRunIDs, Set(ids).count == ids.count,
      !ids.contains(manifest.snapshot.runID)
    else { throw SuggestionRecoveryError.invalid("Invalid applied recovery lineage.") }
    for (index, run) in retainedAppliedRuns.enumerated() {
      guard run.manifest.owner.id == manifest.owner.id,
        run.manifest.owner.sourceFingerprint == manifest.owner.sourceFingerprint,
        run.manifest.owner.transcriptHash == manifest.owner.transcriptHash,
        run.manifest.retainedAppliedRunIDs == Array(ids.prefix(index))
      else {
        throw SuggestionRecoveryError.invalid("Invalid retained applied search.")
      }
    }
  }

  static func validateManifestShape(_ json: RecoveryJSON?) throws {
    guard let json else { throw SuggestionRecoveryError.invalid("Missing manifest.") }
    try json.keys(
      allowed: [
        "schemaVersion", "owner", "snapshot", "originalRequest", "control", "retainedAppliedRunIDs",
      ],
      required: ["schemaVersion", "owner", "snapshot", "originalRequest", "control"])
    try json["owner"]?.keys(
      allowed: ["id", "documentURL", "sourceFingerprint", "transcriptHash"],
      required: ["id", "sourceFingerprint", "transcriptHash"])
    try json["control"]?.keys(
      allowed: ["revision", "proposedStarts", "originalBatchFingerprint", "isPaused"],
      required: ["revision", "proposedStarts", "isPaused"])
    let snapshotFields: Set<String> = [
      "runID", "configuration", "configurationHash", "model", "discoveryPromptVersion",
      "extractionPromptVersion", "productSpecVersion", "transcriptHash", "sourceFingerprint",
      "sampleRate", "stage1Window", "stage1Step", "interviewArtist",
    ]
    try json["snapshot"]?.keys(
      allowed: snapshotFields,
      required: snapshotFields.subtracting(["stage1Window", "stage1Step", "interviewArtist"]))
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
        throw SuggestionRecoveryError.invalid("Missing Python identity.")
      }
      return base
    }
    let digest = try validateIdentity(identity)
    let completed = try completedKeys(identity: digest)
    guard let checkpoint else { return base }
    let json = try RecoveryJSON.read(checkpoint)
    try json.keys(allowed: [
      "schema_version", "run_id", "request_identity", "revision", "phase", "suggestions",
      "completed_request_keys", "failed_request_keys", "failed_batches", "integrity",
    ])
    guard json["request_identity"] == .string(digest),
      Self.isDigest(json["integrity"]?.string ?? ""),
      case .array? = json["failed_batches"]
    else { throw SuggestionRecoveryError.invalid("Malformed Python checkpoint.") }
    try RecoveryPythonBytes.verifyIntegrity(checkpoint)
    let wire = try JSONDecoder().decode(SuggestionRunWireCheckpoint.self, from: checkpoint)
    for keys in [wire.completedRequestKeys, wire.failedRequestKeys] {
      guard Set(keys).count == keys.count, keys.allSatisfy(Self.isDigest) else {
        throw SuggestionRecoveryError.invalid("Invalid checkpoint request keys.")
      }
    }
    guard !requireReferencedRecords || Set(wire.completedRequestKeys).isSubset(of: completed) else {
      throw SuggestionRecoveryError.invalid("Missing completed provider response.")
    }
    guard !requireReferencedRecords || Set(wire.failedRequestKeys).isSubset(of: Set(records.keys))
    else {
      throw SuggestionRecoveryError.invalid("Missing failed provider request record.")
    }
    return try wire.checkpoint(
      snapshot: manifest.snapshot, proposedStarts: control.proposedStarts,
      controlRevision: control.revision, originalBatchFingerprint: control.originalBatchFingerprint,
      isPaused: control.isPaused)
  }

  private func validateIdentity(_ identity: Data) throws -> String {
    let identityJSON = try RecoveryJSON.read(identity)
    try identityJSON.keys(allowed: ["schema_version", "request_identity", "immutable_request"])
    guard identityJSON["schema_version"] == .integer(1),
      let digest = identityJSON["request_identity"]?.string, Self.isDigest(digest),
      identityJSON["immutable_request"] == (try immutableRequest())
    else {
      throw SuggestionRecoveryError.invalid("Python identity does not match the original request.")
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
    guard Set(manifest.retainedAppliedRunIDs).count == manifest.retainedAppliedRunIDs.count,
      !manifest.retainedAppliedRunIDs.contains(manifest.snapshot.runID)
    else {
      throw SuggestionRecoveryError.invalid("Invalid applied recovery lineage.")
    }
    guard schemaVersion == 1, manifest.schemaVersion == 1, manifest.control.revision >= 0,
      manifest.owner.sourceFingerprint == manifest.snapshot.sourceFingerprint,
      manifest.owner.transcriptHash == manifest.snapshot.transcriptHash,
      manifest.snapshot.configuration.validationMessages().isEmpty
    else { throw SuggestionRecoveryError.invalid("Invalid recovery manifest.") }
    let request = try immutableRequest()
    let snapshot = manifest.snapshot
    let configuration = try RecoveryJSON.read(JSONEncoder().encode(snapshot.configuration))
    guard request["schema_version"] == .integer(2),
      request["run_id"]?.string.flatMap(UUID.init(uuidString:)) == snapshot.runID,
      request["transcript_hash"] == .string(snapshot.transcriptHash),
      request["source_fingerprint"] == .string(snapshot.sourceFingerprint),
      request["configuration"] == configuration,
      request["interview_artist"] == snapshot.interviewArtist.map(RecoveryJSON.string),
      snapshot.interviewArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true,
      request["options"]
        == .object([
          "model": .string(snapshot.model), "sample_rate": .integer(Int64(snapshot.sampleRate)),
          "stage1_window": .integer(Int64(snapshot.stage1Window)),
          "stage1_step": .integer(Int64(snapshot.stage1Step)),
          "discovery_prompt_version": .string(snapshot.discoveryPromptVersion),
          "extraction_prompt_version": .string(snapshot.extractionPromptVersion),
          "product_spec_version": .string(snapshot.productSpecVersion),
        ]),
      case .array? = request["transcript_units"],
      snapshot.configurationHash == (try Self.configurationHash(snapshot.configuration))
    else {
      throw SuggestionRecoveryError.invalid(
        "Original request does not match its immutable snapshot.")
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
    guard isDigest(key) else { throw SuggestionRecoveryError.invalid("Invalid request key.") }
    try RecoveryPythonBytes.verifyIntegrity(data)
    let record = try RecoveryJSON.read(data)
    let common: Set<String> = ["schema_version", "request_identity", "key", "status", "integrity"]
    let complete = record["status"] == .string("completed")
    try record.keys(
      allowed: common.union(complete ? ["response", "response_sha256"] : ["error_type"]))
    guard record["schema_version"] == .integer(1), record["request_identity"] == .string(identity),
      record["key"] == .string(key), isDigest(record["integrity"]?.string ?? "")
    else { throw SuggestionRecoveryError.invalid("Invalid provider record identity.") }
    if complete {
      guard let response = record["response"]?.string,
        record["response_sha256"] == .string(sha256(Data(response.utf8)))
      else { throw SuggestionRecoveryError.invalid("Corrupt completed provider response.") }
    } else {
      guard record["status"] == .string("failed"), record["error_type"]?.string != nil else {
        throw SuggestionRecoveryError.invalid("Invalid failed provider record.")
      }
    }
    return record
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
  func keys(allowed: Set<String>, required: Set<String>? = nil) throws {
    guard case .object(let values) = self, Set(values.keys).isSubset(of: allowed),
      (required ?? allowed).isSubset(of: Set(values.keys))
    else {
      throw SuggestionRecoveryError.invalid("Unexpected or missing archive fields.")
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
