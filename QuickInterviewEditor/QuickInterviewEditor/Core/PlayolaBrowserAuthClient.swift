import AppKit
import AuthenticationServices
import Dependencies
import Foundation
import IssueReporting

/// Opens the Playola sign-in page in the user's browser and waits for it to come back
/// to the app's callback scheme. The callback URL carries the one-time code, so it is
/// never logged.
struct PlayolaBrowserAuthClient: Sendable {
  /// Opens `url` and returns the callback URL once the browser redirects to `callbackScheme`.
  var authenticate: @MainActor @Sendable (_ url: URL, _ callbackScheme: String) async throws -> URL
  /// Closes the browser session and fails the pending `authenticate` with `.canceled`.
  var cancel: @MainActor @Sendable () -> Void
}

enum PlayolaBrowserAuthError: Error, Equatable {
  case canceled
  case couldNotStart
}

// MARK: - Live session

/// Owns the one in-flight browser session. Every way an attempt can end (the browser
/// answering, `cancel()`, `start()` failing, or a newer `authenticate` replacing it) goes
/// through `finish(_:)`, which is the only place the continuation resumes.
@MainActor
final class PlayolaWebAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let shared = PlayolaWebAuthSession()

  private var session: ASWebAuthenticationSession?
  private var continuation: CheckedContinuation<URL, Error>?
  private var anchor = ASPresentationAnchor()
  private var attempt = 0

  func authenticate(url: URL, callbackScheme: String) async throws -> URL {
    finish(.failure(PlayolaBrowserAuthError.canceled))
    attempt += 1
    let thisAttempt = attempt
    anchor = NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()

    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation

      let session = ASWebAuthenticationSession(
        url: url, callback: .customScheme(callbackScheme)
      ) { [weak self] callbackURL, error in
        Task { @MainActor in
          self?.completed(attempt: thisAttempt, callbackURL: callbackURL, error: error)
        }
      }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = false
      self.session = session

      if !session.start() {
        finish(.failure(PlayolaBrowserAuthError.couldNotStart))
      }
    }
  }

  func cancel() {
    finish(.failure(PlayolaBrowserAuthError.canceled))
  }

  nonisolated func presentationAnchor(for session: ASWebAuthenticationSession)
    -> ASPresentationAnchor
  {
    MainActor.assumeIsolated { anchor }
  }

  // MARK: - Private Helpers

  private func completed(attempt completedAttempt: Int, callbackURL: URL?, error: Error?) {
    guard completedAttempt == attempt else { return }
    if let callbackURL {
      finish(.success(callbackURL))
    } else if let authError = error as? ASWebAuthenticationSessionError,
      authError.code == .canceledLogin
    {
      finish(.failure(PlayolaBrowserAuthError.canceled))
    } else {
      finish(.failure(error ?? PlayolaBrowserAuthError.couldNotStart))
    }
  }

  private func finish(_ result: Result<URL, Error>) {
    let continuation = continuation
    let session = session
    self.continuation = nil
    self.session = nil
    attempt += 1
    session?.cancel()
    continuation?.resume(with: result)
  }
}

// MARK: - Dependency

extension PlayolaBrowserAuthClient: DependencyKey {
  static var liveValue: PlayolaBrowserAuthClient {
    PlayolaBrowserAuthClient(
      authenticate: { url, callbackScheme in
        try await PlayolaWebAuthSession.shared.authenticate(
          url: url, callbackScheme: callbackScheme)
      },
      cancel: { PlayolaWebAuthSession.shared.cancel() }
    )
  }
}

extension PlayolaBrowserAuthClient: TestDependencyKey {
  static var testValue: PlayolaBrowserAuthClient {
    PlayolaBrowserAuthClient(
      authenticate: unimplemented("PlayolaBrowserAuthClient.authenticate"),
      cancel: {}
    )
  }
}

extension DependencyValues {
  var playolaBrowserAuth: PlayolaBrowserAuthClient {
    get { self[PlayolaBrowserAuthClient.self] }
    set { self[PlayolaBrowserAuthClient.self] = newValue }
  }
}
