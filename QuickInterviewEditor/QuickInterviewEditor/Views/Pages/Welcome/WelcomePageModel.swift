import Observation
import Sharing

@MainActor
@Observable
final class WelcomePageModel: ViewModel {
  enum Gate: Equatable {
    case waitingForRestore, welcome, passThrough
  }

  enum Notice: Equatable {
    case error(String)
    case warning(String)
  }

  // MARK: - Shared State
  @ObservationIgnored @Shared(.playolaAccount) var account

  // MARK: - Initialization
  init(session: PlayolaSessionModel, project: ProjectModel) {
    self.session = session
    self.project = project
    super.init()
  }

  // MARK: - Properties
  private let session: PlayolaSessionModel
  private let project: ProjectModel
  private var choseLocalFile = false

  // MARK: - View Helpers
  var gate: Gate {
    guard project.phase == .empty, !choseLocalFile else { return .passThrough }
    switch account.status {
    case .restoring: return .waitingForRestore
    case .signedOut: return .welcome
    case .signedIn: return .passThrough
    }
  }

  var title: String { "Welcome to Playola Interview Editor" }

  var message: String {
    isWaiting
      ? "Finish signing in in your browser. This window continues on its own when you're done."
      : "Sign in with your Playola account to get the interviews assigned to you."
  }

  var notice: Notice? {
    if session.attempt == .failed {
      return .error("Couldn't sign in to Playola. Check your connection and try again.")
    }
    if !isWaiting, account.status == .signedOut(.rejectedByPlayola) {
      return .warning("You were signed out of Playola. Sign in again to continue.")
    }
    return nil
  }

  var showsProgress: Bool { isWaiting }
  var waitingText: String { "Waiting for Playola…" }
  var showsSignInButtons: Bool { !isWaiting }
  var signInButtonTitle: String {
    session.attempt == .failed ? "Try Again" : "Sign In with Playola…"
  }
  var localFileButtonTitle: String { "Use a Local Audio File" }
  var showsCancelButton: Bool { isWaiting }
  var cancelButtonTitle: String { "Cancel" }

  // MARK: - User Actions
  func signInTapped() async {
    await session.signInTapped()
  }

  func cancelTapped() {
    session.cancelSignInTapped()
  }

  func useLocalFileTapped() {
    choseLocalFile = true
  }

  // MARK: - Private Helpers
  private var isWaiting: Bool { session.attempt == .waiting }
}
