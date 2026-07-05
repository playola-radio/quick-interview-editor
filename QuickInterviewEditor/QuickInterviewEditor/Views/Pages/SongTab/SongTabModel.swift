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
    case transcribing(EngineProgress?)
    case loaded
    case failed(String)
  }

  // MARK: - Properties
  var phase: Phase = .transcribing(nil)
  var transcript: TranscriptPageModel?
  @ObservationIgnored private var task: Task<Void, Never>?

  // MARK: - Display Text
  let cancelButtonLabel = "Cancel"
  let retryButtonLabel = "Retry"
  let startingMessage = "Starting…"

  // MARK: - View Helpers
  var title: String { sourceURL.deletingPathExtension().lastPathComponent }
  var isLoaded: Bool { if case .loaded = phase { return true }; return false }
  var showsCancel: Bool { if case .transcribing = phase { return true }; return false }
  var progressMessage: String {
    if case let .transcribing(p) = phase { return p?.message ?? startingMessage }
    return ""
  }
  var errorMessage: String? { if case let .failed(m) = phase { return m }; return nil }

  // MARK: - User Actions
  func start() { task = Task { await startTranscription() } }

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
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  func cancel() { task?.cancel() }

  func retryTapped() { start() }
}
