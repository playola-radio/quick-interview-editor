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
  case renderFailed(String)
  case renderDecodeFailed(String)

  var errorDescription: String? {
    switch self {
    case .unimplemented(let name): return "EngineClient.\(name) was called without a test override."
    case .engineNotFound(let path): return "Transcription engine not found at \(path)."
    case .engineFailed(let message): return "Transcription failed: \(message)"
    case .decodeFailed(let message): return "Could not read the transcription result: \(message)"
    case .renderFailed(let message): return "Export failed: \(message)"
    case .renderDecodeFailed(let message): return "Could not read the export result: \(message)"
    }
  }
}
