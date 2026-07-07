import AVFoundation
import Dependencies
import Foundation
import IssueReporting

struct AudioPlayerClient: Sendable {
  /// Plays url from range.lowerBound to range.upperBound (samples) and returns when playback
  /// finishes or stop() is called.
  var play: @Sendable (URL, Range<Int>, Int) async throws -> Void
  var stop: @Sendable () async -> Void
  /// A stream of playback positions in PLAN samples while a slice plays, terminated by an
  /// `isPlaying: false` tick on stop/finish. Additive to `play`/`stop` so the waveform
  /// playhead gets real positions without disturbing the tuned slice-playback path.
  var positions: @Sendable () -> AsyncStream<PlaybackPosition>
}

/// A playback position sampled from the audio node, expressed in PLAN samples so it lands
/// in the same coordinate system as the waveform (the native→plan conversion is internal).
struct PlaybackPosition: Sendable, Equatable {
  var sample: Int
  var isPlaying: Bool
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
    stop: { reportIssue("AudioPlayerClient.stop called without a test override") },
    positions: { AsyncStream { $0.finish() } }
  )

  static let previewValue = AudioPlayerClient(
    play: { _, _, _ in }, stop: {}, positions: { AsyncStream { $0.finish() } })
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
      stop: { await box.stop() },
      positions: {
        AsyncStream { continuation in
          // Register on the actor; the builder closure runs synchronously, so hop.
          let id = UUID()
          Task { await box.addPositionContinuation(id: id, continuation) }
          continuation.onTermination = { _ in
            Task { await box.removePositionContinuation(id: id) }
          }
        }
      }
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

  /// Position-stream plumbing. `startPlanSample` + `playRatio` convert the node's native
  /// render frames back to plan samples; `tickTask` polls ~30 Hz while a slice plays.
  /// Positions broadcast to every registered subscriber (one per open editor) so the tab
  /// that started playback always gets ticks, even if another tab subscribed later; each
  /// subscriber decides for itself whether to show them.
  private var positionContinuations: [UUID: AsyncStream<PlaybackPosition>.Continuation] = [:]
  /// IDs whose stream terminated before their (unordered) registration task landed, so a
  /// late `add` doesn't store a dead continuation forever.
  private var terminatedContinuationIDs: Set<UUID> = []
  private var tickTask: Task<Void, Never>?
  private var startPlanSample = 0
  private var playRatio = 1.0

  func addPositionContinuation(
    id: UUID, _ continuation: AsyncStream<PlaybackPosition>.Continuation
  ) {
    if terminatedContinuationIDs.remove(id) != nil { return }  // termination beat us here
    positionContinuations[id] = continuation
  }

  func removePositionContinuation(id: UUID) {
    if positionContinuations.removeValue(forKey: id) == nil {
      terminatedContinuationIDs.insert(id)  // removal beat registration
    }
  }

  private func broadcast(_ position: PlaybackPosition) {
    for continuation in positionContinuations.values { continuation.yield(position) }
  }

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
    startPlanSample = max(0, range.lowerBound)
    playRatio = ratio
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
    ) { @Sendable [weak self] _ in
      // `@Sendable` so the completion isn't inferred as actor-isolated (it runs on
      // an AVFoundation render thread); it captures only the actor ref + an Int and
      // hops back onto the actor via `await`.
      Task { await self?.complete(generation: myGeneration) }
    }
    node.play()
    startTicking()
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
    stopTicking()
    stopNode()
    waiter?.resume()
  }

  private func complete(generation completedGeneration: Int) {
    guard generation == completedGeneration, let waiter = continuation else { return }
    continuation = nil
    stopTicking()
    stopNode()
    waiter.resume()
  }

  /// Polls the node's render position ~30 Hz and yields plan-sample positions.
  private func startTicking() {
    tickTask?.cancel()
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.emitPosition()
        try? await Task.sleep(for: .milliseconds(33))
      }
    }
  }

  /// Stops polling and emits a final `isPlaying: false` tick so the playhead clears.
  private func stopTicking() {
    tickTask?.cancel()
    tickTask = nil
    broadcast(PlaybackPosition(sample: startPlanSample, isPlaying: false))
  }

  /// Reads the node's played-frame count, maps it back to a plan sample, and yields it.
  /// The playhead follows the audio the user actually hears (native frames → plan via the
  /// same ratio playback uses); it is exact when the source is already at the plan rate
  /// (the common case). On a resampled source it can differ from the waveform pyramid by
  /// resampler rounding — a cosmetic read-only-playhead limitation, closed once a single
  /// canonical AIFF backs both (roadmap decision 4).
  private func emitPosition() {
    guard node.isPlaying, let nodeTime = node.lastRenderTime,
      let playerTime = node.playerTime(forNodeTime: nodeTime)
    else { return }
    let framesPlayed = max(0, playerTime.sampleTime)
    let planSample = startPlanSample + Int(Double(framesPlayed) / max(playRatio, .ulpOfOne))
    broadcast(PlaybackPosition(sample: planSample, isPlaying: true))
  }

  private func stopNode() {
    node.stop()
    if engine.isRunning { engine.stop() }
  }
}
