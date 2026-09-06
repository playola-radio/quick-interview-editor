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

  @Test func aRetiredEditorCannotClobberDocumentContentAfterReTranscribe() async throws {
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(
      file: Fixtures.projectFile(
        source: Fixtures.projectSource(
          originalFingerprint: "sha256:original-mp3", canonicalFingerprint: "sha256:canonical")),
      plan: Fixtures.editPlan(), audio: .sessionFile(Fixtures.canonicalAudioURL), sink: sink)

    try await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.canonicalAudioStore.remove = { _ in }
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.viewAppeared()
      let retired = try #require(model.editor)
      await model.reimportIgnoringCacheTapped()
      let current = try #require(model.editor)
      #expect(retired !== current)

      // A buffered async completion on the retired editor (e.g. a late cut-suggestion) fires its
      // document callback after the re-transcribe committed. It must be ignored.
      let commitsBefore = record.commits.count
      retired.mutateDocument { $0.speakerCountOverride = 99 }
      expectNoDifference(record.commits.count, commitsBefore)
      #expect(record.commits.last?.file.content.speakerCountOverride != 99)
    }
  }

  @Test func aCanonicalFingerprintThatIsntAContentHashFailsTheRunAndCleansUp() async throws {
    // A file the fingerprinter can stat (byteCount) but cannot read (mode 000) forces the
    // `path:` fallback — the one way `canonicalFingerprint` could be a non-sha256 value.
    let unreadable = try temporaryCanonicalAudio(bytes: 1024)
    let fm = FileManager.default
    try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
    defer {
      try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
      try? fm.removeItem(at: unreadable)
    }
    let removed = LockIsolated<[URL]>([])
    let (sink, record) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.canonicalAudioStore.remove = { url in removed.withValue { $0.append(url) } }
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(canonicalAudioURL: unreadable))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }

    expectNoDifference(model.phase, .failed(model.uncomputableFingerprintMessage))
    expectNoDifference(record.commits, [])
    expectNoDifference(removed.value, [unreadable])
  }

  @Test func retryAfterAFailedBundledReTranscribeReRunsTheReTranscribe() async throws {
    let calls = LockIsolated(0)
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(
      file: Fixtures.projectFile(
        source: Fixtures.projectSource(
          originalFingerprint: "sha256:original", canonicalFingerprint: "sha256:canonical")),
      plan: Fixtures.editPlan(), audio: .sessionFile(Fixtures.canonicalAudioURL), sink: sink)

    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(importedAt)
      $0.canonicalAudioStore.remove = { _ in }
      $0.transcription.transcribe = { _, _, _ in
        let attempt = calls.withValue {
          $0 += 1
          return $0
        }
        return attempt == 1
          ? engineEvents([], throwing: EngineClientError.engineFailed("flaky"))
          : engineEvents([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.viewAppeared()
      await model.reimportIgnoringCacheTapped()
      #expect(model.showsError)
      await model.retryTapped()
    }

    // Retry re-ran the bundled re-transcribe (a second transcribe call) rather than silently
    // reverting to the loaded state via hydrate().
    expectNoDifference(calls.value, 2)
    expectNoDifference(model.phase, .loaded)
  }
}
