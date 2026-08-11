import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor @Suite struct TranscriptionClientTests {
  private nonisolated func engineStream(_ events: [EngineEvent]) -> AsyncThrowingStream<
    EngineEvent, Error
  > {
    AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }

  private func tempBase() -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "qie-tc/\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  private nonisolated func makeAIFF(_ base: URL) -> URL {
    let url = base.appendingPathComponent("engine-\(UUID().uuidString).aiff")
    try? Data("AIFF".utf8).write(to: url)
    return url
  }

  private func drainCompleted(_ stream: AsyncThrowingStream<EngineEvent, Error>) async throws
    -> TranscriptionResult?
  {
    var result: TranscriptionResult?
    for try await event in stream {
      if case .completed(let completedResult) = event { result = completedResult }
    }
    return result
  }

  @Test func missRunsEngineAndStoresResult() async throws {
    let base = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base.appendingPathComponent("cache"))
    let plan = Fixtures.editPlan()
    let engineAIFF = makeAIFF(base)
    let engineCalls = LockIsolated(0)

    let result = try await withDependencies {
      $0.transcriptCache = cache
      $0.engineFingerprint = EngineFingerprintClient(current: { "engine:test" })
      $0.engine.transcribe = { _ in
        engineCalls.withValue { $0 += 1 }
        return self.engineStream([
          .completed(TranscriptionResult(editPlan: plan, canonicalAudioURL: engineAIFF))
        ])
      }
    } operation: {
      try await self.drainCompleted(
        TranscriptionClient.liveValue.transcribe(
          URL(fileURLWithPath: "/clip.wav"), "sha256:abc", .useCache))
    }

    #expect(engineCalls.value == 1)
    // Re-emitted with a cache-owned URL, and the entry is now on disk.
    #expect(result?.canonicalAudioURL != engineAIFF)
    #expect(
      cache.lookup(
        TranscriptionCacheKey.make(
          sourceFingerprint: "sha256:abc", engineFingerprint: "engine:test")!) != nil)
  }

  @Test func hitReturnsCachedResultWithoutRunningEngine() async throws {
    let base = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base.appendingPathComponent("cache"))
    let plan = Fixtures.editPlan()
    let key = TranscriptionCacheKey.make(
      sourceFingerprint: "sha256:abc", engineFingerprint: "engine:test")!
    _ = try cache.store(key, plan, makeAIFF(base))
    let engineCalls = LockIsolated(0)

    let result = try await withDependencies {
      $0.transcriptCache = cache
      $0.engineFingerprint = EngineFingerprintClient(current: { "engine:test" })
      $0.engine.transcribe = { _ in
        engineCalls.withValue { $0 += 1 }
        return self.engineStream([])
      }
    } operation: {
      try await self.drainCompleted(
        TranscriptionClient.liveValue.transcribe(
          URL(fileURLWithPath: "/clip.wav"), "sha256:abc", .useCache))
    }

    #expect(engineCalls.value == 0)  // no subprocess
    expectNoDifference(result?.editPlan, plan)
  }

  @Test func forceFreshRunsEngineEvenWithWarmEntry() async throws {
    let base = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base.appendingPathComponent("cache"))
    let key = TranscriptionCacheKey.make(
      sourceFingerprint: "sha256:abc", engineFingerprint: "engine:test")!
    _ = try cache.store(key, Fixtures.editPlan(), makeAIFF(base))
    let engineCalls = LockIsolated(0)

    _ = try await withDependencies {
      $0.transcriptCache = cache
      $0.engineFingerprint = EngineFingerprintClient(current: { "engine:test" })
      $0.engine.transcribe = { _ in
        engineCalls.withValue { $0 += 1 }
        return self.engineStream([
          .completed(
            TranscriptionResult(
              editPlan: Fixtures.editPlan(), canonicalAudioURL: self.makeAIFF(base)))
        ])
      }
    } operation: {
      try await self.drainCompleted(
        TranscriptionClient.liveValue.transcribe(
          URL(fileURLWithPath: "/clip.wav"), "sha256:abc", .forceFresh))
    }
    #expect(engineCalls.value == 1)
  }

  @Test func nonSha256FingerprintBypassesCache() async throws {
    let base = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base.appendingPathComponent("cache"))
    let engineAIFF = makeAIFF(base)
    let engineCalls = LockIsolated(0)

    let result = try await withDependencies {
      $0.transcriptCache = cache
      $0.engineFingerprint = EngineFingerprintClient(current: { "engine:test" })
      $0.engine.transcribe = { _ in
        engineCalls.withValue { $0 += 1 }
        return self.engineStream([
          .completed(
            TranscriptionResult(editPlan: Fixtures.editPlan(), canonicalAudioURL: engineAIFF))
        ])
      }
    } operation: {
      try await self.drainCompleted(
        TranscriptionClient.liveValue.transcribe(
          URL(fileURLWithPath: "/clip.wav"), "path:/clip.wav", .useCache))
    }
    #expect(engineCalls.value == 1)
    #expect(result?.canonicalAudioURL == engineAIFF)  // engine URL passed through, not stored
    #expect(cache.totalSize() == 0)
  }
}
