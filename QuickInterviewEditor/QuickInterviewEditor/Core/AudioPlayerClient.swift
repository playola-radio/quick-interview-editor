import AVFoundation
import Dependencies
import Foundation
import IssueReporting

/// Identifies one continuous playback so a stale/superseded tick can never be mistaken for
/// the current one. A fresh id is minted per `play`.
struct PlaybackSessionID: Hashable, Sendable {
  var rawValue: UUID
  init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

struct AudioPlayerClient: Sendable {
  /// Plays url from range.lowerBound to range.upperBound (samples) and returns when playback
  /// finishes or `stop`/a superseding `play` is called. `session` tags this playback's ticks.
  var play: @Sendable (URL, Range<Int>, Int, PlaybackSessionID) async throws -> Void
  /// Pauses `session` if it is the current playback, freezing the node in place; returns the
  /// exact resting plan sample (nil if `session` is not current). Does not end the `play` call.
  var pause: @Sendable (PlaybackSessionID) async -> Int?
  /// Resumes `session` if it is the current paused playback; otherwise no-op.
  var resume: @Sendable (PlaybackSessionID) async -> Void
  /// Stops the current playback if `session` is nil or matches it; otherwise no-op.
  var stop: @Sendable (PlaybackSessionID?) async -> Void
  /// A stream of playback positions in PLAN samples while a slice plays, terminated by an
  /// `isPlaying: false` tick on stop/finish. Additive to `play`/`stop` so the waveform
  /// playhead gets real positions without disturbing the tuned slice-playback path.
  var positions: @Sendable () -> AsyncStream<PlaybackPosition>
}

/// A playback position sampled from the audio node, expressed in PLAN samples so it lands
/// in the same coordinate system as the waveform (the native→plan conversion is internal).
struct PlaybackPosition: Sendable, Equatable {
  var sessionID: PlaybackSessionID
  var sample: Int
  var isPlaying: Bool
}

extension AudioPlayerClient: DependencyKey {
  static let liveValue = AudioPlayerClient.live()
}

extension AudioPlayerClient: TestDependencyKey {
  static let testValue = AudioPlayerClient(
    play: { _, _, _, _ in
      reportIssue("AudioPlayerClient.play called without a test override")
      throw EngineClientError.unimplemented("AudioPlayerClient.play")
    },
    pause: { _ in
      reportIssue("AudioPlayerClient.pause called without a test override")
      return nil
    },
    resume: { _ in reportIssue("AudioPlayerClient.resume called without a test override") },
    stop: { _ in reportIssue("AudioPlayerClient.stop called without a test override") },
    positions: { AsyncStream { $0.finish() } }
  )

