import Dependencies
import Foundation
import IssueReporting

enum CachePolicy: Sendable, Equatable {
  case useCache
  case forceFresh
}

/// Cache-aware transcription. Wraps the pure `EngineClient` subprocess boundary with
/// the on-disk `TranscriptCacheClient`, keyed by source + engine fingerprint. A cache
/// hit skips the subprocess entirely; a miss runs the engine and stores the result.
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
  var engineFingerprint: String
}

enum LiveTranscription {
  static func stream(
    source: URL, sourceFingerprint: String, policy: CachePolicy,
    dependencies: LiveTranscriptionDependencies
  ) -> AsyncThrowingStream<EngineEvent, Error> {
    let engine = dependencies.engine
    let cache = dependencies.cache
    let key = TranscriptionCacheKey.make(
      sourceFingerprint: sourceFingerprint, engineFingerprint: dependencies.engineFingerprint)

    // Cache hit → synthesize completion, no subprocess.
    if policy == .useCache, let key, let hit = cache.lookup(key) {
      return AsyncThrowingStream { continuation in
        continuation.yield(
          .completed(
            TranscriptionResult(editPlan: hit.editPlan, canonicalAudioURL: hit.canonicalAudioURL)))
        continuation.finish()
      }
    }

    // Miss / forced / bypass → run the engine; store on completion when we have a key.
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await event in engine.transcribe(source) {
            switch event {
            case .progress:
              continuation.yield(event)
            case .completed(let result):
              // Defaults to the engine's own result; if storing fails, this fallback
              // keeps the session working with the engine's own URL.
              var out = result
              if let key,
                let cached = try? cache.store(key, result.editPlan, result.canonicalAudioURL)
              {
                out = TranscriptionResult(
                  editPlan: cached.editPlan, canonicalAudioURL: cached.canonicalAudioURL)
              }
              continuation.yield(.completed(out))
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
        engine: engine, cache: cache, engineFingerprint: engineFingerprint.current()))
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
