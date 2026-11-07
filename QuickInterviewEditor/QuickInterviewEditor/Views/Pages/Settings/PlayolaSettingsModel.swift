import Observation
import Sharing

@MainActor
@Observable
final class PlayolaSettingsModel: ViewModel {
  // MARK: - Shared State
  @ObservationIgnored @Shared(.playolaAccount) var account

  // MARK: - Initialization
  init(session: PlayolaSessionModel) {
    self.session = session
    super.init()
  }

  // MARK: - Properties
  private let session: PlayolaSessionModel

  // MARK: - View Helpers
  var tabTitle: String { "Playola" }
  var tabSystemImage: String { "person.crop.circle" }
  var accountHeader: String { "Account" }

  var accountRowLabel: String {
    if case .signedIn = account.status { return "Signed in as:" }
    return "Status:"
  }

  var accountValue: String {
    switch account.status {
    case .restoring: return ""
    case .signedIn(let user): return user?.displayName ?? "Signed in"
    case .signedOut: return isWaiting ? "Waiting for Playola…" : "Not signed in"
    }
  }

  var accountDetail: String? {
    if session.signOutFailed { return "Couldn't sign out. Try again." }
    switch account.status {
    case .restoring: return nil
    case .signedIn(let user): return user?.email
    case .signedOut(let reason):
      if isWaiting { return nil }
      if session.attempt == .failed {
        return "Couldn't sign in to Playola. Check your connection and try again."
      }
      if reason == .rejectedByPlayola {
        return "You were signed out of Playola. Sign in again to continue."
      }
      return "Sign in to get the interviews assigned to you on Playola."
    }
  }

  var accountDetailIsError: Bool {
    if session.signOutFailed { return true }
    return !isWaiting && account.isSignedOut && session.attempt == .failed
  }

  var showsAccountButton: Bool {
    if case .restoring = account.status { return false }
    return true
  }

  var accountButtonTitle: String {
    if isSignedIn { return "Sign Out" }
    return isWaiting ? "Cancel" : "Sign In with Playola…"
  }

  var accountButtonIsProminent: Bool {
    account.isSignedOut && !isWaiting
  }

  var showsServerPicker: Bool { session.allowsServerSwitching }
  var serverHeader: String { "Server (debug builds only)" }
  var serverLabel: String { "Server:" }
  var serverHelp: String {
    "Production, Staging, or Local. Each server keeps its own sign-in."
  }
  var environments: [PlayolaEnvironment] { PlayolaEnvironment.allCases }
  var selectedEnvironment: PlayolaEnvironment { account.environment }

  // MARK: - User Actions
  func accountButtonTapped() async {
    if isSignedIn {
      await session.signOutTapped()
    } else if isWaiting {
      session.cancelSignInTapped()
    } else {
      await session.signInTapped()
    }
  }

  func environmentPicked(_ environment: PlayolaEnvironment) async {
    await session.environmentPicked(environment)
  }

  // MARK: - Private Helpers
  private var isWaiting: Bool { session.attempt == .waiting }

  private var isSignedIn: Bool {
    if case .signedIn = account.status { return true }
    return false
  }
}
