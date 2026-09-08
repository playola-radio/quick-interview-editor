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
    // swiftlint:disable:next implicit_optional_initialization
    @Shared(.suggestionConfiguration) var published: SuggestionConfiguration? = nil
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
    // swiftlint:disable:next implicit_optional_initialization
    @Shared(.suggestionConfiguration) var published: SuggestionConfiguration? = nil
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
      // swiftlint:disable:next implicit_optional_initialization
      @Shared(.suggestionConfiguration) var published: SuggestionConfiguration? = nil
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
    // swiftlint:disable:next implicit_optional_initialization
    @Shared(.suggestionConfiguration) var published: SuggestionConfiguration? = nil
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
    var saved = SuggestionDefaults.configuration
    saved.revision = 1
    let originalBytes = try JSONEncoder().encode(saved)
    try originalBytes.write(to: fileURL)
    var publicationSeed = saved
    publicationSeed.types[0].name = "Published separately"
    @Shared(.suggestionConfiguration) var published: SuggestionConfiguration? = publicationSeed
    let failingStore = SuggestionConfigurationStore(
      fileURL: fileURL,
      write: { _, _ in throw CocoaError(.fileWriteUnknown) })
    var draft = saved
    draft.types[0].name = "Stories"

    await #expect(throws: (any Error).self) {
      try await failingStore.save(draft, expectedRevision: saved.revision)
    }

    expectNoDifference(try Data(contentsOf: fileURL), originalBytes)
    expectNoDifference(published, publicationSeed)
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
    var caught: (any Error)?
    await withKnownIssue {
      do {
        _ = try await SuggestionConfigurationClient.testValue.load()
      } catch {
        caught = error
      }
    }
    expectNoDifference(caught as? SuggestionConfigurationStoreError, .unimplemented("load"))
  }

  @Test func loadingLegacyDefaultsUpgradesOnceAndRejectsOldDrafts() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    let fileURL = directory.appending(component: "SuggestionConfiguration.json")
    let legacy = try legacyConfiguration()
    try JSONEncoder().encode(legacy).write(to: fileURL)
    // swiftlint:disable:next implicit_optional_initialization
    @Shared(.suggestionConfiguration) var published: SuggestionConfiguration? = nil
    let store = SuggestionConfigurationStore(fileURL: fileURL)
    var expected = SuggestionDefaults.configuration
    expected.revision = 8

    let loaded = try await store.load()

    expectNoDifference(loaded, expected)
    expectNoDifference(published, expected)
    let reloaded = try await store.load()
    expectNoDifference(reloaded, expected)
    expectNoDifference(
      try JSONDecoder().decode(SuggestionConfiguration.self, from: Data(contentsOf: fileURL)),
      expected)
    await #expect(throws: SuggestionConfigurationStoreError.staleDraft) {
      try await store.save(legacy, expectedRevision: 7)
    }
  }

  @Test func upgradingLegacyGuidancePreservesEachEditedProperty() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    let fileURL = directory.appending(component: "SuggestionConfiguration.json")
    var legacy = try legacyConfiguration()
    legacy.types[0].name = "Artist Commentary"
    legacy.types[0].guidelines = "Only find explicit handoffs, as I requested."
    legacy.types[0].template = [NamingComponent(kind: .literal, value: "My Intro")]
    legacy.fields[0].instructions = "My custom song extraction instructions."
    try JSONEncoder().encode(legacy).write(to: fileURL)
    var expected = legacy
    expected.revision = 8
    expected.fields[1].instructions = SuggestionDefaults.fields[1].instructions

    let store = SuggestionConfigurationStore(fileURL: fileURL)
    let reloaded = try await store.load()
    expectNoDifference(reloaded, expected)
  }

  @Test func upgradingLegacyGuidanceDoesNotRestoreDeletedDefaults() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    let fileURL = directory.appending(component: "SuggestionConfiguration.json")
    var legacy = try legacyConfiguration()
    legacy.types.removeFirst()
    legacy.fields.removeFirst(2)
    try JSONEncoder().encode(legacy).write(to: fileURL)
    let originalBytes = try Data(contentsOf: fileURL)

    let store = SuggestionConfigurationStore(fileURL: fileURL)
    let loaded = try await store.load()
    expectNoDifference(loaded, legacy)
    expectNoDifference(try Data(contentsOf: fileURL), originalBytes)
  }

  @Test func editedArtistInstructionsSurviveOtherDefaultUpgrades() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    let fileURL = directory.appending(component: "SuggestionConfiguration.json")
    var legacy = try legacyConfiguration()
    legacy.fields[1].instructions = "Extract my chosen artist."
    try JSONEncoder().encode(legacy).write(to: fileURL)
    var expected = SuggestionDefaults.configuration
    expected.revision = 8
    expected.fields[1].instructions = legacy.fields[1].instructions

    let store = SuggestionConfigurationStore(fileURL: fileURL)
    let reloaded = try await store.load()
    expectNoDifference(reloaded, expected)
  }

  @Test func legacyUpgradeWriteFailurePreservesBytesAndPublication() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    let fileURL = directory.appending(component: "SuggestionConfiguration.json")
    let legacy = try legacyConfiguration()
    let bytes = try JSONEncoder().encode(legacy)
    try bytes.write(to: fileURL)
    @Shared(.suggestionConfiguration) var published: SuggestionConfiguration? = legacy
    let store = SuggestionConfigurationStore(
      fileURL: fileURL, write: { _, _ in throw CocoaError(.fileWriteUnknown) })

    await #expect(throws: (any Error).self) { try await store.load() }

    expectNoDifference(try Data(contentsOf: fileURL), bytes)
    expectNoDifference(published, legacy)
  }

  @Test func legacyUpgradeOverflowPreservesBytesAndPublication() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    let fileURL = directory.appending(component: "SuggestionConfiguration.json")
    var legacy = try legacyConfiguration()
    legacy.revision = .max
    let bytes = try JSONEncoder().encode(legacy)
    try bytes.write(to: fileURL)
    @Shared(.suggestionConfiguration) var published: SuggestionConfiguration? = legacy
    let store = SuggestionConfigurationStore(fileURL: fileURL)

    await #expect(throws: SuggestionConfigurationStoreError.revisionOverflow) {
      try await store.load()
    }

    expectNoDifference(try Data(contentsOf: fileURL), bytes)
    expectNoDifference(published, legacy)
  }

  @Test func freshSearchUsesBroadIntrosAndHistoricalOptionsRemainUnchanged() {
    expectNoDifference(CutSuggestOptions.freshConfigured.promptVersion, "configured-v4")
    expectNoDifference(
      CutSuggestOptions(promptVersion: "configured-v2").promptVersion, "configured-v2")
  }

  private func legacyConfiguration() throws -> SuggestionConfiguration {
    let url = try #require(
      Bundle(for: ConfigurationMigrationFixtureBundle.self).url(
        forResource: "suggestion-contract-v2", withExtension: "json"))
    struct Contract: Decodable { var configuration: SuggestionConfiguration }
    var configuration = try JSONDecoder().decode(
      Contract.self, from: Data(contentsOf: url)
    ).configuration
    configuration.revision = 7
    return configuration
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = fileManager.temporaryDirectory.appending(
      component: UUID().uuidString, directoryHint: .isDirectory)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

private final class ConfigurationMigrationFixtureBundle {}
