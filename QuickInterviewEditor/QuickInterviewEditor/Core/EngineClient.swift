import Dependencies
import Foundation
import IssueReporting

struct EngineClient: Sendable {
  var loadPlan: @Sendable (URL) async throws -> EditPlan
  var transcribe: @Sendable (URL) -> AsyncThrowingStream<EngineEvent, Error>
  /// Stamps MARK chunks into slice AIFFs the app already rendered itself. See
  /// `LiveEngine.injectMarkers` for the wire contract with `logic_markers.cli
  /// inject-markers`.
  var injectMarkers: @Sendable ([MarkerInjectionFile]) async throws -> Void
}

extension EngineClient: DependencyKey {
  static let liveValue = EngineClient(
    loadPlan: { url in try EditPlan.decoded(from: url) },
    transcribe: { url in LiveEngine.transcribe(audio: url) },
    injectMarkers: { files in try await LiveEngine.injectMarkers(files) }
  )
}

extension EngineClient: TestDependencyKey {
  static let testValue = EngineClient(
    loadPlan: { _ in
      reportIssue("EngineClient.loadPlan called without a test override")
      throw EngineClientError.unimplemented("loadPlan")
    },
    transcribe: { _ in
      AsyncThrowingStream { continuation in
        reportIssue("EngineClient.transcribe called without a test override")
        continuation.finish(throwing: EngineClientError.unimplemented("transcribe"))
      }
    },
    injectMarkers: { _ in
      reportIssue("EngineClient.injectMarkers called without a test override")
      throw EngineClientError.unimplemented("injectMarkers")
    }
  )

  /// Used automatically by SwiftUI previews; convenient fixture, never in tests.
  static let previewValue = EngineClient(
    loadPlan: { _ in .fixture },
    transcribe: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(
          .completed(
            TranscriptionResult(
              editPlan: .fixture,
              canonicalAudioURL: URL(fileURLWithPath: "/preview/canonical.aiff"))))
        continuation.finish()
      }
    },
    injectMarkers: { _ in }
  )
}

extension DependencyValues {
  var engine: EngineClient {
    get { self[EngineClient.self] }
    set { self[EngineClient.self] = newValue }
  }
}