  static let previewValue = AudioPlayerClient(
    play: { _, _, _, _ in }, pause: { _ in nil }, resume: { _ in },
    stop: { _ in }, positions: { AsyncStream { $0.finish() } })
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
      play: { url, range, sampleRate, session in
        try await box.play(url: url, range: range, planSampleRate: sampleRate, session: session)
      },
      pause: { session in await box.pause(session: session) },
      resume: { session in await box.resume(session: session) },
      stop: { session in await box.stop(session: session) },
      positions: {
        // Only the latest playhead position matters; drop stale ticks rather than let a
        // lagging consumer accumulate a backlog.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
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
  /// The session of the current play (nil when stopped). Tags every tick and gates
  /// `pause`/`resume`/`stop` so a stale session's call is a no-op.
  private var currentSession: PlaybackSessionID?

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
  func play(
    url: URL, range: Range<Int>, planSampleRate: Int, session: PlaybackSessionID
  ) async throws {
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

    // Tear down any current playback without a stop tick: playing slice B directly while
    // A plays keeps `playingSliceID` set, so a `false` tick here would briefly flash this
    // tab's playhead to nil before B's first position arrives. The new ticking task emits
    // shortly.
    supersede(broadcastStop: false)
    currentSession = session
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

  func stop(session: PlaybackSessionID?) {
    guard let session else {
      supersede()  // nil = stop whatever is playing
      return
    }
    guard currentSession == session else { return }
    supersede()
  }

  /// Freezes the node in place and returns the exact plan sample it stopped at. No
  /// `isPlaying: false` broadcast — the playhead must stay where paused. Does not resume
  /// the suspended `play` waiter, so the `play` call stays in flight until resume/stop.
  func pause(session: PlaybackSessionID) -> Int? {
    guard currentSession == session, node.isPlaying else { return nil }
    // Pause the CURRENT session unconditionally; never leave audio running because the
    // exact render time isn't available yet. `lastRenderTime`/`playerTime` are nil in the
    // brief window after `play()` before the first render cycle — fall back to the range
    // start there so an early Pause still stops and freezes at a valid sample.
    let planSample: Int
    if let nodeTime = node.lastRenderTime,
      let playerTime = node.playerTime(forNodeTime: nodeTime)
    {
      let framesPlayed = max(0, playerTime.sampleTime)
      planSample = startPlanSample + Int(Double(framesPlayed) / max(playRatio, .ulpOfOne))
    } else {
      planSample = startPlanSample
    }
    stopTicking(broadcastStop: false)  // stop polling; keep session + node position
    node.pause()  // pauses without discarding the scheduled segment
    return planSample
  }

  /// Resumes a paused session: restart the node and the tick loop. No-op if `session`
  /// isn't current or the node is already playing.
  func resume(session: PlaybackSessionID) {
    guard currentSession == session, !node.isPlaying else { return }
    // An interruption/device-change can stop the engine while the session stays current;
    // restart it before `node.play()`. If the restart fails, surface it and stay paused
    // rather than fake a silent resume — the caller can retry or stop.
    if !engine.isRunning {
      do {
        try engine.start()
      } catch {
        reportIssue(error)
        return
      }
    }
    node.play()
    startTicking()
  }

  /// Invalidate the current segment: bump the generation, resume the waiter, and
  /// stop the engine — all on the actor, so it can't race the render thread. Pass
  /// `broadcastStop: false` when a new segment starts immediately after (a slice switch),
  /// so the playhead isn't flashed to nil between the two.
  private func supersede(broadcastStop: Bool = true) {
    generation += 1
    let waiter = continuation
    continuation = nil
    stopTicking(broadcastStop: broadcastStop)
    stopNode()
    currentSession = nil
    waiter?.resume()
  }

  private func complete(generation completedGeneration: Int) {
    guard generation == completedGeneration, let waiter = continuation else { return }
    continuation = nil
    stopTicking()
    stopNode()
    currentSession = nil
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

  /// Stops polling and (on a real stop/completion) emits a final `isPlaying: false` tick
  /// so the playhead clears. Skipped on a slice switch, where a new segment follows.
  private func stopTicking(broadcastStop: Bool = true) {
    tickTask?.cancel()
    tickTask = nil
    if broadcastStop, let session = currentSession {
      broadcast(PlaybackPosition(sessionID: session, sample: startPlanSample, isPlaying: false))
    }
  }

  /// Reads the node's played-frame count, maps it back to a plan sample, and yields it.
  /// The playhead follows the audio the user actually hears (native frames → plan via the
  /// same ratio playback uses); it is exact when the source is already at the plan rate
  /// (the common case). On a resampled source it can differ from the waveform pyramid by
  /// resampler rounding — a cosmetic read-only-playhead limitation, closed once a single
  /// canonical AIFF backs both (roadmap decision 4).
  private func emitPosition() {
    guard let session = currentSession,
      node.isPlaying, let nodeTime = node.lastRenderTime,
      let playerTime = node.playerTime(forNodeTime: nodeTime)
    else { return }
    let framesPlayed = max(0, playerTime.sampleTime)
    let planSample = startPlanSample + Int(Double(framesPlayed) / max(playRatio, .ulpOfOne))
    broadcast(PlaybackPosition(sessionID: session, sample: planSample, isPlaying: true))
  }

  private func stopNode() {
    node.stop()
    if engine.isRunning { engine.stop() }
  }
}
