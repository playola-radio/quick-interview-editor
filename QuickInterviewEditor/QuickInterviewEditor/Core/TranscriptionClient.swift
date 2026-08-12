import Dependencies
import Foundation
import IssueReporting

enum CachePolicy: Sendable, Equatable {
  case useCache
  case forceFresh
}

/// Cache-aware transcription. Wraps the pure `EngineClient` subprocess boundary with
/// the on-disk `TranscriptCacheClient`, keyed by source + engine fingerprint. A cache
/// hit skips the subprocess entirely; a miss runs the engine and writes the result
/// through to the cache.
///
/// The editor always receives a **session-owned** canonical AIFF (a `CanonicalAudioStore`
/// copy), never a cache-owned file: on a hit the cached AIFF is copied into the session
/// store; on a miss the engine's own session AIFF is used and a copy is written through
/// to the cache. That way clearing or force-refreshing the cache can never pull the AIFF
/// out from under an open editor. All cache work (fingerprint resolution, lookup, copy,
/// store) runs inside the returned stream's task, off the (Main-actor) import path.
struct TranscriptionClient: Sendable {
  var transcribe:
    @Sendable (_ source: URL, _ sourceFingerprint: String, _ policy: CachePolicy)
      -> AsyncThrowingStream<EngineEvent, Error>
}

/// The engine + cache collaborators `LiveTranscription.stream` needs, bundled into one
/// value so the function stays under the project's function-parameter-count limit.
struct LiveTranscriptionDependencies: Sendable {
  var engine: EngineClient
  var cache: TranscriptCacheClient
  /// Resolved lazily inside the stream task so the (potentially blocking) engine hash
  /// never runs on the caller's Main actor.
  var engineFingerprint: @Sendable () -> String
}

enum LiveTranscription {
  static func stream(
    source: URL, sourceFingerprint: String, policy: CachePolicy,
    dependencies: LiveTranscriptionDependencies
  ) -> AsyncThrowingStream<EngineEvent, Error> {
    let engine = dependencies.engine
    let cache = dependencies.cache
    let resolveEngineFingerprint = dependencies.engineFingerprint

    // Everything below runs inside the stream's task (this function is nonisolated), so
    // fingerprint resolution and cache I/O stay off the Main-actor import path.
    return AsyncThrowingStream { continuation in
      let task = Task {
        let key = TranscriptionCacheKey.make(
          sourceFingerprint: sourceFingerprint, engineFingerprint: resolveEngineFingerprint())

        // Cache hit → hand the editor a SESSION-owned copy of the cached AIFF, so
        // clearing or force-refreshing the cache can't delete the file it's using.
        if policy == .useCache, let key, let hit = cache.lookup(key) {
          let sessionAudio =
            (try? CanonicalAudioStore.store(planAIFF: hit.canonicalAudioURL))
            ?? hit.canonicalAudioURL
          continuation.yield(
            .completed(
              TranscriptionResult(editPlan: hit.editPlan, canonicalAudioURL: sessionAudio)))
          continuation.finish()
          return
        }

        // Miss / forced / bypass → run the engine. Write the result THROUGH to the cache
        // (a copy), but hand the editor the engine's own session AIFF — the editor never
        // holds a cache-owned URL. A failed store just skips caching; the session works.
        do {
          for try await event in engine.transcribe(source) {
            switch event {
            case .progress:
              continuation.yield(event)
            case .completed(let result):
              if let key {
                _ = try? cache.store(key, result.editPlan, result.canonicalAudioURL)
              }
              continuation.yield(.completed(result))
            }
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

extension TranscriptionClient: DependencyKey {
  static let liveValue = TranscriptionClient(transcribe: { source, fingerprint, policy in
    @Dependency(\.engine) var engine
    @Dependency(\.transcriptCache) var cache
    @Dependency(\.engineFingerprint) var engineFingerprint
    return LiveTranscription.stream(
      source: source, sourceFingerprint: fingerprint, policy: policy,
      dependencies: LiveTranscriptionDependencies(
        engine: engine, cache: cache, engineFingerprint: engineFingerprint.current))
  })
}

extension TranscriptionClient: TestDependencyKey {
  static let testValue = TranscriptionClient(transcribe: { _, _, _ in
    AsyncThrowingStream { continuation in
      reportIssue("TranscriptionClient.transcribe called without a test override")
      continuation.finish(throwing: EngineClientError.unimplemented("transcribe"))
    }
  })

  static let previewValue = TranscriptionClient(transcribe: { _, _, _ in
    AsyncThrowingStream { continuation in
      continuation.yield(
        .completed(
          TranscriptionResult(
            editPlan: .fixture,
            canonicalAudioURL: URL(fileURLWithPath: "/preview/canonical.aiff"))))
      continuation.finish()
    }
  })
}

extension DependencyValues {
  var transcription: TranscriptionClient {
    get { self[TranscriptionClient.self] }
    set { self[TranscriptionClient.self] = newValue }
  }
}
