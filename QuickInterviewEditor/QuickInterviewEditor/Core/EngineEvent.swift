import Foundation

enum EngineEvent: Equatable, Sendable {
  case progress(EngineProgress)
  case completed(EditPlan)
}

struct EngineProgress: Equatable, Sendable {
  enum Phase: String, Equatable, Sendable {
    case transcribing
    case converting
    case analyzingSilence = "analyzing_silence"
    case writingPlan = "writing_plan"
  }
  var phase: Phase
  var message: String
}

enum EngineClientError: Error, Equatable, LocalizedError {
  case unimplemented(String)
  case engineNotFound(String)
  case engineFailed(String)
  case decodeFailed(String)

  var errorDescription: String? {
    switch self {
    case let .unimplemented(name): return "EngineClient.\(name) was called without a test override."
    case let .engineNotFound(path): return "Transcription engine not found at \(path)."
    case let .engineFailed(message): return "Transcription failed: \(message)"
    case let .decodeFailed(message): return "Could not read the transcription result: \(message)"
    }
  }
}
