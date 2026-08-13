import Dependencies
import Foundation
import Observation

@MainActor
@Observable
final class SongTabModel: ViewModel, Identifiable {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.transcription) var transcription
  @ObservationIgnored @Dependency(\.continuousClock) var clock

  // MARK: - Initialization
  let id = UUID()
  let sourceURL: URL
  init(sourceURL: URL) {
    self.sourceURL = sourceURL
    super.init()
  }

  // MARK: - Phase
  enum Phase: Equatable {
    case queued  // waiting for a transcription slot
    case transcribing(EngineProgress?)
    case loaded
    case failed(String)
  }

  // MARK: - Properties
  var phase: Phase = .queued
  var editor: EditorModel?
  private var maxFraction: Double?
  private var elapsedSeconds: Double = 0
  /// The engine phase identity currently on screen — index plus raw name. A change in
  /// either resets the monotonic clamp (a new phase starts its own 0–100%); the index
  /// alone also lets us ignore a late event from an earlier phase. Keying on the name
  /// too means an old-format message-only phase (no index) still drops the prior
  /// phase's determinate fraction instead of freezing it.
  private var currentPhaseIndex: Int?
  private var currentPhaseName: String?
  /// `elapsedSeconds` at the moment the current phase began, so the ETA measures
  /// time spent in THIS phase (transcribe and align run at very different rates).
  private var phaseStartElapsed: Double = 0
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var tickTask: Task<Void, Never>?
  /// Fired when this tab frees or wants a transcription slot (finished, failed, or
  /// re-queued for retry). RootModel wires this to its queue pump so the concurrency
  /// cap is honoured without the tab knowing about it.
  @ObservationIgnored var onReadyForNext: (() -> Void)?
  /// Consumed (and reset to `.useCache`) on each run. Set to `.forceFresh` by the
  /// re-import action so a single fresh transcription overwrites the cached entry.
  @ObservationIgnored private var cachePolicy: CachePolicy = .useCache

  // MARK: - Display Text
  let cancelButtonLabel = "Cancel"
  let retryButtonLabel = "Retry"
  let startingMessage = "Starting…"
  let queuedMessage = "Waiting to transcribe…"
  let progressNote = "This can take several minutes — longer files take longer."

  // MARK: - View Helpers
  var title: String { sourceURL.deletingPathExtension().lastPathComponent }
  var isQueued: Bool {
    if case .queued = phase { return true }
    return false
  }
  var isTranscribing: Bool {
    if case .transcribing = phase { return true }
    return false
  }
  var isLoaded: Bool {
    if case .loaded = phase { return true }
    return false
  }
  var canReimport: Bool { isLoaded }
  var showsProgress: Bool { isQueued || isTranscribing }
  var showsCancel: Bool { isQueued || isTranscribing }
  /// The one-line progress headline: "Phase X of N · <label> · NN%". The phase-of-N
  /// prefix appears only when the engine declared it; the percent only when the phase
  /// is determinate. All the "which parts to show" logic lives here, not in the view.
  var progressHeadline: String {
    switch phase {
    case .queued: return queuedMessage
    case .transcribing(let progress):
      guard let progress else { return startingMessage }
      return Self.headline(for: progress, fraction: progressFraction)
    case .loaded, .failed: return ""
    }
  }
  static func headline(for progress: EngineProgress, fraction: Double?) -> String {
    var parts: [String] = []
    if let phaseOfN = progress.phaseOfNText { parts.append(phaseOfN) }
    parts.append(progress.displayText)
    if let fraction { parts.append("\(Int(fraction * 100))%") }
    return parts.joined(separator: " · ")
  }
  var errorMessage: String? {
    if case .failed(let message) = phase { return message }
    return nil
  }
  var progressFraction: Double? {
    guard case .transcribing = phase else { return nil }
    return maxFraction  // nil for an indeterminate phase (e.g. Finalizing)
  }
  var isProgressDeterminate: Bool { progressFraction != nil }
  var determinateValue: Double { maxFraction ?? 0 }
  /// A per-phase estimate: time remaining *in this phase*, from time already spent in
  /// it and the phase fraction. Held back until the phase has run a bit (fraction and
  /// elapsed thresholds) so it doesn't jump around, and worded "in this phase" because
  /// a whole-job number would lie (align is slower per-unit than transcribe).
  static func phaseETAText(phaseElapsedSeconds: Double, fraction: Double) -> String? {
    guard phaseElapsedSeconds >= 30, fraction >= 0.05 else { return nil }
    let remaining = phaseElapsedSeconds * (1 - fraction) / fraction
    if remaining < 60 { return "Less than a minute left in this phase" }
    let minutes = Int((remaining / 60).rounded())
    return "About \(max(minutes, 1)) min left in this phase"
  }
  var etaMessage: String? {
    guard let fraction = progressFraction else { return nil }
    return Self.phaseETAText(
      phaseElapsedSeconds: elapsedSeconds - phaseStartElapsed, fraction: fraction)
  }

  // MARK: - User Actions
  func start() {
    task?.cancel()  // never leak/overtake a still-running task (e.g. rapid retry)
    phase = .transcribing(nil)  // mark running synchronously so the queue pump counts it
    maxFraction = nil
    currentPhaseIndex = nil
    currentPhaseName = nil
    phaseStartElapsed = 0
    elapsedSeconds = 0
    startTicking()
    task = Task { await startTranscription() }
  }

  func startTranscription() async {
    // `start()` already set `.transcribing(nil)` synchronously (so the queue pump
    // counts this tab immediately); tear down any prior editor (stop playback, cancel
    // export, release its canonical audio) before dropping it, so a re-import or retry
    // never leaves stale playback/export work running or an orphaned canonical AIFF.
    if let previous = editor {
      previous.cancelExportTapped()
      await previous.stopPlaybackTapped()
      previous.discardCanonicalAudio()
    }
    editor = nil
    let policy = cachePolicy
    cachePolicy = .useCache  // a subsequent retry uses the cache again
    // Content-hash the source once (off-main) BEFORE the engine reads it, so the sidecar
    // keys to the bytes we're actually transcribing — not a file swapped in at the same
    // path mid-run — and survives engine re-runs. Falls back to the path if unreadable.
    let fingerprint = await SourceFingerprint.make(for: sourceURL)
    do {
      for try await event in transcription.transcribe(sourceURL, fingerprint, policy) {
        switch event {
        case .progress(let progress):
          applyProgress(progress)
        case .completed(let result):
          editor = withDependencies(from: self) {
            EditorModel(
              sourceURL: sourceURL, canonicalAudioURL: result.canonicalAudioURL,
              editPlan: result.editPlan, sourceFingerprint: fingerprint)
          }
          phase = .loaded
          stopTicking()
        }
      }
    } catch is CancellationError {
      // cancelled: leave last progress; the tab is being closed by RootModel
      return
    } catch {
      phase = .failed(error.localizedDescription)
      stopTicking()
    }
    stopTicking()  // idempotent; guards the stream ending without a terminal .completed/throw
    onReadyForNext?()  // slot freed (loaded or failed) — let RootModel start the next
  }

  func cancel() {
    task?.cancel()
    stopTicking()
  }

  func retryTapped() {
    task?.cancel()
    stopTicking()
    phase = .queued  // re-enter the queue so the cap is respected
    onReadyForNext?()
  }

  /// Re-transcribe the current source ignoring any cached result, overwriting the
  /// cache entry. Re-enters the queue (like retry) so the concurrency cap holds.
  func reimportIgnoringCacheTapped() {
    task?.cancel()
    stopTicking()
    cachePolicy = .forceFresh
    phase = .queued
    onReadyForNext?()
  }

  // MARK: - Private Helpers
  /// Applies one engine progress event to the on-screen state. Resets the monotonic
  /// clamp and the per-phase timer when the phase moves forward, ignores a late event
  /// from an earlier phase, and clamps the fraction so the bar never jumps backward
  /// within a phase.
  private func applyProgress(_ progress: EngineProgress) {
    if let incoming = progress.phaseIndex, let current = currentPhaseIndex,
      incoming < current
    {
      return  // stale event from an earlier phase — keep the newer phase on screen
    }
    if progress.phaseIndex != currentPhaseIndex || progress.phase != currentPhaseName {
      currentPhaseIndex = progress.phaseIndex
      currentPhaseName = progress.phase
      maxFraction = nil
      phaseStartElapsed = elapsedSeconds
    }
    if let fraction = progress.fraction {
      maxFraction = max(maxFraction ?? 0, fraction)
    }
    phase = .transcribing(progress)
  }

  private func startTicking() {
    tickTask?.cancel()
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        try? await self.clock.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        self.elapsedSeconds += 1
      }
    }
  }

  private func stopTicking() {
    tickTask?.cancel()
    tickTask = nil
  }
}
