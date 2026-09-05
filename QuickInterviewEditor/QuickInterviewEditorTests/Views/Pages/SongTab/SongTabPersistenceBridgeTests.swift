import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
// `FileStorage.inMemory(fileSystem:)` is `@_spi(Internals)`, mirroring how
// `ProjectStorePersistenceTests` seeds and reads an isolated in-memory sidecar.
@_spi(Internals) import Sharing
import Testing

@testable import PlayolaInterviewEditor

private func stream(_ events: [EngineEvent]) -> AsyncThrowingStream<EngineEvent, Error> {
  AsyncThrowingStream { continuation in
    for event in events { continuation.yield(event) }
    continuation.finish()
  }
}

/// PR 2's sidecar bridge lives on `SongTabModel`: it seeds a freshly built `EditorModel`'s
/// document from the legacy `.projectState` sidecar and installs `onDocumentStateChanged`
/// so every document mutation the editor funnels through `mutateDocument` writes straight
/// back to that same sidecar. Behavior stays identical to PR 1 — only the plumbing moved
/// off the editor and onto the tab.
@MainActor
struct SongTabPersistenceBridgeTests {

  // `/clip.m4a` is unreadable, so `SourceFingerprint` falls back to the standardized path.
  private let fingerprint = "path:/clip.m4a"

  @Test func seedsEditorDocumentFromTheSidecar() async throws {
    let seeded = ProjectState(
      cutSuggestions: [Fixtures.cutSuggestion(id: Fixtures.uuid(1))],
      speakerCountOverride: 2,
      speakerDisplayNames: ["0": "Host"],
      timelineRemovals: [
        TimelineRemoval(
          id: Fixtures.uuid(7), removedRange: 1000..<2000,
          crossfade: Crossfade(lengthSamples: 480, curve: .equalPower))
      ])
    let seededData = try JSONEncoder().encode(seeded)
    let fileSystem = LockIsolated<[URL: Data]>([
      ProjectState.sidecarURL(fingerprint: fingerprint): seededData
    ])
    let plan = Fixtures.editPlan()
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))

    await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
      $0.transcription.transcribe = { _, _, _ in
        stream([.completed(Fixtures.transcriptionResult(plan))])
      }
    } operation: {
      await model.startTranscription()
    }

    let editor = try #require(model.editor)
    expectNoDifference(editor.documentCutSuggestions, seeded.cutSuggestions)
    expectNoDifference(editor.speakerCountOverride, 2)
    expectNoDifference(editor.speakerDisplayNames, ["0": "Host"])
    expectNoDifference(editor.timelineRemovals, seeded.timelineRemovals)
    // The sidecar carries no slices; the editor starts with none.
    expectNoDifference(editor.slices, [])
  }

  @Test func editorDocumentMutationsPersistToTheSidecar() async throws {
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    let fileSystem = LockIsolated<[URL: Data]>([:])
    let plan = Fixtures.editPlan()
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))

    try await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
      $0.transcription.transcribe = { _, _, _ in
        stream([.completed(Fixtures.transcriptionResult(plan))])
      }
    } operation: {
      await model.startTranscription()
      let editor = try #require(model.editor)

      editor.mutateDocument {
        $0.speakerCountOverride = 3
        $0.speakerDisplayNames = ["1": "Guest"]
      }

      let onDisk = try JSONDecoder().decode(ProjectState.self, from: fileSystem.value[url]!)
      expectNoDifference(onDisk.speakerCountOverride, 3)
      expectNoDifference(onDisk.speakerDisplayNames, ["1": "Guest"])
    }
  }

  @Test func unrelatedEditDoesNotPersistInitTimeRemovalCleanup() async throws {
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    // A removal far beyond any plausible source length: the editor drops it at init
    // (validatedRemovals), but the user never edited removals, so the cleanup must NOT be
    // written back — the stale entry stays on disk until a real removal edit rewrites it.
    let staleRemoval = TimelineRemoval(
      id: Fixtures.uuid(7), removedRange: 100_000_000..<200_000_000,
      crossfade: Crossfade(lengthSamples: 480, curve: .equalPower))
    let seeded = ProjectState(timelineRemovals: [staleRemoval])
    let seededData = try JSONEncoder().encode(seeded)
    let fileSystem = LockIsolated<[URL: Data]>([url: seededData])
    let plan = Fixtures.editPlan()
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))

    try await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
      $0.transcription.transcribe = { _, _, _ in
        stream([.completed(Fixtures.transcriptionResult(plan))])
      }
    } operation: {
      await model.startTranscription()
      let editor = try #require(model.editor)
      expectNoDifference(editor.timelineRemovals, [])

      editor.mutateDocument { $0.speakerCountOverride = 3 }

      let onDisk = try JSONDecoder().decode(ProjectState.self, from: fileSystem.value[url]!)
      expectNoDifference(onDisk.speakerCountOverride, 3)
      expectNoDifference(onDisk.timelineRemovals, [staleRemoval])
    }
  }

  @Test func aStaleTabDoesNotClobberFieldsAnotherTabPersisted() async throws {
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    let fileSystem = LockIsolated<[URL: Data]>([:])
    let plan = Fixtures.editPlan()
    // Two tabs on the SAME source share one sidecar but hold independent document snapshots.
    let tabA = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    let tabB = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))

    try await withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
      $0.transcription.transcribe = { _, _, _ in
        stream([.completed(Fixtures.transcriptionResult(plan))])
      }
    } operation: {
      await tabA.startTranscription()
      await tabB.startTranscription()
      let editorA = try #require(tabA.editor)
      let editorB = try #require(tabB.editor)

      // Tab A persists a suggestion.
      let suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1))
      editorA.mutateDocument { $0.cutSuggestions.append(suggestion) }

      // Tab B — whose snapshot predates A's write — makes an UNRELATED speaker edit. It must
      // write only the speaker field, never revert A's suggestion to B's (empty) list.
      editorB.mutateDocument { $0.speakerCountOverride = 3 }

      let onDisk = try JSONDecoder().decode(ProjectState.self, from: fileSystem.value[url]!)
      expectNoDifference(onDisk.cutSuggestions, [suggestion])
      expectNoDifference(onDisk.speakerCountOverride, 3)
    }
  }
}
