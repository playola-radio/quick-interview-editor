import Dependencies
import Foundation
import IssueReporting

struct EngineClient: Sendable {
  var loadPlan: @Sendable (URL) async throws -> EditPlan
  var transcribe: @Sendable (URL) -> AsyncThrowingStream<EngineEvent, Error>
}

extension EngineClient: DependencyKey {
  static let liveValue = EngineClient(
    loadPlan: { url in try EditPlan.decoded(from: url) },
    transcribe: { url in EngineClient.liveTranscribe(audio: url) }  // Task 5
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
    }
  )

  /// Used automatically by SwiftUI previews; convenient fixture, never in tests.
  static let previewValue = EngineClient(
    loadPlan: { _ in .fixture },
    transcribe: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.completed(.fixture))
        continuation.finish()
      }
    }
  )
}

extension DependencyValues {
  var engine: EngineClient {
    get { self[EngineClient.self] }
    set { self[EngineClient.self] = newValue }
  }
}

extension EngineClient {
  static func liveTranscribe(audio: URL) -> AsyncThrowingStream<EngineEvent, Error> {
    AsyncThrowingStream { $0.finish(throwing: EngineClientError.engineNotFound("live engine not implemented yet")) }
  }
}
