import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
// `FileStorage.inMemory(fileSystem:)` — which seeds an isolated in-memory file system
// so a test can pre-populate a sidecar and read the bytes back — is `@_spi(Internals)`,
// exactly as swift-sharing's own `FileStorageTests` access it.
@_spi(Internals) import Sharing
import Testing

@testable import QuickInterviewEditor

/// The sidecar is `@Shared(.fileStorage(...))`, which is backed by an in-memory file
/// system in tests. Each test injects its OWN fresh in-memory file system and uses a
/// UNIQUE fingerprint, so nothing bleeds between tests through the shared cache.
struct ProjectStorePersistenceTests {

  @Test func loadsSuggestionsSeededForItsFingerprint() throws {
    let fingerprint = "fp-load"
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    let seeded = ProjectState(cutSuggestions: [
      Fixtures.cutSuggestion(id: Fixtures.uuid(1)),
      Fixtures.cutSuggestion(id: Fixtures.uuid(2)),
    ])
    let seededData = try JSONEncoder().encode(seeded)
    let fileSystem = LockIsolated<[URL: Data]>([url: seededData])

    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      expectNoDifference(state.cutSuggestions, seeded.cutSuggestions)
    }
  }

  @Test func differentFingerprintsAreIsolated() throws {
    let fingerprintA = "fp-a"
    let seeded = ProjectState(cutSuggestions: [Fixtures.cutSuggestion(id: Fixtures.uuid(1))])
    let seededData = try JSONEncoder().encode(seeded)
    let fileSystem = LockIsolated<[URL: Data]>([
      ProjectState.sidecarURL(fingerprint: fingerprintA): seededData
    ])

    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      @Shared(.projectState(fingerprint: fingerprintA)) var stateA = ProjectState()
      @Shared(.projectState(fingerprint: "fp-b")) var stateB = ProjectState()
      expectNoDifference(stateA.cutSuggestions.count, 1)
      expectNoDifference(stateB.cutSuggestions, [])
    }
  }

  /// An engine re-run rewrites `edit-plan.json`; re-decoding a plan must not touch
  /// the Swift-owned sidecar.
  @Test func survivesEngineRerun() throws {
    let fingerprint = "fp-rerun"
    let seeded = ProjectState(cutSuggestions: [Fixtures.cutSuggestion(id: Fixtures.uuid(1))])
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    let seededData = try JSONEncoder().encode(seeded)
    let fileSystem = LockIsolated<[URL: Data]>([url: seededData])

    try withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
      expectNoDifference(state.cutSuggestions.count, 1)

      // The engine re-runs and the app re-decodes a fresh EditPlan…
      _ = Fixtures.editPlan()

      // …the sidecar is untouched.
      expectNoDifference(state.cutSuggestions, seeded.cutSuggestions)
      let onDisk = try JSONDecoder().decode(ProjectState.self, from: fileSystem.value[url]!)
      expectNoDifference(onDisk.cutSuggestions, seeded.cutSuggestions)
    }
  }

  @Test func mutationsPersistToTheSidecarFile() throws {
    let fingerprint = "fp-save"
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    let suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1))
    let fileSystem = LockIsolated<[URL: Data]>([:])

    try withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState(
        cutSuggestions: [suggestion])
      $state.withLock { $0.acceptSuggestion(suggestion.id) }

      let onDisk = try JSONDecoder().decode(ProjectState.self, from: fileSystem.value[url]!)
      expectNoDifference(onDisk.cutSuggestions[id: suggestion.id]?.status, .accepted)
    }
  }
}
