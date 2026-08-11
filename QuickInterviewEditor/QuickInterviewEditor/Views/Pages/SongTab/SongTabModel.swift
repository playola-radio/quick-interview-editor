import Dependencies
import Foundation
import Observation

@MainActor
@Observable
final class SongTabModel: ViewModel, Identifiable {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.transcription) var transcription

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
  @ObservationIgnored private var task: Task<Void, Never>?
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

  // MARK: - User Actions
  func start() {
    task?.cancel()  // never leak/overtake a still-running task (e.g. rapid retry)
    phase = .transcribing(nil)  // mark running synchronously so the queue pump counts it
    task = Task { await startTranscription() }
  }

  func startTranscription() async {
    // `start()` already set `.transcribing(nil)` synchronously (so the queue pump
    // counts this tab immediately); just clear any prior editor here.
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
        case .progress(let progress): phase = .transcribing(progress)
        case .completed(let result):
          editor = withDependencies(from: self) {
            EditorModel(
              sourceURL: sourceURL, canonicalAudioURL: result.canonicalAudioURL,
              editPlan: result.editPlan, sourceFingerprint: fingerprint)
          }
          phase = .loaded
        }
      }
    } catch is CancellationError {
      // cancelled: leave last progress; the tab is being closed by RootModel
      return
    } catch {
      phase = .failed(error.localizedDescription)
    }
    onReadyForNext?()  // slot freed (loaded or failed) — let RootModel start the next
  }

  func cancel() { task?.cancel() }

  func retryTapped() {
    task?.cancel()
    phase = .queued  // re-enter the queue so the cap is respected
    onReadyForNext?()
  }

  /// Re-transcribe the current source ignoring any cached result, overwriting the
  /// cache entry. Re-enters the queue (like retry) so the concurrency cap holds.
  func reimportIgnoringCacheTapped() {
    task?.cancel()
    cachePolicy = .forceFresh
    phase = .queued
    onReadyForNext?()
  }
}
