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
    // An empty range can't come from a valid selection; no-op without disturbing
    // any current playback.
    guard frameCount > 0 else { return }
    let myGeneration = prepareToPlay(file: file)
    try engine.start()
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      scheduleSegment(
        cont, file: file, startingFrame: clampedStart, frameCount: frameCount,
        expectedGeneration: myGeneration)
    }
  }

  func stop() {
    let cont = withLock { () -> CheckedContinuation<Void, Never>? in
      generation += 1
      let existing = continuation
      continuation = nil
      return existing
    }
    stopNode()
    cont?.resume()
  }

  private func prepareToPlay(file: AVAudioFile) -> Int {
    let result = withLock { () -> (CheckedContinuation<Void, Never>?, Int) in
      generation += 1
      let existing = continuation
      continuation = nil
      return (existing, generation)
    }
    result.0?.resume()
    stopNode()
    withLock {
      if node.engine == nil { engine.attach(node) }
      engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
    }
    return result.1
  }

  private func scheduleSegment(
    _ cont: CheckedContinuation<Void, Never>, file: AVAudioFile,
    startingFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount,
    expectedGeneration: Int
  ) {
    let installed = withLock { () -> Bool in
      guard generation == expectedGeneration else { return false }
      continuation = cont
      node.scheduleSegment(file, startingFrame: startingFrame, frameCount: frameCount, at: nil) {
        [weak self] in self?.completeSegment(generation: expectedGeneration)
      }
      return true
    }
    guard installed else {
      cont.resume()
      return
    }
    // Recheck under the lock: `stop()` or another `play()` may have advanced
    // `generation` in the gap between installing above and calling `node.play()`
    // here, in which case this segment was already abandoned and must not start.
    let stillCurrent = withLock { generation == expectedGeneration }
    if stillCurrent {
      node.play()
    }
  }

  private func completeSegment(generation completedGeneration: Int) {
    let cont = withLock { () -> CheckedContinuation<Void, Never>? in
      guard generation == completedGeneration else { return nil }
      let existing = continuation
      continuation = nil
      return existing
    }
    guard let cont else { return }
    stopNode()
    cont.resume()
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private func stopNode() {
    node.stop()
    if engine.isRunning { engine.stop() }
  }
}
