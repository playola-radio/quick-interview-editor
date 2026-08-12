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

  private nonisolated func throwingEngineStream(_ error: Error) -> AsyncThrowingStream<
    EngineEvent, Error
  > {
    AsyncThrowingStream { continuation in
      continuation.finish(throwing: error)
    }
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

  private func drainAll(_ stream: AsyncThrowingStream<EngineEvent, Error>) async throws
    -> [EngineEvent]
  {
    var events: [EngineEvent] = []
    for try await event in stream { events.append(event) }
    return events
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
    // Editor keeps the engine's own session URL; the result is written through to the cache.
    #expect(result?.canonicalAudioURL == engineAIFF)
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

  @Test func progressEventsForwardDuringMiss() async throws {
    let base = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base.appendingPathComponent("cache"))
    let plan = Fixtures.editPlan()
    let engineAIFF = makeAIFF(base)
    let progress = EngineProgress(phase: .transcribing, message: "Transcribing…")

    let events = try await withDependencies {
      $0.transcriptCache = cache
      $0.engineFingerprint = EngineFingerprintClient(current: { "engine:test" })
      $0.engine.transcribe = { _ in
        self.engineStream([
          .progress(progress),
          .completed(TranscriptionResult(editPlan: plan, canonicalAudioURL: engineAIFF)),
        ])
      }
    } operation: {
      try await self.drainAll(
        TranscriptionClient.liveValue.transcribe(
          URL(fileURLWithPath: "/clip.wav"), "sha256:progress", .useCache))
    }

    let messages = events.compactMap { event -> String? in
      if case .progress(let progress) = event { return progress.message }
      return nil
    }
    expectNoDifference(messages, [progress.message])
    #expect(
      events.contains {
        if case .completed = $0 { return true }
        return false
      })
  }

  @Test func storeFailureFallsBackToEngineURL() async throws {
    struct StoreError: Error {}
    let base = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient(
      lookup: { _ in nil },
      store: { _, _, _ in throw StoreError() },
      clear: {},
      totalSize: { 0 })
    let plan = Fixtures.editPlan()
    let engineAIFF = makeAIFF(base)

    let result = try await withDependencies {
      $0.transcriptCache = cache
      $0.engineFingerprint = EngineFingerprintClient(current: { "engine:test" })
      $0.engine.transcribe = { _ in
        self.engineStream([
          .completed(TranscriptionResult(editPlan: plan, canonicalAudioURL: engineAIFF))
        ])
      }
    } operation: {
      try await self.drainCompleted(
        TranscriptionClient.liveValue.transcribe(
          URL(fileURLWithPath: "/clip.wav"), "sha256:storefail", .useCache))
    }

    #expect(result?.canonicalAudioURL == engineAIFF)  // fallback: engine's own URL, not a cache URL
    expectNoDifference(result?.editPlan, plan)
  }

  @Test func engineErrorPropagates() async throws {
    let base = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base.appendingPathComponent("cache"))

    await withDependencies {
      $0.transcriptCache = cache
      $0.engineFingerprint = EngineFingerprintClient(current: { "engine:test" })
      $0.engine.transcribe = { _ in
        self.throwingEngineStream(EngineClientError.engineFailed("boom"))
      }
    } operation: {
      await #expect(throws: EngineClientError.self) {
        try await self.drainCompleted(
          TranscriptionClient.liveValue.transcribe(
            URL(fileURLWithPath: "/clip.wav"), "sha256:enginefail", .useCache))
      }
    }
  }

  @Test func engineCancellationFinishesQuietlyWithoutCompleted() async throws {
    let base = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base.appendingPathComponent("cache"))

    let events = try await withDependencies {
      $0.transcriptCache = cache
      $0.engineFingerprint = EngineFingerprintClient(current: { "engine:test" })
      $0.engine.transcribe = { _ in
        self.throwingEngineStream(CancellationError())
      }
    } operation: {
      try await self.drainAll(
        TranscriptionClient.liveValue.transcribe(
          URL(fileURLWithPath: "/clip.wav"), "sha256:cancel", .useCache))
    }

    #expect(events.isEmpty)
  }
}
