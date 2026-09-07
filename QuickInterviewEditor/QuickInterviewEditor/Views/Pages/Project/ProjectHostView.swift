import SwiftUI

/// The `DocumentGroup` content for one `.pie` window. Builds the window's `ProjectModel` from
/// the document's decoded content, wires the model's document sink to the document, hands the
/// document its environment `UndoManager` (the dirtiness/autosave bridge, spec A7), and exposes
/// the model to menu commands as the focused project. Visuals live in `ProjectView`.
struct ProjectHostView: View {
  let document: ProjectDocument
  let fileURL: URL?
  @State private var model: ProjectModel
  @Environment(\.undoManager) private var undoManager
  @Environment(AppLaunchModel.self) private var launch

  init(document: ProjectDocument, fileURL: URL?) {
    self.document = document
    self.fileURL = fileURL
    let content = document.content
    _model = State(
      initialValue: ProjectModel(
        file: content?.file, plan: content?.plan, audio: content?.audio, packageURL: fileURL,
        sink: document.sink, recoveryArchive: content?.recoveryArchive))
  }

  var body: some View {
    content
      .background(DocumentDefaultName(suggestedName: model.suggestedDocumentName))
      .focusedSceneValue(\.projectModel, model)
      .onChange(of: undoManager, initial: true) { _, manager in document.undoManager = manager }
      // Wire the document's weak indicator to the RETAINED model's own SaveStatus (never a
      // fresh one made in init — SwiftUI reuses the @State model across view re-inits, so a
      // per-init SaveStatus would orphan the visible indicator). Idempotent across re-appears.
      .onAppear {
        document.saveStatus = model.saveStatus
        launch.viewAppeared()
      }
      .onChange(of: fileURL) { _, url in
        model.documentURLChanged(url)
        Task { await model.documentLocationObserved() }
      }
      .onChange(of: model.saveStatus.isSaving) { _, _ in
        Task { await model.savedProjectObserved() }
      }
      .task { await model.viewAppeared() }
      .onDisappear { Task { await model.viewDisappeared() } }
  }

  @ViewBuilder private var content: some View {
    if launch.showsModelSetup, let setup = launch.modelSetup {
      ModelSetupView(model: setup)
    } else {
      ProjectView(model: model)
    }
  }
}
