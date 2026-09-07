import CustomDump
import Foundation
import Sharing
import Testing

@testable import PlayolaInterviewEditor

struct SuggestionConfigurationClientTests {
  private let fileManager = FileManager.default

  @Test func loadingMissingStorageProvidesSixDefaultsAndPublishes() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    @Shared(.suggestionConfiguration) var published: SuggestionConfiguration?
    let store = SuggestionConfigurationStore(
      fileURL: directory.appending(component: "SuggestionConfiguration.json"))

    let loaded = try await store.load()

    expectNoDifference(loaded, SuggestionDefaults.configuration)
    expectNoDifference(loaded.types.count, 6)
    expectNoDifference(published, loaded)
  }

  @Test func successfulSavePublishesThePersistedConfiguration() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    @Shared(.suggestionConfiguration) var published: SuggestionConfiguration?
    let fileURL = directory.appending(component: "SuggestionConfiguration.json")
    let store = SuggestionConfigurationStore(fileURL: fileURL)
    let original = try await store.load()
    var draft = original
    draft.types[0].name = "Stories"

    let saved = try await store.save(draft, expectedRevision: original.revision)
    let persisted = try JSONDecoder().decode(
      SuggestionConfiguration.self, from: Data(contentsOf: fileURL))

    expectNoDifference(persisted, saved)
    expectNoDifference(published, saved)
  }

  @Test func invalidDraftLeavesStorageAndPublicationUnchanged() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    let fileURL = directory.appending(component: "SuggestionConfiguration.json")
    let store = SuggestionConfigurationStore(fileURL: fileURL)
    let original = try await store.load()
    let saved = try await store.save(original, expectedRevision: original.revision)
    let originalBytes = try Data(contentsOf: fileURL)
    @Shared(.suggestionConfiguration) var published: SuggestionConfiguration? = saved
    var invalid = saved
    invalid.types = []

    await #expect(throws: SuggestionConfigurationStoreError.self) {
      try await store.save(invalid, expectedRevision: saved.revision)
    }

    expectNoDifference(try Data(contentsOf: fileURL), originalBytes)
    expectNoDifference(published, saved)
  }

  @Test func invalidExistingStorageThrowsAndPreservesBytes() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    let fileURL = directory.appending(component: "SuggestionConfiguration.json")
    let missingSchemaVersion = Data(#"{"revision":0,"types":[],"fields":[]}"#.utf8)
    let invalidSchema = try JSONEncoder().encode(
      SuggestionConfiguration(schemaVersion: 2, types: [], fields: []))
    let invalidJSON = Data("not JSON".utf8)

    for bytes in [missingSchemaVersion, invalidSchema, invalidJSON] {
      try bytes.write(to: fileURL)
      @Shared(.suggestionConfiguration) var published: SuggestionConfiguration?
      published = nil
      let store = SuggestionConfigurationStore(fileURL: fileURL)

      await #expect(throws: (any Error).self) {
        try await store.load()
      }

      expectNoDifference(try Data(contentsOf: fileURL), bytes)
      expectNoDifference(published, nil)
    }
  }

  @Test func staleDraftCannotOverwriteTheFirstSave() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    let store = SuggestionConfigurationStore(
      fileURL: directory.appending(component: "SuggestionConfiguration.json"))
    let original = try await store.load()
    var first = original
    first.types[0].name = "Stories"

    let saved = try await store.save(first, expectedRevision: original.revision)

    await #expect(throws: SuggestionConfigurationStoreError.staleDraft) {
      try await store.save(original, expectedRevision: original.revision)
    }
    let reloaded = try await store.load()
    expectNoDifference(reloaded, saved)
  }

  @Test func revisionOverflowLeavesStorageAndPublicationUnchanged() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    let fileURL = directory.appending(component: "SuggestionConfiguration.json")
    var configuration = SuggestionDefaults.configuration
    configuration.revision = .max
    let originalBytes = try JSONEncoder().encode(configuration)
    try originalBytes.write(to: fileURL)
    @Shared(.suggestionConfiguration) var published: SuggestionConfiguration?
    let store = SuggestionConfigurationStore(fileURL: fileURL)
    let loaded = try await store.load()
    var draft = loaded
    draft.revision = 0

    await #expect(throws: SuggestionConfigurationStoreError.revisionOverflow) {
      try await store.save(draft, expectedRevision: loaded.revision)
    }

    expectNoDifference(try Data(contentsOf: fileURL), originalBytes)
    expectNoDifference(published, loaded)
  }

  @Test func writeFailureLeavesStorageAndPublicationUnchanged() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    let fileURL = directory.appending(component: "SuggestionConfiguration.json")
    let seedStore = SuggestionConfigurationStore(fileURL: fileURL)
    let original = try await seedStore.load()
    let saved = try await seedStore.save(original, expectedRevision: original.revision)
    let originalBytes = try Data(contentsOf: fileURL)
    @Shared(.suggestionConfiguration) var published: SuggestionConfiguration? = saved
    let failingStore = SuggestionConfigurationStore(
      fileURL: fileURL,
      write: { _, _ in throw CocoaError(.fileWriteUnknown) })
    var draft = saved
    draft.types[0].name = "Stories"

    await #expect(throws: (any Error).self) {
      try await failingStore.save(draft, expectedRevision: saved.revision)
    }

    expectNoDifference(try Data(contentsOf: fileURL), originalBytes)
    expectNoDifference(published, saved)
  }

  @Test func previewImplementationsAreIsolated() async throws {
    let first = SuggestionConfigurationClient.previewValue
    let second = SuggestionConfigurationClient.previewValue
    let original = try await first.load()
    var draft = original
    draft.types[0].name = "Stories"

    let firstSaved = try await first.save(draft, original.revision)
    let secondLoaded = try await second.load()

    expectNoDifference(firstSaved.types[0].name, "Stories")
    expectNoDifference(secondLoaded, SuggestionDefaults.configuration)
  }

  @Test func testValueReportsAndThrowsWithoutAnOverride() async {
    await withKnownIssue {
      _ = try await SuggestionConfigurationClient.testValue.load()
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = fileManager.temporaryDirectory.appending(
      component: UUID().uuidString, directoryHint: .isDirectory)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
