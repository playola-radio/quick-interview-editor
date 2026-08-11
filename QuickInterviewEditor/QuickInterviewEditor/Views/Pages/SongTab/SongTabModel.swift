import Dependencies
import Foundation
import Observation

@MainActor
@Observable
final class SongTabModel: ViewModel, Identifiable {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.engine) var engine
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
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var tickTask: Task<Void, Never>?
  /// Fired when this tab frees or wants a transcription slot (finished, failed, or
  /// re-queued for retry). RootModel wires this to its queue pump so the concurrency
  /// cap is honoured without the tab knowing about it.
  @ObservationIgnored var onReadyForNext: (() -> Void)?

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
  var showsProgress: Bool { isQueued || isTranscribing }
  var showsCancel: Bool { isQueued || isTranscribing }
  var progressMessage: String {
    switch phase {
    case .queued: return queuedMessage
    case .transcribing(let progress): return progress?.message ?? startingMessage
    case .loaded, .failed: return ""
    }
  }
  var errorMessage: String? {
    if case .failed(let message) = phase { return message }
    return nil
  }
  var progressFraction: Double? {
    guard case .transcribing(let progress) = phase,
      let progress, progress.phase == .transcribing, progress.fraction != nil
    else { return nil }
    return maxFraction
  }
  var isProgressDeterminate: Bool { progressFraction != nil }
  var determinateValue: Double { maxFraction ?? 0 }
  static func etaText(elapsedSeconds: Double, fraction: Double) -> String? {
    if fraction >= 0.5 { return "Aligning words — almost done" }
    let p = fraction / 0.5  // progress within the transcribe half
    guard p >= 0.05 else { return nil }  // too early to estimate
    let remaining = elapsedSeconds * (1 - p) / p
    if remaining < 60 { return "Less than a minute remaining" }
    let minutes = Int((remaining / 60).rounded())
    return "About \(max(minutes, 1)) min remaining"
  }
  var etaMessage: String? {
    guard let f = progressFraction else { return nil }
    return Self.etaText(elapsedSeconds: elapsedSeconds, fraction: f)
  }

  // MARK: - User Actions
  func start() {
    task?.cancel()  // never leak/overtake a still-running task (e.g. rapid retry)
    phase = .transcribing(nil)  // mark running synchronously so the queue pump counts it
    maxFraction = nil
    elapsedSeconds = 0
    startTicking()
    task = Task { await startTranscription() }
  }

  func startTranscription() async {
    // `start()` already set `.transcribing(nil)` synchronously (so the queue pump
    // counts this tab immediately); just clear any prior editor here.
    editor = nil
    // Content-hash the source once (off-main) BEFORE the engine reads it, so the sidecar
    // keys to the bytes we're actually transcribing — not a file swapped in at the same
    // path mid-run — and survives engine re-runs. Falls back to the path if unreadable.
    let fingerprint = await SourceFingerprint.make(for: sourceURL)
    do {
      for try await event in engine.transcribe(sourceURL) {
        switch event {
        case .progress(let progress):
          if progress.phase == .transcribing, let fraction = progress.fraction {
            maxFraction = max(maxFraction ?? 0, fraction)
          }
          phase = .transcribing(progress)
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

  // MARK: - Private Helpers
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
