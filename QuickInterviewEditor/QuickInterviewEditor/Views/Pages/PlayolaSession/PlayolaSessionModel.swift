import Dependencies
import Foundation
import Observation
import Sharing

/// The app's one Playola sign-in: restore at launch, sign in through the browser, sign
/// out, and server switching. It is the only writer of `@Shared(.playolaAccount)`.
///
/// Every async step captures the environment and `generation` before it awaits and drops
/// its result when either changed, so a late answer from an old attempt or server never
/// publishes or saves anything. Every abort bumps `generation`.
@MainActor
@Observable
final class PlayolaSessionModel: ViewModel {
  enum Attempt: Equatable {
    case idle, waiting, failed
  }

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.playolaTokenStore) var tokenStore
  @ObservationIgnored @Dependency(\.playolaAPI) var api
  @ObservationIgnored @Dependency(\.playolaBrowserAuth) var browserAuth
  @ObservationIgnored @Dependency(\.secureRandom) var secureRandom

  // MARK: - Shared State
  @ObservationIgnored @Shared(.playolaAccount) var account
  @ObservationIgnored @Shared(.playolaEnvironment) var environmentSetting

  // MARK: - Initialization
  init(allowsServerSwitching: Bool = PlayolaEnvironment.allowsSwitching) {
    self.allowsServerSwitching = allowsServerSwitching
    super.init()
    let environment = PlayolaEnvironment.resolved(
      environmentSetting, allowsSwitching: allowsServerSwitching)
    $account.withLock { $0.environment = environment }
  }

  // MARK: - Properties
  let allowsServerSwitching: Bool
  private(set) var attempt: Attempt = .idle
  private(set) var signOutFailed = false
  private var generation = 0
  private var didLaunch = false

  // MARK: - User Actions
  func appLaunched() async {
    guard !didLaunch else { return }
    didLaunch = true
    await restore()
  }

  func signInTapped() async {
    guard attempt != .waiting, account.isSignedOut else { return }
    generation += 1
    attempt = .waiting
    let environment = account.environment
    let generation = generation
    let authAttempt = PlayolaPKCE.makeAttempt(
      stateBytes: secureRandom.bytes(32), verifierBytes: secureRandom.bytes(32))
    do {
      let callback = try await browserAuth.authenticate(
        PlayolaPKCE.authorizeURL(environment: environment, attempt: authAttempt),
        PlayolaPKCE.callbackScheme)
      guard isCurrent(environment, generation) else { return }
      let code = try PlayolaPKCE.code(fromCallback: callback, expectedState: authAttempt.state)
      let newToken = try await api.exchangeCode(environment, code, authAttempt.verifier)
      guard isCurrent(environment, generation) else { return }
      try await tokenStore.save(newToken, environment)
      guard isCurrent(environment, generation) else { return }
      setStatus(.signedIn(nil))
      attempt = .idle
      signOutFailed = false
      await loadCurrentUser(token: newToken, environment: environment, generation: generation)
    } catch {
      guard isCurrent(environment, generation) else { return }
      if error as? PlayolaBrowserAuthError == .canceled {
        attempt = .idle
      } else {
        AppLog.playola.error(
          "Playola sign-in failed: \(Self.typeName(of: error), privacy: .public)")
        attempt = .failed
      }
    }
  }

  func cancelSignInTapped() {
    abortBrowserSignIn()
  }

  func signOutTapped() async {
    abortBrowserSignIn()
    guard case .signedIn = account.status else { return }
    generation += 1
    let environment = account.environment
    let generation = generation
    do {
      try await tokenStore.delete(environment)
    } catch {
      guard isCurrent(environment, generation) else { return }
      AppLog.playola.error(
        "Couldn't delete the Playola sign-in: \(String(describing: error), privacy: .public)")
      signOutFailed = true
      return
    }
    guard isCurrent(environment, generation) else { return }
    setStatus(.signedOut(nil))
    signOutFailed = false
  }

  func environmentPicked(_ environment: PlayolaEnvironment) async {
    guard allowsServerSwitching, environment != account.environment else { return }
    generation += 1
    abortBrowserSignIn()
    attempt = .idle
    signOutFailed = false
    $environmentSetting.withLock { $0 = environment }
    $account.withLock { $0 = PlayolaAccount(environment: environment, status: .restoring) }
    await restore()
  }

  // MARK: - Private Helpers
  private func restore() async {
    let environment = account.environment
    let generation = generation
    let loaded: String?
    do {
      loaded = try await tokenStore.load(environment)
    } catch {
      guard isCurrent(environment, generation) else { return }
      AppLog.playola.error(
        "Couldn't read the Playola sign-in: \(String(describing: error), privacy: .public)")
      setStatus(.signedOut(nil))
      return
    }
    guard isCurrent(environment, generation) else { return }
    guard let loaded else {
      setStatus(.signedOut(nil))
      return
    }
    setStatus(.signedIn(nil))
    await loadCurrentUser(token: loaded, environment: environment, generation: generation)
  }

  private func loadCurrentUser(
    token: String, environment: PlayolaEnvironment, generation: Int
  ) async {
    do {
      let user = try await api.currentUser(environment, token)
      guard isCurrent(environment, generation) else { return }
      setStatus(.signedIn(user))
    } catch PlayolaAPIError.unauthorized {
      guard isCurrent(environment, generation) else { return }
      do {
        try await tokenStore.delete(environment)
      } catch {
        AppLog.playola.error(
          "Couldn't delete the rejected Playola sign-in: \(String(describing: error), privacy: .public)"
        )
      }
      guard isCurrent(environment, generation) else { return }
      setStatus(.signedOut(.rejectedByPlayola))
    } catch {
      AppLog.playola.error(
        "Couldn't load the Playola user: \(Self.typeName(of: error), privacy: .public)")
    }
  }

  /// Cancelling the caller's `Task` doesn't end the browser session, so every abort
  /// while waiting has to close it explicitly.
  private func abortBrowserSignIn() {
    guard attempt == .waiting else { return }
    generation += 1
    attempt = .idle
    browserAuth.cancel()
  }

  private func isCurrent(_ environment: PlayolaEnvironment, _ generation: Int) -> Bool {
    environment == account.environment && generation == self.generation
  }

  private func setStatus(_ status: PlayolaAccount.Status) {
    $account.withLock { $0.status = status }
  }

  private static func typeName(of error: any Error) -> String {
    String(describing: type(of: error))
  }
}
