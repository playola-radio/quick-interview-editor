import Dependencies
import Foundation
import Observation

@MainActor
@Observable
final class SongTabModel: ViewModel, Identifiable {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.engine) var engine

  // MARK: - Initialization
  let id = UUID()
  let sourceURL: URL
  init(sourceURL: URL) {
    self.sourceURL = sourceURL
    super.init()
  }

  // MARK: - Phase
  enum Phase: Equatable {
    case queued                            // waiting for a transcription slot
    case transcribing(EngineProgress?)
    case loaded
    case failed(String)
  }

  // MARK: - Properties
  var phase: Phase = .queued
  var transcript: TranscriptPageModel?
  @ObservationIgnored private var task: Task<Void, Never>?
  /// Fired when this tab frees or wants a transcription slot (finished, failed, or
  /// re-queued for retry). RootModel wires this to its queue pump so the concurrency
  /// cap is honoured without the tab knowing about it.
  @ObservationIgnored var onReadyForNext: (() -> Void)?

  // MARK: - Display Text
  let cancelButtonLabel = "Cancel"
  let retryButtonLabel = "Retry"
  let startingMessage = "Starting…"
  let queuedMessage = "Waiting to transcribe…"

  // MARK: - View Helpers
  var title: String { sourceURL.deletingPathExtension().lastPathComponent }
  var isQueued: Bool { if case .queued = phase { return true }; return false }
  var isTranscribing: Bool { if case .transcribing = phase { return true }; return false }
  var isLoaded: Bool { if case .loaded = phase { return true }; return false }
  var showsProgress: Bool { isQueued || isTranscribing }
  var showsCancel: Bool { isQueued || isTranscribing }
  var progressMessage: String {
    switch phase {
    case .queued: return queuedMessage
    case let .transcribing(p): return p?.message ?? startingMessage
    case .loaded, .failed: return ""
    }
  }
  var errorMessage: String? { if case let .failed(m) = phase { return m }; return nil }

  // MARK: - User Actions
  func start() {
    task?.cancel()  // never leak/overtake a still-running task (e.g. rapid retry)
    phase = .transcribing(nil)  // mark running synchronously so the queue pump counts it
    task = Task { await startTranscription() }
  }

  func startTranscription() async {
    phase = .transcribing(nil)
    transcript = nil
    do {
      for try await event in engine.transcribe(sourceURL) {
        switch event {
        case let .progress(p): phase = .transcribing(p)
        case let .completed(plan):
          transcript = TranscriptPageModel(editPlan: plan)
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
    phase = .queued           // re-enter the queue so the cap is respected
    onReadyForNext?()
  }
}
