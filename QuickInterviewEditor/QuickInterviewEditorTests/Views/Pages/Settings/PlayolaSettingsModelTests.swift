import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PlayolaSettingsModelTests {
  nonisolated static let randomBytes = Data(repeating: 7, count: 32)
  nonisolated static let user = PlayolaUser(
    firstName: "Ada", lastName: "Lovelace", email: "ada@example.com")

  static func base(_ values: inout DependencyValues) {
    values.defaultInMemoryStorage = InMemoryStorage()
    values.defaultAppStorage = UserDefaults(suiteName: "playola-settings-\(UUID())")!
    values.secureRandom = .constant(randomBytes)
    values.playolaTokenStore = .inMemory()
  }

  static func makeModel(
    status: PlayolaAccount.Status, allowsServerSwitching: Bool = true
  ) -> PlayolaSettingsModel {
    let session = PlayolaSessionModel(allowsServerSwitching: allowsServerSwitching)
    @Shared(.playolaAccount) var account
    $account.withLock { $0.status = status }
    return PlayolaSettingsModel(session: session)
  }

  @Test func staticCopy() {
    withDependencies {
      Self.base(&$0)
    } operation: {
      let model = Self.makeModel(status: .signedOut(nil))

      expectNoDifference(model.tabTitle, "Playola")
      expectNoDifference(model.tabSystemImage, "person.crop.circle")
      expectNoDifference(model.accountHeader, "Account")
      expectNoDifference(model.serverHeader, "Server (debug builds only)")
      expectNoDifference(model.serverLabel, "Server:")
      expectNoDifference(
        model.serverHelp,
        "Production, Staging, or Local. Each server keeps its own sign-in.")
    }
  }

  @Test func restoringShowsStatusWithNoValueOrButton() {
    withDependencies {
      Self.base(&$0)
    } operation: {
      let model = Self.makeModel(status: .restoring)

      expectNoDifference(model.accountRowLabel, "Status:")
      expectNoDifference(model.accountValue, "")
      expectNoDifference(model.accountDetail, nil)
      expectNoDifference(model.showsAccountButton, false)
    }
  }

  @Test func signedInWithUserShowsNameEmailAndSignOut() {
    withDependencies {
      Self.base(&$0)
    } operation: {
      let model = Self.makeModel(status: .signedIn(Self.user))

      expectNoDifference(model.accountRowLabel, "Signed in as:")
      expectNoDifference(model.accountValue, "Ada Lovelace")
      expectNoDifference(model.accountDetail, "ada@example.com")
      expectNoDifference(model.accountDetailIsError, false)
      expectNoDifference(model.showsAccountButton, true)
      expectNoDifference(model.accountButtonTitle, "Sign Out")
      expectNoDifference(model.accountButtonIsProminent, false)
    }
  }

  @Test func signedInWithoutUserShowsSignedIn() {
    withDependencies {
      Self.base(&$0)
    } operation: {
      let model = Self.makeModel(status: .signedIn(nil))

      expectNoDifference(model.accountRowLabel, "Signed in as:")
      expectNoDifference(model.accountValue, "Signed in")
      expectNoDifference(model.accountDetail, nil)
      expectNoDifference(model.accountButtonTitle, "Sign Out")
    }
  }

  @Test func signedOutShowsNotSignedInAndSignInButton() {
    withDependencies {
      Self.base(&$0)
    } operation: {
      let model = Self.makeModel(status: .signedOut(nil))

      expectNoDifference(model.accountRowLabel, "Status:")
      expectNoDifference(model.accountValue, "Not signed in")
      expectNoDifference(
        model.accountDetail, "Sign in to get ready for future assigned interviews on Playola.")
      expectNoDifference(model.accountDetailIsError, false)
      expectNoDifference(model.showsAccountButton, true)
      expectNoDifference(model.accountButtonTitle, "Sign In with Playola…")
      expectNoDifference(model.accountButtonIsProminent, true)
    }
  }

  @Test func rejectedShowsRejectedDetail() {
    withDependencies {
      Self.base(&$0)
    } operation: {
      let model = Self.makeModel(status: .signedOut(.rejectedByPlayola))

      expectNoDifference(model.accountRowLabel, "Status:")
      expectNoDifference(model.accountValue, "Not signed in")
      expectNoDifference(
        model.accountDetail, "You were signed out of Playola. Sign in again to continue.")
      expectNoDifference(model.accountDetailIsError, false)
      expectNoDifference(model.showsAccountButton, true)
      expectNoDifference(model.accountButtonTitle, "Sign In with Playola…")
      expectNoDifference(model.accountButtonIsProminent, true)
    }
  }

  @Test func tappingTheButtonWhileRestoringDoesNothing() async {
    await withDependencies {
      Self.base(&$0)
    } operation: {
      let model = Self.makeModel(status: .restoring)
      @Shared(.playolaAccount) var account

      expectNoDifference(model.accountButtonTitle, "Sign In with Playola…")
      expectNoDifference(model.accountButtonIsProminent, false)

      await model.accountButtonTapped()

      expectNoDifference(account.status, .restoring)
    }
  }

  @Test func waitingShowsWaitingTextAndCancel() async {
    let gate = Gate()
    await withDependencies {
      Self.base(&$0)
      $0.playolaBrowserAuth = PlayolaBrowserAuthClient(
        authenticate: { _, _ in
          await gate.pass()
          throw PlayolaBrowserAuthError.canceled
        },
        cancel: {})
    } operation: {
      let model = Self.makeModel(status: .signedOut(nil))

      let task = Task { await model.accountButtonTapped() }
      await gate.waitUntilStarted()

      expectNoDifference(model.accountRowLabel, "Status:")
      expectNoDifference(model.accountValue, "Waiting for Playola…")
      expectNoDifference(model.accountDetail, nil)
      expectNoDifference(model.showsAccountButton, true)
      expectNoDifference(model.accountButtonTitle, "Cancel")
      expectNoDifference(model.accountButtonIsProminent, false)

      gate.open()
      await task.value
    }
  }

  @Test func failedShowsErrorDetail() async {
    await withDependencies {
      Self.base(&$0)
      $0.playolaBrowserAuth = PlayolaBrowserAuthClient(
        authenticate: { _, _ in throw URLError(.notConnectedToInternet) },
        cancel: {})
    } operation: {
      let model = Self.makeModel(status: .signedOut(.rejectedByPlayola))

      await model.accountButtonTapped()

      expectNoDifference(model.accountValue, "Not signed in")
      expectNoDifference(
        model.accountDetail,
        "Couldn't sign in to Playola. Check your connection and try again.")
      expectNoDifference(model.accountDetailIsError, true)
      expectNoDifference(model.accountButtonTitle, "Sign In with Playola…")
      expectNoDifference(model.accountButtonIsProminent, true)
    }
  }

  @Test func signOutFailureShowsCouldNotSignOut() async {
    var store = PlayolaTokenStore.inMemory([.production: "T"])
    store.delete = { _ in throw PlayolaKeychainError.unexpectedStatus(-25300) }
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = store
    } operation: {
      let model = Self.makeModel(status: .signedIn(Self.user))

      await model.accountButtonTapped()

      expectNoDifference(model.accountValue, "Ada Lovelace")
      expectNoDifference(model.accountDetail, "Couldn't sign out. Try again.")
      expectNoDifference(model.accountDetailIsError, true)
    }
  }

  @Test func accountButtonTappedSignedInSignsOut() async {
    await withDependencies {
      Self.base(&$0)
      $0.playolaTokenStore = .inMemory([.production: "T"])
    } operation: {
      let model = Self.makeModel(status: .signedIn(Self.user))
      @Shared(.playolaAccount) var account

      await model.accountButtonTapped()

      expectNoDifference(account.status, .signedOut(nil))
    }
  }

  @Test func accountButtonTappedWhileWaitingCancelsTheBrowser() async {
    let gate = Gate()
    let cancels = LockIsolated(0)
    await withDependencies {
      Self.base(&$0)
      $0.playolaBrowserAuth = PlayolaBrowserAuthClient(
        authenticate: { _, _ in
          await gate.pass()
          throw PlayolaBrowserAuthError.canceled
        },
        cancel: { cancels.withValue { $0 += 1 } })
    } operation: {
      let model = Self.makeModel(status: .signedOut(nil))
      let task = Task { await model.accountButtonTapped() }
      await gate.waitUntilStarted()

      await model.accountButtonTapped()
      gate.open()
      await task.value

      expectNoDifference(cancels.value, 1)
      expectNoDifference(model.accountButtonTitle, "Sign In with Playola…")
    }
  }

  @Test func serverPickerHiddenWhenSwitchingNotAllowed() {
    withDependencies {
      Self.base(&$0)
    } operation: {
      let model = Self.makeModel(status: .signedOut(nil), allowsServerSwitching: false)

      expectNoDifference(model.showsServerPicker, false)
    }
  }

  @Test func serverPickerShowsAllEnvironmentsWhenAllowed() {
    withDependencies {
      Self.base(&$0)
    } operation: {
      let model = Self.makeModel(status: .signedOut(nil))

      expectNoDifference(model.showsServerPicker, true)
      expectNoDifference(model.environments, [.production, .staging, .local])
      expectNoDifference(model.selectedEnvironment, .production)
    }
  }

  @Test func environmentPickedSwitchesTheSelectedServer() async {
    await withDependencies {
      Self.base(&$0)
    } operation: {
      let model = Self.makeModel(status: .signedOut(nil))

      await model.environmentPicked(.staging)

      expectNoDifference(model.selectedEnvironment, .staging)
    }
  }
}

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
