import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import PlayolaInterviewEditor

/// Re-transcribe identity (spec A8, PR 5): import records a content fingerprint of the bundled
/// canonical AIFF, and a re-transcribe from a saved project keys its cache on that
/// `canonicalFingerprint` — never the original MP3's — so a Versions-restored or copied `.pie`
/// never collides with the original import's entry. The original source identity is preserved.
@MainActor
struct ReTranscribeIdentityTests {
  private let importedAt = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func importRecordsAContentFingerprintOfTheCanonicalAudio() async throws {
    let canonical = try temporaryCanonicalAudio(bytes: 2048)
    defer { try? FileManager.default.removeItem(at: canonical) }
    let expected = SourceFingerprint.compute(for: canonical)
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(canonicalAudioURL: canonical))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }

    let commit = try #require(record.commits.first)
    #expect(commit.file.source.canonicalFingerprint.hasPrefix("sha256:"))
    expectNoDifference(commit.file.source.canonicalFingerprint, expected)
    expectNoDifference(commit.file.source.canonicalByteCount, 2048)
  }

  @Test func reTranscribeFromASavedProjectKeysOnTheCanonicalFingerprint() async throws {
    let canonicalFingerprint = "sha256:canonical-bytes"
    let originalFingerprint = "sha256:original-mp3"
    let captured = LockIsolated<[(fingerprint: String, policy: CachePolicy)]>([])
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(
      file: Fixtures.projectFile(
        source: Fixtures.projectSource(
          originalFingerprint: originalFingerprint, canonicalFingerprint: canonicalFingerprint)),
      plan: Fixtures.editPlan(), audio: .sessionFile(Fixtures.canonicalAudioURL), sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.canonicalAudioStore.remove = { _ in }
      $0.transcription.transcribe = { _, fingerprint, policy in
        captured.withValue { $0.append((fingerprint, policy)) }
        return engineEvents([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.viewAppeared()
      #expect(model.canReimport)
      await model.reimportIgnoringCacheTapped()
    }

    expectNoDifference(captured.value.map(\.fingerprint), [canonicalFingerprint])
    expectNoDifference(captured.value.map(\.policy), [.forceFresh])
    #expect(canonicalFingerprint != originalFingerprint)
  }

  @Test func reTranscribeFromASavedProjectPreservesTheOriginalSourceIdentity() async throws {
    let canonical = try temporaryCanonicalAudio(bytes: 4096)
    defer { try? FileManager.default.removeItem(at: canonical) }
    let source = Fixtures.projectSource(
      originalFileName: "interview.mp3", originalPath: "/Users/host/interview.mp3",
      originalFingerprint: "sha256:original-mp3", canonicalFingerprint: "sha256:canonical-bytes",
      canonicalByteCount: 1)
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(
      file: Fixtures.projectFile(source: source),
      plan: Fixtures.editPlan(), audio: .sessionFile(Fixtures.canonicalAudioURL), sink: sink)

    try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.canonicalAudioStore.remove = { _ in }
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([
          .completed(
            Fixtures.transcriptionResult(Fixtures.editPlan(), canonicalAudioURL: canonical))
        ])
      }
    } operation: {
      await model.viewAppeared()
      let before = try #require(model.editor)
      before.mutateDocument { $0.speakerCountOverride = 5 }

      await model.reimportIgnoringCacheTapped()
      let after = try #require(model.editor)
      #expect(before !== after)
      // The re-transcribe keeps the user's edits (same words → no re-key).
      expectNoDifference(after.speakerCountOverride, 5)
    }

    let commit = try #require(record.commits.last)
    // Original source identity is preserved; only the canonical fields refresh.
    expectNoDifference(commit.file.source.originalFileName, "interview.mp3")
    expectNoDifference(commit.file.source.originalPath, "/Users/host/interview.mp3")
    expectNoDifference(commit.file.source.originalFingerprint, "sha256:original-mp3")
    expectNoDifference(
      commit.file.source.canonicalFingerprint, SourceFingerprint.compute(for: canonical))
    expectNoDifference(commit.file.source.canonicalByteCount, 4096)
    expectNoDifference(commit.file.content.speakerCountOverride, 5)
  }
}
