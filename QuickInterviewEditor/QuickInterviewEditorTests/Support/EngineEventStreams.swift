import Foundation

@testable import PlayolaInterviewEditor

/// A finished engine stream that replays `events`, then ends (with `error`, if given).
func engineEvents(_ events: [EngineEvent], throwing error: Error? = nil)
  -> AsyncThrowingStream<EngineEvent, Error>
{
  AsyncThrowingStream { continuation in
    for event in events { continuation.yield(event) }
    continuation.finish(throwing: error)
  }
}

/// An engine stream that never completes — holds a model in `.transcribing`.
func neverCompletingEngineEvents() -> AsyncThrowingStream<EngineEvent, Error> {
  AsyncThrowingStream { _ in }
}

/// Writes a small stand-in canonical AIFF (its bytes are never decoded) and returns its URL.
func temporaryCanonicalAudio(bytes: Int, name: String = "qie-canonical") throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(name)-\(UUID().uuidString).aiff")
  try Data(repeating: 0x41, count: bytes).write(to: url)
  return url
}
