import Dependencies
import Foundation

struct SuggestionRecoveryOwner: Codable, Equatable, Sendable {
  var id: UUID
  var documentURL: URL?
  var sourceFingerprint: String
  var transcriptHash: String
}

struct SuggestionRecoveryControl: Codable, Equatable, Sendable {
  var revision: Int
  var proposedStarts: SuggestionStarts
  var originalBatchFingerprint: String?
  var isPaused: Bool
}

struct SuggestionRecoveryPreparation: Sendable {
  var snapshot: SuggestionRunSnapshot
  var originalRequest: Data
  var control: SuggestionRecoveryControl
  var lastAppliedRunID: UUID?
}

struct SuggestionRecoveryCapture: Equatable, Sendable {
  var checkpoint: SuggestionRunCheckpoint
  var archive: Data
  var journalDirectory: URL
}

enum SuggestionRecoveryError: Error, Equatable, LocalizedError {
  case invalid(String)
  case missingRun
  case staleControl
  case revisionOverflow
  case conflict(String)
  case staleIdentity(owner: SuggestionRecoveryOwner, runID: UUID)
  case notSaved

  var errorDescription: String? {
    switch self {
    case .invalid(let detail): "The saved suggestion search is damaged: \(detail)"
    case .missingRun: "The unfinished suggestion search could not be found."
    case .staleControl: "The search settings changed. Reload the unfinished search."
    case .revisionOverflow: "The search revision cannot advance."
    case .conflict(let detail): "The saved suggestion searches conflict: \(detail)"
    case .staleIdentity:
      "This unfinished search belongs to an earlier transcript. Discard it before starting a new search."
    case .notSaved: "The applied suggestions have not been confirmed on disk yet."
    }
  }
}

struct SuggestionRecoveryOwnerResolution: Sendable {
  var persistedID: UUID?
  var documentURL: URL?
  var sourceFingerprint: String
  var transcriptHash: String
  var archivedOwner: SuggestionRecoveryOwner?
  var instanceID: UUID?
}

struct SuggestionRecoveryClient: Sendable {
  var prepare:
    @Sendable (SuggestionRecoveryOwner, SuggestionRecoveryPreparation) async throws -> URL
  var updateControl:
    @Sendable (SuggestionRecoveryOwner, UUID, SuggestionRecoveryControl, Int) async throws -> Void
  var load: @Sendable (SuggestionRecoveryOwner) async throws -> SuggestionRunCheckpoint?
  var checkpoint:
    @Sendable (SuggestionRecoveryOwner, UUID, Int) async throws -> SuggestionRunCheckpoint
  var discard: @Sendable (SuggestionRecoveryOwner, UUID) async throws -> Void
  var duplicate: @Sendable (SuggestionRecoveryOwner, SuggestionRecoveryOwner) async throws -> Void
  var confirmSaved: @Sendable (SuggestionRecoveryOwner, UUID) async throws -> Void
  var recoverableOrphans: @Sendable (String, String) async throws -> [SuggestionRecoveryOwner]
  var capture:
    @Sendable (SuggestionRecoveryOwner, UUID, Int?) async throws -> SuggestionRecoveryCapture
  var restore: @Sendable (SuggestionRecoveryOwner, Data) async throws -> Void
  var resolveOwner:
    @Sendable (SuggestionRecoveryOwnerResolution) async throws -> SuggestionRecoveryOwner?

  var claimOwner:
    @Sendable (SuggestionRecoveryOwner, UUID) async throws -> SuggestionRecoveryOwner = {
      owner, _ in owner
    }
  var releaseOwner: @Sendable (UUID) async -> Void = { _ in }

  static func store(_ store: SuggestionRecoveryStore) -> Self {
    Self(
      prepare: { try await store.prepare($0, preparation: $1) },
      updateControl: {
        try await store.updateControl($0, runID: $1, control: $2, expectedRevision: $3)
      },
      load: { try await store.load($0) },
      checkpoint: { try await store.capture($0, runID: $1, minimumPythonRevision: $2).checkpoint },
      discard: { try await store.discard($0, runID: $1) },
      duplicate: { try await store.duplicate($0, newOwner: $1) },
      confirmSaved: { try await store.confirmSaved($0, runID: $1) },
      recoverableOrphans: {
        try await store.recoverableOrphans(sourceFingerprint: $0, transcriptHash: $1)
      },
      capture: { try await store.capture($0, runID: $1, minimumPythonRevision: $2) },
      restore: { try await store.restore($0, archive: $1) },
      resolveOwner: {
        try await store.resolveOwner(
          persistedID: $0.persistedID, documentURL: $0.documentURL,
          sourceFingerprint: $0.sourceFingerprint, transcriptHash: $0.transcriptHash,
          archivedOwner: $0.archivedOwner, instanceID: $0.instanceID)
      },
      claimOwner: { try await store.claimOwner($0, instanceID: $1) },
      releaseOwner: { await store.releaseOwner(instanceID: $0) })
  }
}

extension SuggestionRecoveryClient: DependencyKey {
  private static let liveStore = SuggestionRecoveryStore(
    root: URL.applicationSupportDirectory.appending(component: AppDirectories.folderName)
      .appending(component: "SuggestionRecovery"))
  static var liveValue: Self { .store(liveStore) }
  static var testValue: Self {
    Self(
      prepare: { _, _ in throw SuggestionRecoveryError.missingRun },
      updateControl: { _, _, _, _ in throw SuggestionRecoveryError.missingRun },
      load: { _ in nil }, checkpoint: { _, _, _ in throw SuggestionRecoveryError.missingRun },
      discard: { _, _ in throw SuggestionRecoveryError.missingRun },
      duplicate: { _, _ in throw SuggestionRecoveryError.missingRun },
      confirmSaved: { _, _ in throw SuggestionRecoveryError.notSaved },
      recoverableOrphans: { _, _ in [] },
      capture: { _, _, _ in throw SuggestionRecoveryError.missingRun },
      restore: { _, _ in throw SuggestionRecoveryError.missingRun },
      resolveOwner: { request in
        request.persistedID.map {
          SuggestionRecoveryOwner(
            id: $0, documentURL: request.documentURL, sourceFingerprint: request.sourceFingerprint,
            transcriptHash: request.transcriptHash)
        }
      })
  }
}

extension DependencyValues {
  var suggestionRecovery: SuggestionRecoveryClient {
    get { self[SuggestionRecoveryClient.self] }
    set { self[SuggestionRecoveryClient.self] = newValue }
  }
}
