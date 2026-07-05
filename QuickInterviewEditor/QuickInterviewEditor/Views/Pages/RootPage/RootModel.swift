import Dependencies
import Foundation
import IdentifiedCollections
import Observation

@MainActor
@Observable
final class RootModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.engine) var engine

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
  }

  // MARK: - Private Helpers
  private func openSong(_ url: URL) {
    let tab = withDependencies(from: self) { SongTabModel(sourceURL: url) }
    tabs.append(tab)
    selectedTabID = tab.id
    tab.start()
  }
}
