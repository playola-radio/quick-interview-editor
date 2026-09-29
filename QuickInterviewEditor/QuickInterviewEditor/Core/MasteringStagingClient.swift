import Dependencies
import Foundation
import IssueReporting

// swiftlint:disable:next inclusive_language
struct MasteringStagingClient: Sendable {
  var makeWorkDirectory: @Sendable () throws -> URL
  var adopt: @Sendable (URL, String) throws -> StagedMasteringArtifact
  var sessionCopy: @Sendable (URL, String) async throws -> StagedMasteringArtifact
  var removeDirectory: @Sendable (URL) -> Void
}

extension MasteringStagingClient: DependencyKey {
  static var liveValue: MasteringStagingClient {
    MasteringStagingClient(
      makeWorkDirectory: { try MasteringStagingStore.makeWorkDirectory() },
      adopt: { try MasteringStagingStore.adopt($0, as: $1) },
      sessionCopy: { source, name in
        try await Task.detached(priority: .userInitiated) {
          try MasteringStagingStore.copy(source, as: name)
        }.value
      },
      removeDirectory: { MasteringStagingStore.removeDirectory($0) })
  }
}

extension MasteringStagingClient: TestDependencyKey {
  static var testValue: MasteringStagingClient {
    MasteringStagingClient(
      makeWorkDirectory: {
        throw EngineClientError.unimplemented("MasteringStagingClient.makeWorkDirectory")
      },
      adopt: { _, _ in throw EngineClientError.unimplemented("MasteringStagingClient.adopt") },
      sessionCopy: { _, _ in
        throw EngineClientError.unimplemented("MasteringStagingClient.sessionCopy")
      },
      removeDirectory: { _ in reportIssue("Unimplemented: MasteringStagingClient.removeDirectory") }
    )
  }
}

extension DependencyValues {
  // swiftlint:disable:next inclusive_language
  var masteringStaging: MasteringStagingClient {
    get { self[MasteringStagingClient.self] }
    set { self[MasteringStagingClient.self] = newValue }
  }
}
