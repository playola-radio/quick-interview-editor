import Dependencies
import Foundation
import IssueReporting

/// The network side-effect boundary for LLM cut suggestions. Like `EngineClient`, it is a
/// `Sendable` dependency-client struct: `suggestCuts` takes a fully-built request and
/// streams progress then a completed set of ranked candidates. The live two-stage LLM
/// implementation lands in PR 5; this PR ships the contract, a stub `liveValue`, and
/// fixtures, so the model and its tests run with no network, no subprocess, and no sleeps.
struct CutSuggestClient: Sendable {
  var suggestCuts: @Sendable (CutSuggestRequest) -> AsyncThrowingStream<CutSuggestEvent, Error>
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
}

/// Streamed progress, then the final ranked candidates. Sample bounds on each candidate
/// are still derived from words downstream, never from the LLM's duration guess.
enum CutSuggestEvent: Equatable, Sendable {
  case progress(String)
  case completed([CutSuggestion])
}

enum CutSuggestClientError: Error, Equatable, LocalizedError {
  case unimplemented(String)

  var errorDescription: String? {
    switch self {
    case .unimplemented(let name):
      return "CutSuggestClient.\(name) has no live implementation yet — it lands in PR 5."
    }
  }
}

extension CutSuggestClient: DependencyKey {
  /// No live implementation yet: the two-stage network cutter is PR 5. Mirrors
  /// `EngineClient`'s missing-override pattern — report the gap and finish the stream with
  /// an `unimplemented` error rather than silently doing nothing.
  static let liveValue = CutSuggestClient(
    suggestCuts: { _ in
      AsyncThrowingStream { continuation in
        reportIssue("CutSuggestClient.suggestCuts has no live implementation yet (PR 5).")
        continuation.finish(throwing: CutSuggestClientError.unimplemented("suggestCuts"))
      }
    }
  )
}

extension CutSuggestClient: TestDependencyKey {
  /// Fails loudly if a test reaches the client without overriding it (via
  /// `withDependencies { $0.cutSuggest = … }`), so a forgotten override never passes
  /// against a hidden fixture. Matches `EngineClient.testValue`.
  static let testValue = CutSuggestClient(
    suggestCuts: { _ in
      AsyncThrowingStream { continuation in
        reportIssue("CutSuggestClient.suggestCuts called without a test override")
        continuation.finish(throwing: CutSuggestClientError.unimplemented("suggestCuts"))
      }
    }
  )

  /// Used automatically by SwiftUI previews: a progress tick then an empty completion, so a
  /// preview exercises the streaming path without a network call.
  static let previewValue = CutSuggestClient(
    suggestCuts: { _ in
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
