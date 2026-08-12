import Dependencies
import Foundation
import IssueReporting

/// The network side-effect boundary for LLM cut suggestions. Like `EngineClient`, it is a
/// `Sendable` dependency-client struct: `suggestCuts` takes a fully-built request plus the
/// resolved API key and streams progress then a completed set of ranked candidates.
///
/// The `apiKey` is passed as a separate, in-memory argument — never a field of the
/// (Equatable, on-disk-serialized) `CutSuggestRequest` — so the credential can't leak into
/// the request JSON, a snapshot, or a log. The live path injects it only into the child
/// process environment. `nil` means "no key resolved"; callers gate on that before calling.
struct CutSuggestClient: Sendable {
  var suggestCuts:
    @Sendable (_ request: CutSuggestRequest, _ apiKey: String?) -> AsyncThrowingStream<
      CutSuggestEvent, Error
    >
}

/// Everything the cutter needs, addressed by stable IDs rather than raw offsets. The
/// `transcriptHash` and `sourceFingerprint` are stamped onto each produced suggestion's
/// provenance so staleness is detectable after an engine re-run.
struct CutSuggestRequest: Equatable, Sendable {
  var transcriptUnits: [TranscriptUnit]
  var diarization: DiarizationEvidence?
  var productSpecs: [ProductSpec]
  var options: CutSuggestOptions
  var transcriptHash: String
  var sourceFingerprint: String
  /// The canonical sample rate the units' samples are expressed in (the plan rate,
  /// `EditPlan.source.sampleRate`). The Python cutter derives each candidate's
  /// duration from `(endSample - startSample) / sampleRate`, so it must match the
  /// rate the samples were computed at or durations drift.
  var sampleRate: Int
}

/// Streamed progress, then the final ranked candidates. Sample bounds on each candidate
/// are still derived from words downstream, never from the LLM's duration guess.
enum CutSuggestEvent: Equatable, Sendable {
  case progress(String)
  case completed([CutSuggestion])
}

enum CutSuggestClientError: Error, Equatable, LocalizedError {
  /// No override was installed in a test (or the client is a stub) — mirrors
  /// `EngineClientError.unimplemented`.
  case unimplemented(String)
  /// Neither the bundled `cut-suggester-engine` helper nor the dev `.venv` python
  /// was found at the resolved path.
  case helperNotFound(String)
  /// The provider rejected the request for lack of credentials (no API key /
  /// gateway token in the environment). Kept distinct so the UI can prompt for auth.
  case authMissing(String)
  /// The subprocess exited nonzero (provider/network failure, invalid request, a
  /// cache miss in cached-only mode, …). Carries the helper's stderr tail.
  case suggestFailed(String)
  /// The subprocess exited cleanly but produced no usable candidates. Carries
  /// run diagnostics so the UI can explain whether the model returned no clips,
  /// clips were malformed, or all candidates were dropped by duration filters.
  case noSuggestions(String)
  /// The subprocess exited cleanly but its stdout was not the expected suggestion
  /// JSON (non-JSON leaked, or a candidate was missing a required field).
  case decodeFailed(String)

  var errorDescription: String? {
    switch self {
    case .unimplemented(let name):
      return "CutSuggestClient.\(name) has no test override."
    case .helperNotFound(let path):
      return "The cut-suggester helper was not found at \(path)."
    case .authMissing(let detail):
      return "The cut-suggester could not authenticate with the model provider.\n\n\(detail)"
    case .suggestFailed(let detail):
      return "The cut-suggester failed.\n\n\(detail)"
    case .noSuggestions(let detail):
      return "The cut-suggester completed but produced no usable suggestions.\n\n\(detail)"
    case .decodeFailed(let detail):
      return "The cut-suggester returned output that could not be read.\n\n\(detail)"
    }
  }
}

extension CutSuggestClient: DependencyKey {
  /// The live two-stage cutter: shells out to the Python `cut_suggester` (mirroring
  /// `EngineClient.liveValue` → `LiveEngine`), so the validated windowing / classify /
  /// trim / dedupe / rank logic and the regression eval stay a single source of truth.
  static let liveValue = CutSuggestClient(
    suggestCuts: { request, apiKey in LiveCutSuggester.suggestCuts(request, apiKey: apiKey) }
  )
}

extension CutSuggestClient: TestDependencyKey {
  /// Fails loudly if a test reaches the client without overriding it (via
  /// `withDependencies { $0.cutSuggest = … }`), so a forgotten override never passes
  /// against a hidden fixture. Matches `EngineClient.testValue`.
  static let testValue = CutSuggestClient(
    suggestCuts: { _, _ in
      AsyncThrowingStream { continuation in
        reportIssue("CutSuggestClient.suggestCuts called without a test override")
        continuation.finish(throwing: CutSuggestClientError.unimplemented("suggestCuts"))
      }
    }
  )

  /// Used automatically by SwiftUI previews: a progress tick then an empty completion, so a
  /// preview exercises the streaming path without a network call.
  static let previewValue = CutSuggestClient(
    suggestCuts: { _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.progress("Analyzing transcript…"))
        continuation.yield(.completed([]))
        continuation.finish()
      }
    }
  )
}

extension DependencyValues {
  var cutSuggest: CutSuggestClient {
    get { self[CutSuggestClient.self] }
    set { self[CutSuggestClient.self] = newValue }
  }
}
