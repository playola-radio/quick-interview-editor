import Dependencies
import Foundation
import IssueReporting

struct EngineClient: Sendable {
  var loadPlan: @Sendable (URL) async throws -> EditPlan
  var transcribe: @Sendable (URL) -> AsyncThrowingStream<EngineEvent, Error>
  var renderSlices: @Sendable (RenderRequest) -> AsyncThrowingStream<RenderEvent, Error>
}

extension EngineClient: DependencyKey {
  static let liveValue = EngineClient(
    loadPlan: { url in try EditPlan.decoded(from: url) },
    transcribe: { url in LiveEngine.transcribe(audio: url) },
    renderSlices: { request in LiveEngine.render(request) }
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
    renderSlices: { _ in
      AsyncThrowingStream { continuation in
        reportIssue("EngineClient.renderSlices called without a test override")
        continuation.finish(throwing: EngineClientError.unimplemented("renderSlices"))
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
    },
    renderSlices: { _ in
      AsyncThrowingStream { continuation in
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
