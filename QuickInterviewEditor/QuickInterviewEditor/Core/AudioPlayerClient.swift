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

/// Why a `play` call returned. `finished` = the segment played to its end (the caller may
/// rest the cursor at the range end); `stopped` = a `stop` on this session ended it; `superseded`
/// = a newer `play` (this tab or, crucially, another tab sharing the one player) took over. Only
/// `finished` should move the resting cursor to the range end — a superseded background tab must
/// leave its cursor where it was, not jump it to the end.
enum PlaybackEnd: Sendable, Equatable {
  case finished
  case stopped
  case superseded
}

struct AudioPlayerClient: Sendable {
  /// Plays url from range.lowerBound to range.upperBound (samples) at `rate` (pitch-preserving
  /// speed, 1.0 = normal) and returns how it ended when playback finishes or `stop`/a superseding
  /// `play` is called. Passing the rate here (rather than a separate call) keeps it applied
  /// atomically with the start, so no suspension point sits between it and `session` becoming
  /// current. `session` tags this playback's ticks.
  var play: @Sendable (URL, Range<Int>, Int, Double, PlaybackSessionID) async throws -> PlaybackEnd
  /// Pauses `session` if it is the current playback, freezing the node in place; returns the
  /// exact resting plan sample (nil if `session` is not current). Does not end the `play` call.
  var pause: @Sendable (PlaybackSessionID) async -> Int?
  /// Resumes `session` if it is the current paused playback. Returns whether it is now playing,
  /// so a caller can keep its UI honest when a restart fails (e.g. the engine stopped mid-pause).
  var resume: @Sendable (PlaybackSessionID) async -> Bool
  /// Stops the current playback if `session` is nil or matches it; otherwise no-op.
  var stop: @Sendable (PlaybackSessionID?) async -> Void
  /// Sets the pitch-preserving playback speed (e.g. 0.5–3.0). Applies live to any current
  /// playback and is remembered for the next `play`. Speed is global to the one shared player,
  /// so it takes no session. Does not disturb the plan-sample position math: the player node's
  /// `sampleTime` still counts input frames, so the playhead stays aligned at any rate.
  var setRate: @Sendable (Double) async -> Void
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
    play: { _, _, _, _, _ -> PlaybackEnd in
      reportIssue("AudioPlayerClient.play called without a test override")
      throw EngineClientError.unimplemented("AudioPlayerClient.play")
    },
    pause: { _ in
      reportIssue("AudioPlayerClient.pause called without a test override")
      return nil
    },
    resume: { _ in
      reportIssue("AudioPlayerClient.resume called without a test override")
      return false
    },
    stop: { _ in reportIssue("AudioPlayerClient.stop called without a test override") },
    // Additive and side-effect-free in tests (no audio graph), so it's a benign no-op rather than
    // a reported issue: the transport primes the rate on every `play`, and most tests don't care.
    setRate: { _ in },
    positions: { AsyncStream { $0.finish() } }
  )

  static let previewValue = AudioPlayerClient(
    play: { _, _, _, _, _ in .finished }, pause: { _ in nil }, resume: { _ in true },
    stop: { _ in }, setRate: { _ in }, positions: { AsyncStream { $0.finish() } })
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
      play: { url, range, sampleRate, rate, session in
        try await box.play(
          url: url, range: range, planSampleRate: sampleRate, rate: rate, session: session)
      },
      pause: { session in await box.pause(session: session) },
      resume: { session in await box.resume(session: session) },
      stop: { session in await box.stop(session: session) },
      setRate: { rate in await box.setRate(rate) },
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
  /// Pitch-preserving speed control, spliced between the player node and the mixer
  /// (`node -> timePitch -> mainMixer`). `rate` 1.0 is normal speed; the app clamps to 0.5–3.0.
  private let timePitch = AVAudioUnitTimePitch()
  /// The current speed, remembered across plays so a `play` starts at the last-set rate and a
  /// paused/resumed session keeps it. Applied to `timePitch.rate` at graph setup and on `setRate`.
  private var currentRate: Double = 1.0
  private var continuation: CheckedContinuation<PlaybackEnd, Never>?
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
  /// Set only while an *edited-timeline* playlist plays (`playEdited`); maps the node's
  /// played input frames straight to EDITED samples. When set, position reporting uses it
  /// instead of the single-offset `startPlanSample`/`playRatio` math the slice path uses.
  private var editedFrameTimeline: PlaylistFrameTimeline?
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
    url: URL, range: Range<Int>, planSampleRate: Int, rate: Double, session: PlaybackSessionID
  ) async throws -> PlaybackEnd {
    currentRate = Self.clampedRate(rate)
    let file = try AVAudioFile(forReading: url)
    let nativeRate = file.processingFormat.sampleRate
    let ratio = nativeRate / Double(max(1, planSampleRate))
    let startFrame = AVAudioFramePosition((Double(max(0, range.lowerBound)) * ratio).rounded())
    let endFrame = AVAudioFramePosition((Double(max(0, range.upperBound)) * ratio).rounded())
    let clampedStart = min(startFrame, file.length)
    let clampedEnd = min(endFrame, file.length)
    let frameCount = AVAudioFrameCount(max(0, clampedEnd - clampedStart))
    // An empty range can't come from a valid selection; no-op without disturbing any current
    // playback. This can also be reached when the canonical file is shorter than the plan's declared
    // duration (the range clamps to empty against `file.length`). Report `.stopped`, not `.finished`,
    // so a caller never rests its cursor at the range end for audio that never played.
    guard frameCount > 0 else { return .stopped }

    // Tear down any current playback without a stop tick: starting playback B directly while
    // A plays keeps the transport owner set, so a `false` tick here would briefly flash this
    // tab's playhead before B's first position arrives. The new ticking task emits shortly.
    supersede(broadcastStop: false)
    currentSession = session
    startPlanSample = max(0, range.lowerBound)
    playRatio = ratio
    if node.engine == nil { engine.attach(node) }
    if timePitch.engine == nil { engine.attach(timePitch) }
    // Rebuild the fixed graph node -> timePitch -> mixer with the file's format. Reconnecting here
    // is safe because `supersede` above stopped the engine; the units aren't reconnected live.
    engine.connect(node, to: timePitch, format: file.processingFormat)
    engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
    // Set the speed before starting so the first buffers already play at the intended rate.
    timePitch.rate = Float(currentRate)
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
    return await withCheckedContinuation { (cont: CheckedContinuation<PlaybackEnd, Never>) in
      continuation = cont
    }
  }

  /// SPIKE (PR2): plays an edited-timeline `plan` as one gapless stream on the shared node —
  /// kept-segment interiors scheduled straight from `file`, seam crossfades pre-rendered into PCM
  /// buffers and blended by `CrossfadeRenderer` — proving the playlist scheduler + edited-position
  /// bookkeeping before the transport migrates to edited coordinates. Positions report EDITED
  /// samples (`editedFrameTimeline`). Not exposed on `AudioPlayerClient` yet (PR3 wires the
  /// transport); exercised by manual verification only.
  func playEdited(
    url: URL, plan: AudioEditRenderPlan, planSampleRate: Int, rate: Double,
    session: PlaybackSessionID
  ) async throws -> PlaybackEnd {
    currentRate = Self.clampedRate(rate)
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let ratio = format.sampleRate / Double(max(1, planSampleRate))

    // A plan with no items (e.g. a seek past the edited end) can't play; no-op without disturbing
    // any current playback, mirroring the empty-range guard in `play`.
    guard !plan.items.isEmpty else { return .stopped }

    supersede(broadcastStop: false)
    currentSession = session
    startPlanSample = 0
    playRatio = ratio
    editedFrameTimeline = PlaylistFrameTimeline(plan: plan, ratio: ratio)

    if node.engine == nil { engine.attach(node) }
    if timePitch.engine == nil { engine.attach(timePitch) }
    engine.connect(node, to: timePitch, format: format)
    engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    timePitch.rate = Float(currentRate)
    try engine.start()

    let myGeneration = generation
    // Only the final scheduled item carries the completion callback; the queued items ahead of it
    // play back-to-back with `at: nil`, so the stream is gapless and completes exactly once.
    let onLast: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = {
      @Sendable [weak self] _ in Task { await self?.complete(generation: myGeneration) }
    }
    let lastIndex = plan.items.count - 1
    for (index, item) in plan.items.enumerated() {
      let completion = index == lastIndex ? onLast : nil
      switch item {
      case .segment(let source, _):
        let startFrame = AVAudioFramePosition((Double(source.lowerBound) * ratio).rounded())
        let frameCount = AVAudioFrameCount(max(0, (Double(source.count) * ratio).rounded()))
        guard frameCount > 0 else { continue }
        node.scheduleSegment(
          file, startingFrame: min(startFrame, file.length), frameCount: frameCount, at: nil,
          completionCallbackType: .dataPlayedBack, completionHandler: completion)
      case .seam(_, let leftTail, let rightHead, _, _, let fadeOffset):
        guard
          let buffer = try seamBuffer(
            file: file, leftTail: leftTail, rightHead: rightHead,
            fadeOffset: fadeOffset, ratio: ratio)
        else { continue }
        node.scheduleBuffer(
          buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack,
          completionHandler: completion)
      }
    }
    node.play()
    startTicking()
    return await withCheckedContinuation { (cont: CheckedContinuation<PlaybackEnd, Never>) in
      continuation = cont
    }
  }

  /// Pre-renders one seam's crossfade into a PCM buffer: reads the outgoing tail and incoming head
  /// from `file`, blends them with equal-power gains (the spike's fixed curve — PR5 threads the
  /// per-seam curve through the plan), and packs the result into `file.processingFormat`.
  /// `fadeOffset` (plan samples skipped by a seek into the crossfade) keeps the gains continuing
  /// the original fade instead of restarting it. The overlap length is `leftTail.count` (the
  /// plan's seam `length` always equals its trimmed tail/head range counts).
  private func seamBuffer(
    file: AVAudioFile, leftTail: Range<Int>, rightHead: Range<Int>, fadeOffset: Int,
    ratio: Double
  ) throws -> AVAudioPCMBuffer? {
    let nativeCount = AVAudioFrameCount(max(0, (Double(leftTail.count) * ratio).rounded()))
    guard nativeCount > 0 else { return nil }
    let leftStart = AVAudioFramePosition((Double(leftTail.lowerBound) * ratio).rounded())
    let rightStart = AVAudioFramePosition((Double(rightHead.lowerBound) * ratio).rounded())
    let out = try readFloats(file: file, startFrame: leftStart, frameCount: nativeCount)
    let incoming = try readFloats(file: file, startFrame: rightStart, frameCount: nativeCount)
    let nativeFadeOffset = Int((Double(fadeOffset) * ratio).rounded())
    let blended = CrossfadeRenderer.blend(
      out: out, incoming: incoming, curve: .equalPower,
      fadeOffset: nativeFadeOffset, fadeTotal: nativeFadeOffset + Int(nativeCount))
    guard
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: nativeCount),
      let channels = buffer.floatChannelData
    else { return nil }
    buffer.frameLength = nativeCount
    let channelCount = Int(file.processingFormat.channelCount)
    for channel in 0..<channelCount {
      let source = blended[min(channel, blended.count - 1)]
      let destination = channels[channel]
      for frame in 0..<Int(nativeCount) {
        destination[frame] = frame < source.count ? source[frame] : 0
      }
    }
    return buffer
  }

  /// Reads `frameCount` frames from `startFrame` into per-channel float arrays, zero-padding any
  /// frames past EOF so the caller always gets exactly `frameCount` samples per channel.
  private func readFloats(
    file: AVAudioFile, startFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount
  ) throws -> [[Float]] {
    let channelCount = Int(file.processingFormat.channelCount)
    var result = Array(
      repeating: [Float](repeating: 0, count: Int(frameCount)), count: channelCount)
    let clampedStart = max(0, min(startFrame, file.length))
    let available = AVAudioFrameCount(max(0, min(Int64(frameCount), file.length - clampedStart)))
    guard available > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: available)
    else { return result }
    file.framePosition = clampedStart
    try file.read(into: buffer, frameCount: available)
    guard let channels = buffer.floatChannelData else { return result }
    let read = Int(buffer.frameLength)
    for channel in 0..<channelCount {
      let source = channels[channel]
      for frame in 0..<read { result[channel][frame] = source[frame] }
    }
    return result
  }

  func stop(session: PlaybackSessionID?) {
    guard let session else {
      supersede(reason: .stopped)  // nil = stop whatever is playing
      return
    }
    guard currentSession == session else { return }
    supersede(reason: .stopped)
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
    let restingSample: Int
    if let nodeTime = node.lastRenderTime,
      let playerTime = node.playerTime(forNodeTime: nodeTime)
    {
      restingSample = positionSample(forFramesPlayed: Int(max(0, playerTime.sampleTime)))
    } else {
      restingSample = positionSample(forFramesPlayed: 0)
    }
    stopTicking(broadcastStop: false)  // stop polling; keep session + node position
    node.pause()  // pauses without discarding the scheduled segment
    return restingSample
  }

  /// Resumes a paused session: restart the node and the tick loop. Returns whether the session
  /// is now playing — false if `session` isn't current, or true if it was already playing.
  func resume(session: PlaybackSessionID) -> Bool {
    guard currentSession == session else { return false }
    if node.isPlaying { return true }
    // An interruption/device-change can stop the engine while the session stays current;
    // restart it before `node.play()`. If the restart fails, surface it and stay paused
    // rather than fake a silent resume — the caller keeps its UI paused and can retry or stop.
    if !engine.isRunning {
      do {
        try engine.start()
      } catch {
        reportIssue(error)
        return false
      }
    }
    node.play()
    startTicking()
    return true
  }

  /// Sets the pitch-preserving speed, live and for the next play. `timePitch.rate` can be changed
  /// while the node plays; windowed DSP may briefly smear the audio but the position math is
  /// untouched (the player node's `sampleTime` counts INPUT frames, so the plan-sample mapping in
  /// `emitPosition`/`pause` stays correct at any rate).
  func setRate(_ rate: Double) {
    currentRate = Self.clampedRate(rate)
    timePitch.rate = Float(currentRate)
  }

  /// Clamps a requested speed to a hardware-safe range as a defensive backstop; the app's 0.5–3.0
  /// UI range is the real bound, so this only fires on a corrupt/out-of-range input.
  private static func clampedRate(_ rate: Double) -> Double { min(max(rate, 0.5), 3.0) }

  /// Invalidate the current segment: bump the generation, resume the waiter, and
  /// stop the engine — all on the actor, so it can't race the render thread. Pass
  /// `broadcastStop: false` when a new segment starts immediately after (a slice switch),
  /// so the playhead isn't flashed to nil between the two.
  /// `reason` tells the suspended `play` caller why it woke: `.stopped` from a `stop`, `.superseded`
  /// from a newer `play` taking over (the default). The caller uses this to decide whether to rest
  /// the cursor at the range end (only on a natural `.finished`, never here).
  private func supersede(broadcastStop: Bool = true, reason: PlaybackEnd = .superseded) {
    generation += 1
    let waiter = continuation
    continuation = nil
    stopTicking(broadcastStop: broadcastStop)
    stopNode()
    currentSession = nil
    waiter?.resume(returning: reason)
  }

  private func complete(generation completedGeneration: Int) {
    guard generation == completedGeneration, let waiter = continuation else { return }
    continuation = nil
    stopTicking()
    stopNode()
    currentSession = nil
    waiter.resume(returning: .finished)
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
      broadcast(
        PlaybackPosition(
          sessionID: session, sample: positionSample(forFramesPlayed: 0), isPlaying: false))
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
    let framesPlayed = Int(max(0, playerTime.sampleTime))
    let sample = positionSample(forFramesPlayed: framesPlayed)
    broadcast(PlaybackPosition(sessionID: session, sample: sample, isPlaying: true))
  }

  /// Converts the node's played input-frame count to the reported position sample: an EDITED
  /// sample while a `playEdited` playlist runs (via `editedFrameTimeline`), otherwise the
  /// slice path's plan sample from the single start offset.
  private func positionSample(forFramesPlayed framesPlayed: Int) -> Int {
    if let editedFrameTimeline {
      return editedFrameTimeline.editedSample(forFramesPlayed: framesPlayed)
    }
    return startPlanSample + Int(Double(framesPlayed) / max(playRatio, .ulpOfOne))
  }

  private func stopNode() {
    node.stop()
    editedFrameTimeline = nil  // back to slice-path position math until the next `playEdited`

    // Clear the time-pitch unit's internal overlap/latency buffers so a stop, supersede, or slice
    // switch can't smear the tail of the old segment into the start of the next one.
    if timePitch.engine != nil { timePitch.reset() }
    if engine.isRunning { engine.stop() }
  }
}
