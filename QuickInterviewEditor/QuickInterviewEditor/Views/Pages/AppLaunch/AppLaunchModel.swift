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

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.updater) var updater

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
    // Canonical audio caches are per-session derived data. On launch no editor
    // references any prior-run dir, so prune them all before any new one is created.
    CanonicalAudioStore.pruneAll()
    // Warm the engine-fingerprint memo off the main actor so the first import
    // doesn't stall on hashing the engine (notably the frozen binary in packaged builds).
    Task.detached(priority: .utility) { _ = EngineFingerprint.current() }
    if let base = try? TranscriptCache.baseDirectory() {
      TranscriptCache.sweepStaleTempDirs(base: base)
    }
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

  // MARK: - Properties
  private var didRunLaunchTasks = false

  // MARK: - View Helpers
  var showsModelSetup: Bool { phase == .modelSetup }

  // MARK: - User Actions
  /// Run once on first appearance. `onAppear` can fire repeatedly (window reopen,
  /// tab switches), so the one-shot guard keeps the relocation prompt from nagging
  /// the user again and again within a single process. Relocation runs first; if it
  /// kicks off a move + relaunch this process is terminating, so we skip starting
  /// the updater here — the relocated copy starts its own on launch.
  func viewAppeared() {
    guard !didRunLaunchTasks else { return }
    didRunLaunchTasks = true
    let relocating = InstallLocation.offerMoveToApplicationsIfNeeded()
    guard !relocating else { return }
    updater.start()
  }
}
