import AVFoundation
import Dependencies
import Foundation
import IssueReporting

struct AudioPlayerClient: Sendable {
  /// Plays `url` from `range.lowerBound` to `range.upperBound` (samples) and
  /// returns once playback has started (does not block until the range ends).
  var play: @Sendable (URL, Range<Int>, Int) async throws -> Void
  var stop: @Sendable () async -> Void
}

extension AudioPlayerClient: DependencyKey {
  static let liveValue = AudioPlayerClient.live()
}

extension AudioPlayerClient: TestDependencyKey {
  static let testValue = AudioPlayerClient(
    play: { _, _, _ in
      reportIssue("AudioPlayerClient.play called without a test override")
      throw EngineClientError.unimplemented("AudioPlayerClient.play")
    },
    stop: { reportIssue("AudioPlayerClient.stop called without a test override") }
  )

  static let previewValue = AudioPlayerClient(play: { _, _, _ in }, stop: {})
}

extension DependencyValues {
  var audioPlayer: AudioPlayerClient {
    get { self[AudioPlayerClient.self] }
    set { self[AudioPlayerClient.self] = newValue }
  }
}

extension AudioPlayerClient {
  /// AVFoundation range playback via a shared engine + player node. Not unit
  /// tested (real audio hardware); covered by manual verification.
  static func live() -> AudioPlayerClient {
    let box = LivePlayerBox()
    return AudioPlayerClient(
      play: { url, range, _ in try box.play(url: url, range: range) },
      stop: { box.stop() }
    )
  }
}

private final class LivePlayerBox: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let lock = NSLock()

  func play(url: URL, range: Range<Int>) throws {
    lock.lock()
    defer { lock.unlock() }
    stopLocked()
    let file = try AVAudioFile(forReading: url)
    let start = AVAudioFramePosition(max(0, range.lowerBound))
    let frames = AVAudioFrameCount(max(0, range.upperBound - range.lowerBound))
    guard frames > 0 else { return }
    if node.engine == nil { engine.attach(node) }
    engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
    if !engine.isRunning { try engine.start() }
    node.scheduleSegment(file, startingFrame: start, frameCount: frames, at: nil)
    node.play()
  }

  func stop() {
    lock.lock()
    defer { lock.unlock() }
    stopLocked()
  }

  private func stopLocked() {
    node.stop()
    if engine.isRunning { engine.stop() }
  }
}
