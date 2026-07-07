import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
  @Bindable var model: RootModel

  var body: some View {
    VStack(spacing: 0) {
      if !model.tabs.isEmpty { tabStrip }
      content
    }
    .frame(minWidth: 1040, minHeight: 680)
    .background(Color.black)
    .dropDestination(for: URL.self) { urls, _ in
      model.fileDropped(urls)  // model filters to audio files
      return true
    }
    .fileImporter(
      isPresented: $model.isImporterPresented,
      allowedContentTypes: [.audio]
    ) { result in
      switch result {
      case .success(let url): model.filePicked(url)
      case .failure(let error): model.filePickFailed(error)
      }
    }
  }

  private var tabStrip: some View {
    HStack(spacing: 6) {
      ForEach(model.tabs) { tab in
        HStack(spacing: 6) {
          Text(tab.title).lineLimit(1)
          Button {
            model.closeTab(tab.id)
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain).accessibilityLabel(model.closeTabLabel)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(model.selectedTabID == tab.id ? Color(white: 0.16) : Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { model.tabSelected(tab.id) }
        .accessibilityAddTraits(.isButton)
      }
      Spacer()
    }
    .padding(8)
    .background(Color(white: 0.06))
  }

  @ViewBuilder private var content: some View {
    if let tab = model.selectedTab {
      SongTabView(model: tab, onCancel: { model.closeTab(tab.id) })
    } else {
      ImportPageView(model: model)
    }
  }
}
