import AVFoundation
import Dependencies
import Foundation
import IssueReporting

struct AudioPlayerClient: Sendable {
  /// Plays url from range.lowerBound to range.upperBound (samples) and returns when playback
  /// finishes or stop() is called.
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
      play: { url, range, sampleRate in
        try await box.play(url: url, range: range, planSampleRate: sampleRate)
      },
      stop: { await box.stop() }
    )
  }
}

private final class LivePlayerBox: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  /// Generation counter guards against a `stop()` landing in the gap between
  /// `engine.start()` (which must run outside the lock) and the continuation
  /// being installed: if the generation changed in that gap, scheduling is
  /// abandoned instead of playing on a stopped engine or hanging forever.
  private var generation = 0

  /// Returns when the scheduled segment finishes playing, or when `stop()` is called.
  func play(url: URL, range: Range<Int>, planSampleRate: Int) async throws {
    let file = try AVAudioFile(forReading: url)
    let nativeRate = file.processingFormat.sampleRate
    let ratio = nativeRate / Double(max(1, planSampleRate))
    let startFrame = AVAudioFramePosition((Double(max(0, range.lowerBound)) * ratio).rounded())
    let endFrameRaw = AVAudioFramePosition((Double(max(0, range.upperBound)) * ratio).rounded())
    let clampedStart = min(startFrame, file.length)
    let clampedEnd = min(endFrameRaw, file.length)
    let frameCount = AVAudioFrameCount(max(0, clampedEnd - clampedStart))
    guard frameCount > 0 else {
      stop()
      return
    }
    let myGeneration = prepareToPlay(file: file)
    try engine.start()
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      scheduleSegment(
        cont, file: file, startingFrame: clampedStart, frameCount: frameCount,
        expectedGeneration: myGeneration)
    }
  }

  func stop() {
    withLock {
      generation += 1
      stopNodeLocked()
      resumeLocked()
    }
  }

  private func prepareToPlay(file: AVAudioFile) -> Int {
    withLock {
      generation += 1
      resumeLocked()
      stopNodeLocked()
      if node.engine == nil { engine.attach(node) }
      engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
      return generation
    }
  }

  private func scheduleSegment(
    _ cont: CheckedContinuation<Void, Never>, file: AVAudioFile,
    startingFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount,
    expectedGeneration: Int
  ) {
    withLock {
      guard generation == expectedGeneration else {
        cont.resume()
        return
      }
      continuation = cont
      node.scheduleSegment(file, startingFrame: startingFrame, frameCount: frameCount, at: nil) {
        [weak self] in self?.completeSegment(generation: expectedGeneration)
      }
      node.play()
    }
  }

  private func completeSegment(generation completedGeneration: Int) {
    withLock {
      guard generation == completedGeneration else { return }
      stopNodeLocked()
      resumeLocked()
    }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private func resumeLocked() {
    let cont = continuation
    continuation = nil
    cont?.resume()
  }

  private func stopNodeLocked() {
    node.stop()
    if engine.isRunning { engine.stop() }
  }
}
