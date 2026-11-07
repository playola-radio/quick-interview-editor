import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WelcomePageTests {
  nonisolated static let nonEmptyPhases: [ProjectModel.Phase] = [
    .queued, .transcribing(nil), .loaded, .failed("x"),
  ]

  static func base(_ values: inout DependencyValues) {
    values.defaultInMemoryStorage = InMemoryStorage()
    values.defaultAppStorage = UserDefaults(suiteName: "welcome-page-\(UUID())")!
    values.secureRandom = .constant(Data(repeating: 7, count: 32))
    values.playolaTokenStore = .inMemory()
  }

  static func emptyProject() -> ProjectModel {
    let (sink, _) = ProjectDocumentSink.recorder()
    return ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
  }

  static func signedOutSession() async -> PlayolaSessionModel {
    let session = PlayolaSessionModel()
    await session.appLaunched()
    return session
  }

  // MARK: - Gate

  @Test func gateShowsWelcomeForEmptyProjectWhileSignedOut() async {
    await withDependencies {
      Self.base(&$0)
    } operation: {
      let session = await Self.signedOutSession()
      let model = WelcomePageModel(session: session, project: Self.emptyProject())

      expectNoDifference(model.gate, .welcome)
    }
  }

  @Test func gateWaitsWhileRestoring() {
    withDependencies {
      Self.base(&$0)
    } operation: {
      let session = PlayolaSessionModel()
      let model = WelcomePageModel(session: session, project: Self.emptyProject())

      expectNoDifference(model.gate, .waitingForRestore)
    }
  }

  @Test func gateIsPassThroughWhenSignedIn() {
    withDependencies {
      Self.base(&$0)
    } operation: {
      let session = PlayolaSessionModel()
      @Shared(.playolaAccount) var account
      $account.withLock { $0.status = .signedIn(nil) }
      let model = WelcomePageModel(session: session, project: Self.emptyProject())

      expectNoDifference(model.gate, .passThrough)
    }
  }

  @Test(arguments: nonEmptyPhases)
  func gateIsPassThroughForNonEmptyPhases(phase: ProjectModel.Phase) async {
    await withDependencies {
      Self.base(&$0)
    } operation: {
      let session = await Self.signedOutSession()
      let project = Self.emptyProject()
      project.phase = phase
      let model = WelcomePageModel(session: session, project: project)

      expectNoDifference(model.gate, .passThrough)
    }
  }

  @Test func gateFollowsTheProjectLeavingEmpty() async {
    await withDependencies {
      Self.base(&$0)
    } operation: {
      let session = await Self.signedOutSession()
      let project = Self.emptyProject()
      let model = WelcomePageModel(session: session, project: project)

      project.phase = .queued

      expectNoDifference(model.gate, .passThrough)
    }
  }

  @Test func useLocalFileTappedPassesThroughForThisWindowOnly() async {
    await withDependencies {
      Self.base(&$0)
    } operation: {
      let session = await Self.signedOutSession()
      let first = WelcomePageModel(session: session, project: Self.emptyProject())
      let second = WelcomePageModel(session: session, project: Self.emptyProject())

      first.useLocalFileTapped()

      expectNoDifference(first.gate, .passThrough)
      expectNoDifference(second.gate, .welcome)
    }
  }

  @Test func gateMovesToPassThroughWhenSignInCompletesWhileAlive() async {
    await withDependencies {
      Self.base(&$0)
    } operation: {
      let session = await Self.signedOutSession()
      let model = WelcomePageModel(session: session, project: Self.emptyProject())
      expectNoDifference(model.gate, .welcome)

      @Shared(.playolaAccount) var account
      $account.withLock { $0.status = .signedIn(nil) }

      expectNoDifference(model.gate, .passThrough)
    }
  }

  // MARK: - Drop

  @Test func fileDroppedImportsAndPassesThrough() async {
    let picked = LockIsolated<URL?>(nil)
    await withDependencies {
      Self.base(&$0)
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.transcription.transcribe = { url, _, _ in
        picked.setValue(url)
        return neverCompletingEngineEvents()
      }
    } operation: {
      let session = await Self.signedOutSession()
      let project = Self.emptyProject()
      let model = WelcomePageModel(session: session, project: project)

      let taken = model.fileDropped(
        [URL(fileURLWithPath: "/song.m4a")], modelSetupRequired: false)

      #expect(taken)
      expectNoDifference(model.gate, .passThrough)
      for _ in 0..<1000 where picked.value == nil { await Task.yield() }
      expectNoDifference(picked.value?.path, "/song.m4a")
      #expect(project.showsProgress)
      project.cancelTranscriptionTapped()
    }
  }

  @Test func fileDroppedWhileModelSetupIsRequiredPassesThroughWithoutImporting() async {
    await withDependencies {
      Self.base(&$0)
    } operation: {
      let session = await Self.signedOutSession()
      let project = Self.emptyProject()
      let model = WelcomePageModel(session: session, project: project)

      let taken = model.fileDropped(
        [URL(fileURLWithPath: "/song.m4a")], modelSetupRequired: true)

      #expect(!taken)
      expectNoDifference(model.gate, .passThrough)
      expectNoDifference(project.phase, .empty)
    }
  }

  @Test func fileDroppedIgnoresNonAudioFiles() async {
    await withDependencies {
      Self.base(&$0)
    } operation: {
      let session = await Self.signedOutSession()
      let project = Self.emptyProject()
      let model = WelcomePageModel(session: session, project: project)

      let taken = model.fileDropped(
        [URL(fileURLWithPath: "/doc.pdf")], modelSetupRequired: false)

      #expect(!taken)
      expectNoDifference(model.gate, .welcome)
      expectNoDifference(project.phase, .empty)
    }
  }

  // MARK: - Copy

  @Test func signedOutStateCopy() async {
    await withDependencies {
      Self.base(&$0)
    } operation: {
      let session = await Self.signedOutSession()
      let model = WelcomePageModel(session: session, project: Self.emptyProject())

      expectNoDifference(model.title, "Welcome to Playola Interview Editor")
      expectNoDifference(
        model.message, "Sign in with your Playola account to get the interviews assigned to you.")
      expectNoDifference(model.notice, nil)
      expectNoDifference(model.showsProgress, false)
      expectNoDifference(model.showsSignInButtons, true)
      expectNoDifference(model.signInButtonTitle, "Sign In with Playola…")
      expectNoDifference(model.localFileButtonTitle, "Use a Local Audio File")
      expectNoDifference(model.showsCancelButton, false)
      expectNoDifference(model.cancelButtonTitle, "Cancel")
    }
  }

  @Test func waitingStateShowsProgressAndCancelOnly() async {
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
      let session = await Self.signedOutSession()
      let model = WelcomePageModel(session: session, project: Self.emptyProject())

      let task = Task { await model.signInTapped() }
      await gate.waitUntilStarted()

      expectNoDifference(model.showsProgress, true)
      expectNoDifference(model.waitingText, "Waiting for Playola…")
      expectNoDifference(
        model.message,
        "Finish signing in in your browser. This window continues on its own when you're done.")
      expectNoDifference(model.showsCancelButton, true)
      expectNoDifference(model.showsSignInButtons, false)
      expectNoDifference(model.notice, nil)

      gate.open()
      await task.value
    }
  }

  @Test func cancelTappedReturnsToSignInButtons() async {
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
      let session = await Self.signedOutSession()
      let model = WelcomePageModel(session: session, project: Self.emptyProject())
      let task = Task { await model.signInTapped() }
      await gate.waitUntilStarted()

      model.cancelTapped()

      expectNoDifference(model.showsProgress, false)
      expectNoDifference(model.showsSignInButtons, true)
      expectNoDifference(model.showsCancelButton, false)

      gate.open()
      await task.value
    }
  }

  @Test func failedStateShowsErrorNoticeAndTryAgain() async {
    await withDependencies {
      Self.base(&$0)
      $0.playolaBrowserAuth = PlayolaBrowserAuthClient(
        authenticate: { _, _ in throw URLError(.notConnectedToInternet) }, cancel: {})
    } operation: {
      let session = await Self.signedOutSession()
      let model = WelcomePageModel(session: session, project: Self.emptyProject())

      await model.signInTapped()

      expectNoDifference(
        model.notice,
        .error("Couldn't sign in to Playola. Check your connection and try again."))
      expectNoDifference(model.signInButtonTitle, "Try Again")
      expectNoDifference(model.showsSignInButtons, true)
      expectNoDifference(model.gate, .welcome)
    }
  }

  @Test func rejectedStateShowsWarningNotice() async {
    await withDependencies {
      Self.base(&$0)
    } operation: {
      let session = await Self.signedOutSession()
      @Shared(.playolaAccount) var account
      $account.withLock { $0.status = .signedOut(.rejectedByPlayola) }
      let model = WelcomePageModel(session: session, project: Self.emptyProject())

      expectNoDifference(
        model.notice, .warning("You were signed out of Playola. Sign in again to continue."))
      expectNoDifference(model.signInButtonTitle, "Sign In with Playola…")
      expectNoDifference(model.gate, .welcome)
    }
  }

  @Test func failedNoticeWinsOverRejectedWarning() async {
    await withDependencies {
      Self.base(&$0)
      $0.playolaBrowserAuth = PlayolaBrowserAuthClient(
        authenticate: { _, _ in throw URLError(.notConnectedToInternet) }, cancel: {})
    } operation: {
      let session = await Self.signedOutSession()
      @Shared(.playolaAccount) var account
      $account.withLock { $0.status = .signedOut(.rejectedByPlayola) }
      let model = WelcomePageModel(session: session, project: Self.emptyProject())

      await model.signInTapped()

      expectNoDifference(
        model.notice,
        .error("Couldn't sign in to Playola. Check your connection and try again."))
    }
  }

  @Test func rejectedWarningHidesWhileWaiting() async {
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
      let session = await Self.signedOutSession()
      @Shared(.playolaAccount) var account
      $account.withLock { $0.status = .signedOut(.rejectedByPlayola) }
      let model = WelcomePageModel(session: session, project: Self.emptyProject())

      let task = Task { await model.signInTapped() }
      await gate.waitUntilStarted()

      expectNoDifference(model.notice, nil)

      gate.open()
      await task.value
    }
  }

  // MARK: - Windows

  @Test func welcomeMirrorsSessionAttemptAcrossWindows() async {
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
      let session = await Self.signedOutSession()
      let first = WelcomePageModel(session: session, project: Self.emptyProject())
      let second = WelcomePageModel(session: session, project: Self.emptyProject())

      let task = Task { await first.signInTapped() }
      await gate.waitUntilStarted()

      expectNoDifference(first.showsProgress, true)
      expectNoDifference(second.showsProgress, true)
      expectNoDifference(second.showsCancelButton, true)
      expectNoDifference(second.showsSignInButtons, false)

      gate.open()
      await task.value

      expectNoDifference(second.showsProgress, false)
      expectNoDifference(second.showsSignInButtons, true)
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
