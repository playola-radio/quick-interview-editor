import Dependencies
import Foundation
import Observation

/// Top-level launch flow: in the **packaged** app, first-launch model setup must
/// complete before the editor is usable; in **dev**, the engine downloads models
/// on demand, so setup is skipped entirely. Owning both child models here keeps
/// the decision (and all of it) out of the view.
@MainActor
@Observable
final class AppLaunchModel: ViewModel {

  // MARK: - Phase
  enum Phase: Equatable {
    case modelSetup
    case ready
  }

  // MARK: - Properties
  var phase: Phase
  let root: RootModel
  private(set) var modelSetup: ModelSetupModel?

  // MARK: - Initialization
  /// - Parameter requiresManagedModels: `true` for the packaged build (bundled
  ///   engine), which gates on model setup; `false` for dev, which goes straight
  ///   to the editor. Defaults to `LiveEngine.isPackaged`.
  init(requiresManagedModels: Bool = LiveEngine.isPackaged) {
    self.root = RootModel()
    self.phase = requiresManagedModels ? .modelSetup : .ready
    if requiresManagedModels {
      let setup = ModelSetupModel()
      self.modelSetup = setup
      super.init()
      // Setup self-skips to `.ready` immediately if the models are already
      // installed (verified), so a returning user never sees the gate.
      setup.onReady = { [weak self] _ in self?.phase = .ready }
    } else {
      self.modelSetup = nil
      super.init()
    }
  }

  // MARK: - View Helpers
  var showsModelSetup: Bool { phase == .modelSetup }
}
