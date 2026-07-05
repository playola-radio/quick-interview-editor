import Dependencies
import Foundation
import IdentifiedCollections
import Observation

@MainActor
@Observable
final class RootModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.engine) var engine

  // MARK: - Configuration
  /// Cap on simultaneously-running transcriptions. Each is a heavy WhisperX
  /// subprocess (multi-GB), so dropping many files must not fork-bomb the machine;
  /// extra tabs wait in `.queued` and start as slots free.
  let maxConcurrentTranscriptions = 2

  // MARK: - Properties
  var tabs: IdentifiedArrayOf<SongTabModel> = []
  var selectedTabID: SongTabModel.ID?
  var isImporterPresented = false

  // MARK: - Display Text
  let emptyStateTitle = "Drop an audio clip to transcribe"
  let emptyStateSubtitle = "Drag a file here, or choose one to open."
  let importButtonLabel = "Open Audio File…"
  let closeTabLabel = "Close tab"

  // MARK: - View Helpers
  var showsEmptyState: Bool { tabs.isEmpty }
  var selectedTab: SongTabModel? { selectedTabID.flatMap { tabs[id: $0] } }

  // MARK: - User Actions
  func fileDropped(_ urls: [URL]) { for url in urls { openSong(url) } }
  func filePicked(_ url: URL) { openSong(url) }
  func importButtonTapped() { isImporterPresented = true }
  func tabSelected(_ id: SongTabModel.ID) { selectedTabID = id }

  func closeTab(_ id: SongTabModel.ID) {
    tabs[id: id]?.cancel()
    let wasSelected = selectedTabID == id
    tabs.remove(id: id)
    if wasSelected { selectedTabID = tabs.last?.id }
    pumpQueue()  // closing a running tab frees a slot for a queued one
  }

  // MARK: - Private Helpers
  private var runningCount: Int { tabs.filter(\.isTranscribing).count }

  /// Starts queued tabs until the concurrency cap is reached. `start()` marks a tab
  /// `.transcribing` synchronously, so `runningCount` updates within the loop.
  private func pumpQueue() {
    while runningCount < maxConcurrentTranscriptions,
      let next = tabs.first(where: \.isQueued)
    {
      next.start()
    }
  }

  private func openSong(_ url: URL) {
    let tab = withDependencies(from: self) { SongTabModel(sourceURL: url) }
    tab.onReadyForNext = { [weak self] in self?.pumpQueue() }
    tabs.append(tab)
    selectedTabID = tab.id
    pumpQueue()
  }
}
