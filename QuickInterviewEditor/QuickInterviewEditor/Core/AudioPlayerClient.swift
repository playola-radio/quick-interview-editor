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

/// `AVAudioEngine`/`AVAudioPlayerNode` are not thread-safe, so every engine
/// operation is confined to this actor. The segment-completion callback fires on
/// an AVFoundation render thread, so it hops back onto the actor (`Task { await
/// … }`) before touching any state or the engine — which is what a play/stop
/// race previously trapped on. `generation` lets a superseding `play()` or a
/// `stop()` invalidate an in-flight segment's completion.
private actor LivePlayerBox {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private var continuation: CheckedContinuation<Void, Never>?
  private var generation = 0

  /// Returns when the scheduled segment finishes playing, or when `stop()` or
  /// another `play()` supersedes it.
  func play(url: URL, range: Range<Int>, planSampleRate: Int) async throws {
    let file = try AVAudioFile(forReading: url)
    let nativeRate = file.processingFormat.sampleRate
    let ratio = nativeRate / Double(max(1, planSampleRate))
    let startFrame = AVAudioFramePosition((Double(max(0, range.lowerBound)) * ratio).rounded())
    let endFrame = AVAudioFramePosition((Double(max(0, range.upperBound)) * ratio).rounded())
    let clampedStart = min(startFrame, file.length)
    let clampedEnd = min(endFrame, file.length)
    let frameCount = AVAudioFrameCount(max(0, clampedEnd - clampedStart))
    // An empty range can't come from a valid selection; no-op without disturbing
    // any current playback.
    guard frameCount > 0 else { return }

    supersede()  // resume + tear down any current playback
    if node.engine == nil { engine.attach(node) }
    engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
    try engine.start()

    let myGeneration = generation
    // `.dataPlayedBack` fires when the audio has actually been played through the
    // output, NOT when the file segment has merely been read/consumed. The player
    // pre-buffers ~1-2s ahead, so the default (consumed) callback fires early and
    // `stopNode()` would truncate the pre-buffered tail — cutting off the last
    // words of the slice.
    node.scheduleSegment(
      file, startingFrame: clampedStart, frameCount: frameCount, at: nil,
      completionCallbackType: .dataPlayedBack
    ) { [weak self] _ in
      Task { await self?.complete(generation: myGeneration) }
    }
    node.play()
    // Suspend until the segment completes or is superseded. Schedule/play happen
    // before this (not inside the continuation body) so the `sending` body
    // captures only the actor's own `continuation`, never the non-Sendable
    // `file`. The completion callback hops back onto this actor, so it cannot run
    // `complete` until we suspend here and free the actor — by which point
    // `continuation` is already set.
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      continuation = cont
    }
  }

  func stop() {
    supersede()
  }

  /// Invalidate the current segment: bump the generation, resume the waiter, and
  /// stop the engine — all on the actor, so it can't race the render thread.
  private func supersede() {
    generation += 1
    let waiter = continuation
    continuation = nil
    stopNode()
    waiter?.resume()
  }

  private func complete(generation completedGeneration: Int) {
    guard generation == completedGeneration, let waiter = continuation else { return }
    continuation = nil
    stopNode()
    waiter.resume()
  }

  private func stopNode() {
    node.stop()
    if engine.isRunning { engine.stop() }
  }
}
