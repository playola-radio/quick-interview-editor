import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct PlayolaSessionModelTests {
  nonisolated static let randomBytes = Data(repeating: 7, count: 32)
  nonisolated static let state = PlayolaPKCE.base64URL(randomBytes)
  nonisolated static let user = PlayolaUser(
    id: "user-1", firstName: "Ada", lastName: "Lovelace", email: "ada@example.com")
  nonisolated static let successCallback = callback("code=C&state=\(state)")
  nonisolated static let exchangeErrors: [any Error] = [
    PlayolaAPIError.badStatus(400), PlayolaAPIError.unauthorized,
    URLError(.notConnectedToInternet),
  ]

  nonisolated static func callback(_ query: String) -> URL {
    URL(string: "playola-interview-editor://auth/callback?\(query)")!
  }

  static func base(_ values: inout DependencyValues) {
    values.defaultInMemoryStorage = InMemoryStorage()
    values.defaultAppStorage = UserDefaults(suiteName: "playola-session-\(UUID())")!
    values.secureRandom = .constant(randomBytes)
  }

  // MARK: - Sign in

  @Test func signInSuccessSavesTokenForActiveEnvironmentThenLoadsUser() async throws {
    let store = PlayolaTokenStore.inMemory()
    let exchanges = LockIsolated<[ExchangeRequest]>([])
    try await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
      $0.playolaBrowserAuth = .returning(Self.successCallback)
      $0.playolaAPI = PlayolaAPIClient(
        exchangeCode: { environment, code, codeVerifier in
          exchanges.withValue {
            $0.append(
              ExchangeRequest(environment: environment, code: code, codeVerifier: codeVerifier))
          }
          return "T"
        },
        currentUser: { _, _ in Self.user })
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account

      await model.signInTapped()

      let saved = try await store.load(.production)
      expectNoDifference(saved, "T")
      expectNoDifference(
        account, PlayolaAccount(environment: .production, status: .signedIn(Self.user)))
      expectNoDifference(model.attempt, .idle)
      expectNoDifference(
        exchanges.value,
        [
          ExchangeRequest(
            environment: .production, code: "C",
            codeVerifier: PlayolaPKCE.base64URL(Self.randomBytes))
        ])
    }
  }

  @Test func signInCanceledInBrowserReturnsToSignedOutWithoutFailure() async {
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = .inMemory()
      $0.playolaBrowserAuth = .throwing(PlayolaBrowserAuthError.canceled)
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account
      await model.appLaunched()

      await model.signInTapped()

      expectNoDifference(model.attempt, .idle)
      expectNoDifference(account, PlayolaAccount(environment: .production, status: .signedOut(nil)))
    }
  }

  @Test func signInStateMismatchFailsAndSavesNothing() async throws {
    let store = PlayolaTokenStore.inMemory()
    try await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
      $0.playolaBrowserAuth = .returning(Self.callback("code=C&state=someone-else"))
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account
      await model.appLaunched()

      await model.signInTapped()

      let saved = try await store.load(.production)
      expectNoDifference(model.attempt, .failed)
      expectNoDifference(saved, nil)
      expectNoDifference(account, PlayolaAccount(environment: .production, status: .signedOut(nil)))
    }
  }

  @Test func signInProviderErrorFails() async {
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = .inMemory()
      $0.playolaBrowserAuth = .returning(
        Self.callback("error=access_denied&state=\(Self.state)"))
    } operation: {
      let model = PlayolaSessionModel()
      await model.appLaunched()

      await model.signInTapped()

      expectNoDifference(model.attempt, .failed)
    }
  }

  @Test(arguments: exchangeErrors)
  func signInExchange400And401AndNetworkErrorFail(error: any Error) async throws {
    let store = PlayolaTokenStore.inMemory()
    try await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
      $0.playolaBrowserAuth = .returning(Self.successCallback)
      $0.playolaAPI.exchangeCode = { _, _, _ in throw error }
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account
      await model.appLaunched()

      await model.signInTapped()

      let saved = try await store.load(.production)
      expectNoDifference(model.attempt, .failed)
      expectNoDifference(saved, nil)
      expectNoDifference(account, PlayolaAccount(environment: .production, status: .signedOut(nil)))
    }
  }

  @Test func signInSaveFailureIsAFailedSignIn() async {
    var store = PlayolaTokenStore.inMemory()
    store.save = { _, _ in throw TestError() }
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
      $0.playolaBrowserAuth = .returning(Self.successCallback)
      $0.playolaAPI.exchangeCode = { _, _, _ in "T" }
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account
      await model.appLaunched()

      await model.signInTapped()

      expectNoDifference(model.attempt, .failed)
      expectNoDifference(account, PlayolaAccount(environment: .production, status: .signedOut(nil)))
    }
  }

  @Test func secondSignInWhileWaitingDoesNotStartAnotherBrowserSession() async {
    let gate = Gate()
    let authenticateCalls = LockIsolated(0)
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = .inMemory()
      $0.playolaBrowserAuth = PlayolaBrowserAuthClient(
        authenticate: { _, _ in
          authenticateCalls.withValue { $0 += 1 }
          await gate.pass()
          return Self.successCallback
        },
        cancel: {})
      $0.playolaAPI = PlayolaAPIClient(
        exchangeCode: { _, _, _ in "T" }, currentUser: { _, _ in Self.user })
    } operation: {
      let model = PlayolaSessionModel()
      await model.appLaunched()

      let task = Task { await model.signInTapped() }
      await gate.waitUntilStarted()
      await model.signInTapped()
      gate.open()
      await task.value

      expectNoDifference(authenticateCalls.value, 1)
    }
  }

  @Test func cancelDuringExchangeDropsLateSuccessAndSavesNothing() async throws {
    let gate = Gate()
    let store = PlayolaTokenStore.inMemory()
    let cancels = LockIsolated(0)
    try await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
      $0.playolaBrowserAuth = .returning(Self.successCallback, cancels: cancels)
      $0.playolaAPI.exchangeCode = { _, _, _ in
        await gate.pass()
        return "T"
      }
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account
      await model.appLaunched()

      let task = Task { await model.signInTapped() }
      await gate.waitUntilStarted()
      model.cancelSignInTapped()
      gate.open()
      await task.value

      let saved = try await store.load(.production)
      expectNoDifference(saved, nil)
      expectNoDifference(account, PlayolaAccount(environment: .production, status: .signedOut(nil)))
      expectNoDifference(model.attempt, .idle)
      expectNoDifference(cancels.value, 1)
    }
  }

  // MARK: - Restore

  @Test func restoreWithTokenIsSignedInBeforeMeAnswers() async {
    let gate = Gate()
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = .inMemory([.production: "T"])
      $0.playolaAPI.currentUser = { _, _ in
        await gate.pass()
        return Self.user
      }
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account

      let task = Task { await model.appLaunched() }
      await gate.waitUntilStarted()

      expectNoDifference(account, PlayolaAccount(environment: .production, status: .signedIn(nil)))

      gate.open()
      await task.value

      expectNoDifference(
        account, PlayolaAccount(environment: .production, status: .signedIn(Self.user)))
    }
  }

  @Test func restoreWithoutTokenIsSignedOut() async {
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = .inMemory()
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account

      await model.appLaunched()

      expectNoDifference(account, PlayolaAccount(environment: .production, status: .signedOut(nil)))
    }
  }

  @Test func restoreKeychainErrorSignsOutWithoutDeleting() async {
    let deletes = LockIsolated(0)
    var store = PlayolaTokenStore.inMemory([.production: "T"])
    store.load = { _ in throw PlayolaKeychainError.unreadableData }
    store.delete = { _ in deletes.withValue { $0 += 1 } }
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account

      await model.appLaunched()

      expectNoDifference(account, PlayolaAccount(environment: .production, status: .signedOut(nil)))
      expectNoDifference(deletes.value, 0)
    }
  }

  @Test func appLaunchedTwiceRestoresOnce() async {
    let loads = LockIsolated(0)
    var store = PlayolaTokenStore.inMemory()
    store.load = { _ in
      loads.withValue { $0 += 1 }
      return nil
    }
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
    } operation: {
      let model = PlayolaSessionModel()

      await model.appLaunched()
      await model.appLaunched()

      expectNoDifference(loads.value, 1)
    }
  }

  // MARK: - /me

  @Test func meUnauthorizedDeletesTokenAndSignsOutAsRejected() async throws {
    let store = PlayolaTokenStore.inMemory([.production: "T"])
    try await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
      $0.playolaAPI.currentUser = { _, _ in throw PlayolaAPIError.unauthorized }
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account

      await model.appLaunched()

      let saved = try await store.load(.production)
      expectNoDifference(
        account,
        PlayolaAccount(environment: .production, status: .signedOut(.rejectedByPlayola)))
      expectNoDifference(saved, nil)
    }
  }

  @Test func meNetworkErrorStaysSignedInWithoutUser() async throws {
    let store = PlayolaTokenStore.inMemory([.production: "T"])
    try await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
      $0.playolaAPI.currentUser = { _, _ in throw URLError(.notConnectedToInternet) }
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account

      await model.appLaunched()

      let saved = try await store.load(.production)
      expectNoDifference(account, PlayolaAccount(environment: .production, status: .signedIn(nil)))
      expectNoDifference(saved, "T")
    }
  }

  // MARK: - Late answers

  @Test func staleMeAfterSignOutIsDropped() async {
    let gate = Gate()
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = .inMemory([.production: "T"])
      $0.playolaAPI.currentUser = { _, _ in
        await gate.pass()
        return Self.user
      }
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account

      let task = Task { await model.appLaunched() }
      await gate.waitUntilStarted()
      await model.signOutTapped()
      gate.open()
      await task.value

      expectNoDifference(account, PlayolaAccount(environment: .production, status: .signedOut(nil)))
    }
  }

  @Test func staleMeUnauthorizedAfterServerSwitchDeletesNothing() async throws {
    let gate = Gate()
    let store = PlayolaTokenStore.inMemory([.production: "P"])
    try await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
      $0.playolaAPI.currentUser = { _, _ in
        await gate.pass()
        throw PlayolaAPIError.unauthorized
      }
    } operation: {
      let model = PlayolaSessionModel(allowsServerSwitching: true)
      @Shared(.playolaAccount) var account

      let task = Task { await model.appLaunched() }
      await gate.waitUntilStarted()
      await model.environmentPicked(.staging)
      gate.open()
      await task.value

      let saved = try await store.load(.production)
      expectNoDifference(saved, "P")
      expectNoDifference(account, PlayolaAccount(environment: .staging, status: .signedOut(nil)))
    }
  }

  @Test func switchingAwayAndBackMidRestoreRestoresTheRightToken() async {
    let gate = Gate()
    let productionLoads = LockIsolated(0)
    let store = PlayolaTokenStore(
      load: { environment in
        guard environment == .production else { return nil }
        let count = productionLoads.withValue {
          $0 += 1
          return $0
        }
        guard count > 1 else {
          await gate.pass()
          return nil
        }
        return "P"
      },
      save: { _, _ in },
      delete: { _ in })
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
      $0.playolaAPI.currentUser = { _, _ in Self.user }
    } operation: {
      let model = PlayolaSessionModel(allowsServerSwitching: true)
      @Shared(.playolaAccount) var account

      let task = Task { await model.appLaunched() }
      await gate.waitUntilStarted()
      await model.environmentPicked(.staging)
      await model.environmentPicked(.production)
      gate.open()
      await task.value

      expectNoDifference(
        account, PlayolaAccount(environment: .production, status: .signedIn(Self.user)))
    }
  }

  // MARK: - Server switching

  @Test func serverSwitchLoadsOnlyThatServersToken() async {
    let requests = LockIsolated<[MeRequest]>([])
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = .inMemory([.production: "P", .staging: "S"])
      $0.playolaAPI.currentUser = { environment, token in
        requests.withValue { $0.append(MeRequest(environment: environment, token: token)) }
        return Self.user
      }
    } operation: {
      let model = PlayolaSessionModel(allowsServerSwitching: true)
      @Shared(.playolaAccount) var account
      await model.appLaunched()

      await model.environmentPicked(.staging)

      expectNoDifference(
        requests.value,
        [
          MeRequest(environment: .production, token: "P"),
          MeRequest(environment: .staging, token: "S"),
        ])
      expectNoDifference(
        account, PlayolaAccount(environment: .staging, status: .signedIn(Self.user)))
    }
  }

  @Test func serverSwitchIgnoredWhenSwitchingNotAllowed() async {
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = .inMemory()
    } operation: {
      let model = PlayolaSessionModel(allowsServerSwitching: false)
      @Shared(.playolaAccount) var account
      @Shared(.playolaEnvironment) var environmentSetting
      await model.appLaunched()

      await model.environmentPicked(.staging)

      expectNoDifference(account, PlayolaAccount(environment: .production, status: .signedOut(nil)))
      expectNoDifference(environmentSetting, .production)
    }
  }

  // MARK: - Sign out

  @Test func signOutDeletesOnlyActiveEnvironmentToken() async throws {
    let store = PlayolaTokenStore.inMemory([.production: "P", .staging: "S"])
    try await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
      $0.playolaAPI.currentUser = { _, _ in Self.user }
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account
      await model.appLaunched()

      await model.signOutTapped()

      let production = try await store.load(.production)
      let staging = try await store.load(.staging)
      expectNoDifference(production, nil)
      expectNoDifference(staging, "S")
      expectNoDifference(account, PlayolaAccount(environment: .production, status: .signedOut(nil)))
      expectNoDifference(model.signOutFailed, false)
    }
  }

  @Test func signOutDeleteFailureStaysSignedInAndFlagsIt() async {
    var store = PlayolaTokenStore.inMemory([.production: "T"])
    store.delete = { _ in throw PlayolaKeychainError.unexpectedStatus(-25300) }
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
      $0.playolaAPI.currentUser = { _, _ in Self.user }
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account
      await model.appLaunched()

      await model.signOutTapped()

      expectNoDifference(
        account, PlayolaAccount(environment: .production, status: .signedIn(Self.user)))
      expectNoDifference(model.signOutFailed, true)
    }
  }

  @Test func signOutWhileWaitingCancelsTheBrowser() async throws {
    let gate = Gate()
    let store = PlayolaTokenStore.inMemory()
    let cancels = LockIsolated(0)
    try await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
      $0.playolaBrowserAuth = PlayolaBrowserAuthClient(
        authenticate: { _, _ in
          await gate.pass()
          return Self.successCallback
        },
        cancel: { cancels.withValue { $0 += 1 } })
    } operation: {
      let model = PlayolaSessionModel()
      @Shared(.playolaAccount) var account
      await model.appLaunched()

      let task = Task { await model.signInTapped() }
      await gate.waitUntilStarted()
      await model.signOutTapped()

      expectNoDifference(cancels.value, 1)
      expectNoDifference(model.attempt, .idle)

      gate.open()
      await task.value

      let saved = try await store.load(.production)
      expectNoDifference(saved, nil)
      expectNoDifference(model.attempt, .idle)
      expectNoDifference(account, PlayolaAccount(environment: .production, status: .signedOut(nil)))
    }
  }
}

// MARK: - Test doubles

private struct TestError: Error {}

private struct ExchangeRequest: Equatable, Sendable {
  var environment: PlayolaEnvironment
  var code: String
  var codeVerifier: String
}

private struct MeRequest: Equatable, Sendable {
  var environment: PlayolaEnvironment
  var token: String
}

/// Holds a test double mid-call: `pass()` signals `started`, then waits for `open()`.
private struct Gate: Sendable {
  let started = AsyncStream.makeStream(of: Void.self)
  let release = AsyncStream.makeStream(of: Void.self)

  func pass() async {
    started.continuation.yield()
    for await _ in release.stream {}
  }

  func waitUntilStarted() async {
    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
  }

  func open() {
    release.continuation.finish()
  }
}

extension PlayolaBrowserAuthClient {
  fileprivate static func returning(
    _ callback: URL, cancels: LockIsolated<Int> = LockIsolated(0)
  ) -> Self {
    Self(
      authenticate: { _, _ in callback },
      cancel: { cancels.withValue { $0 += 1 } })
  }

  fileprivate static func throwing(_ error: any Error) -> Self {
    Self(authenticate: { _, _ in throw error }, cancel: {})
  }
}
