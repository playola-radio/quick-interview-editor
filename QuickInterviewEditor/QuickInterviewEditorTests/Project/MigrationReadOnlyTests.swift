import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
// `FileStorage.inMemory(fileSystem:)` is `@_spi(Internals)`, matching the other sidecar tests.
@_spi(Internals) import Sharing
import Testing

@testable import PlayolaInterviewEditor

/// Locks the legacy `.projectState` sidecar as a **read-only migration input** (Task 5.2). The
/// document owns persistence now: editing a loaded-from-file project must never write the sidecar,
/// yet the one-time migration read must still seed a first import of a source that predates the
/// document model.
@MainActor
struct MigrationReadOnlyTests {
  private let importedAt = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func mutatingALoadedFromFileProjectNeverWritesTheLegacySidecar() async throws {
    let fingerprint = "sha256:loaded-project"
    let sidecarURL = ProjectState.sidecarURL(fingerprint: fingerprint)
    let seeded = ProjectState(speakerCountOverride: 2)
    let seededData = try JSONEncoder().encode(seeded)
    let fileSystem = LockIsolated<[URL: Data]>([sidecarURL: seededData])
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(
      file: Fixtures.projectFile(source: Fixtures.projectSource(originalFingerprint: fingerprint)),
      plan: Fixtures.editPlan(), audio: .sessionFile(Fixtures.canonicalAudioURL), sink: sink)

    try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      await model.viewAppeared()
      let editor = try #require(model.editor)
      editor.mutateDocument { $0.speakerCountOverride = 9 }
    }

    // The edit persists through the document sink, never the sidecar.
    expectNoDifference(record.commits.last?.file.content.speakerCountOverride, 9)
    #expect(record.registerChangeCount > 0)
    let onDisk = try #require(fileSystem.value[sidecarURL])
    expectNoDifference(try JSONDecoder().decode(ProjectState.self, from: onDisk), seeded)
  }

  @Test func theReadMigrationStillSeedsAFirstImport() async throws {
    // `/clip.m4a` is unreadable, so `SourceFingerprint` falls back to the standardized path — the
    // same key the legacy sidecar was written under.
    let fingerprint = "path:/clip.m4a"
    let seeded = ProjectState(
      cutSuggestions: [Fixtures.cutSuggestion(id: Fixtures.uuid(1))],
      speakerCountOverride: 3,
      speakerDisplayNames: ["0": "Host"])
    let seededData = try JSONEncoder().encode(seeded)
    let fileSystem = LockIsolated<[URL: Data]>([
      ProjectState.sidecarURL(fingerprint: fingerprint): seededData
    ])
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }

    let editor = try #require(model.editor)
    expectNoDifference(editor.documentCutSuggestions, seeded.cutSuggestions)
    expectNoDifference(editor.speakerCountOverride, 3)
    expectNoDifference(editor.speakerDisplayNames, ["0": "Host"])
  }
}
