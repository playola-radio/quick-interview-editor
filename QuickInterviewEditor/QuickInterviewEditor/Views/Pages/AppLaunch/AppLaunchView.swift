import SwiftUI

/// Chooses between first-launch model setup and the editor. Visuals only — the
/// decision lives on ``AppLaunchModel``.
struct AppLaunchView: View {
  @State var model: AppLaunchModel

  var body: some View {
    content
      .onAppear { model.viewAppeared() }
  }

  @ViewBuilder private var content: some View {
    if model.showsModelSetup, let setup = model.modelSetup {
      ModelSetupView(model: setup)
    } else {
      RootView(model: model.root)
    }
  }
}
