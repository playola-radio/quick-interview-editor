import Dependencies
import Foundation
import IssueReporting
import Sharing

enum SuggestionConfigurationStoreError: Error, Equatable {
  case staleDraft
  case invalid([String])
  case revisionOverflow
  case unimplemented(String)
}

actor SuggestionConfigurationStore {
  private let fileURL: URL
  private let write: @Sendable (Data, URL) throws -> Void

  @Shared(.suggestionConfiguration) private var publishedConfiguration: SuggestionConfiguration?

  init(fileURL: URL) {
    self.init(
      fileURL: fileURL,
      write: { data, url in
        try data.write(to: url, options: .atomic)
      })
  }

  init(fileURL: URL, write: @escaping @Sendable (Data, URL) throws -> Void) {
    self.fileURL = fileURL
    self.write = write
  }

  func load() async throws -> SuggestionConfiguration {
    let configuration = try loadConfiguration()
    publishedConfiguration = configuration
    return configuration
  }

  func save(
    _ draft: SuggestionConfiguration, expectedRevision: Int
  ) async throws -> SuggestionConfiguration {
    let current = try loadConfiguration()
    let validationMessages = draft.validationMessages()
    guard validationMessages.isEmpty else {
      throw SuggestionConfigurationStoreError.invalid(validationMessages)
    }
    guard current.revision == expectedRevision else {
      throw SuggestionConfigurationStoreError.staleDraft
    }
    let (nextRevision, overflow) = current.revision.addingReportingOverflow(1)
    guard !overflow else {
      throw SuggestionConfigurationStoreError.revisionOverflow
    }

    var saved = draft
    saved.revision = nextRevision
    let data = try JSONEncoder().encode(saved)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try write(data, fileURL)
    publishedConfiguration = saved
    return saved
  }

  private func loadConfiguration() throws -> SuggestionConfiguration {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return SuggestionDefaults.configuration
    }

    let configuration = try JSONDecoder().decode(
      SuggestionConfiguration.self, from: Data(contentsOf: fileURL))
    let validationMessages = configuration.validationMessages()
    guard validationMessages.isEmpty else {
      throw SuggestionConfigurationStoreError.invalid(validationMessages)
    }
    var migrated = SuggestionDefaults.upgradingLegacyIntroGuidance(in: configuration)
    guard migrated != configuration else { return configuration }
    let (revision, overflow) = configuration.revision.addingReportingOverflow(1)
    guard !overflow else { throw SuggestionConfigurationStoreError.revisionOverflow }
    migrated.revision = revision
    try write(JSONEncoder().encode(migrated), fileURL)
    return migrated
  }
}

struct SuggestionConfigurationClient: Sendable {
  var load: @Sendable () async throws -> SuggestionConfiguration
  var save:
    @Sendable (_ draft: SuggestionConfiguration, _ expectedRevision: Int) async throws ->
      SuggestionConfiguration
}

extension SuggestionConfigurationClient: DependencyKey {
  private static let liveStore = SuggestionConfigurationStore(
    fileURL: URL.applicationSupportDirectory
      .appending(component: AppDirectories.folderName, directoryHint: .isDirectory)
      .appending(component: "SuggestionConfiguration.json"))

  static var liveValue: SuggestionConfigurationClient {
    let store = Self.liveStore
    return SuggestionConfigurationClient(
      load: { try await store.load() },
      save: { draft, expectedRevision in
        try await store.save(draft, expectedRevision: expectedRevision)
      })
  }
}

extension SuggestionConfigurationClient: TestDependencyKey {
  static var testValue: SuggestionConfigurationClient {
    SuggestionConfigurationClient(
      load: {
        reportIssue("SuggestionConfigurationClient.load called without a test override")
        throw SuggestionConfigurationStoreError.unimplemented("load")
      },
      save: { _, _ in
        reportIssue("SuggestionConfigurationClient.save called without a test override")
        throw SuggestionConfigurationStoreError.unimplemented("save")
      })
  }

  static var previewValue: SuggestionConfigurationClient { .inMemory() }
}

extension SuggestionConfigurationClient {
  static func inMemory(
    _ initial: SuggestionConfiguration = SuggestionDefaults.configuration
  ) -> SuggestionConfigurationClient {
    let store = InMemorySuggestionConfigurationStore(initial: initial)
    return SuggestionConfigurationClient(
      load: { await store.load() },
      save: { draft, expectedRevision in
        try await store.save(draft, expectedRevision: expectedRevision)
      })
  }
}

extension DependencyValues {
  var suggestionConfiguration: SuggestionConfigurationClient {
    get { self[SuggestionConfigurationClient.self] }
    set { self[SuggestionConfigurationClient.self] = newValue }
  }
}

private actor InMemorySuggestionConfigurationStore {
  private var configuration: SuggestionConfiguration

  init(initial: SuggestionConfiguration) {
    configuration = initial
  }

  func load() -> SuggestionConfiguration {
    configuration
  }

  func save(
    _ draft: SuggestionConfiguration, expectedRevision: Int
  ) throws -> SuggestionConfiguration {
    let validationMessages = draft.validationMessages()
    guard validationMessages.isEmpty else {
      throw SuggestionConfigurationStoreError.invalid(validationMessages)
    }
    guard configuration.revision == expectedRevision else {
      throw SuggestionConfigurationStoreError.staleDraft
    }
    let (nextRevision, overflow) = configuration.revision.addingReportingOverflow(1)
    guard !overflow else {
      throw SuggestionConfigurationStoreError.revisionOverflow
    }
    configuration = draft
    configuration.revision = nextRevision
    return configuration
  }
}
