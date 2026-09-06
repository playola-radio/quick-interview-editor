import SwiftUI

/// The `DocumentGroup` content for one `.pie` window. Builds the window's `ProjectModel` from
/// the document's decoded content, wires the model's document sink to the document, hands the
/// document its environment `UndoManager` (the dirtiness/autosave bridge, spec A7), and exposes
/// the model to menu commands as the focused project. Visuals live in `ProjectView`.
struct ProjectHostView: View {
  let document: ProjectDocument
  @State private var model: ProjectModel
  @Environment(\.undoManager) private var undoManager
  @Environment(AppLaunchModel.self) private var launch

  init(document: ProjectDocument, fileURL: URL?) {
    self.document = document
    let content = document.content
    _model = State(
      initialValue: ProjectModel(
        file: content?.file, plan: content?.plan, audio: content?.audio, packageURL: fileURL,
        sink: document.sink))
  }

  var body: some View {
    content
      .focusedSceneValue(\.projectModel, model)
      .onChange(of: undoManager, initial: true) { _, manager in document.undoManager = manager }
      .onAppear { launch.viewAppeared() }
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
