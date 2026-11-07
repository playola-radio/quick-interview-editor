# Playola Sign-in Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an editor sign in to Playola through the browser, stay signed in across launches, see who they are in Settings ▸ Playola, and see a Welcome screen in empty windows while signed out — without changing anything that works today.

**Architecture:** One app-scoped `@MainActor @Observable PlayolaSessionModel` (held by the App struct like `AppLaunchModel`) is the only writer of `@Shared(.playolaAccount)`. Three new dependency clients wrap the side effects: `PlayolaTokenStore` (Keychain), `PlayolaAPIClient` (URLSession) and `PlayolaBrowserAuthClient` (`ASWebAuthenticationSession`), plus `SecureRandomClient` for PKCE bytes. `WelcomePageModel` (per window) and `PlayolaSettingsModel` read the session and hold all copy and flags; `ProjectHostView` only branches on `WelcomePageModel.gate`.

**Tech Stack:** Swift 6, SwiftUI (macOS 15), swift-dependencies, swift-sharing, Swift Testing + swift-custom-dump, Security, CryptoKit, AuthenticationServices, URLSession.

**Spec:** `docs/superpowers/specs/2026-11-07-playola-sign-in-design.md` (approved 2026-11-07), with `design/features/playola-sign-in/{screens,endpoints,models}.md`. Read all four before starting.

## Global Constraints

- Every implementer invokes the applicable `pfw-*` skills before writing Swift and lists them in their checklist: `pfw-dependencies`, `pfw-observable-models`, `pfw-sharing`, `pfw-testing`, `pfw-custom-dump`, `pfw-modern-swiftui` (views), `pfw-case-paths` (enum assertions).
- MV pattern per `CLAUDE.md`: `@MainActor @Observable final class X: ViewModel`, MARK sections in order (Dependencies, Shared State, Initialization, Properties, View Helpers, User Actions, Private Helpers). **Views contain zero logic and zero literal strings.**
- Model methods that do async work are `async`; the view creates the `Task`. Don't start work in a model's `init`.
- Tests: Swift Testing, `@MainActor struct …Tests`, `expectNoDifference` for value comparisons, `withDependencies`, `@Shared` declared locally, **no `Task.sleep`**, **no network, Keychain, browser or engine**. Every test that touches `@Shared` sets `$0.defaultInMemoryStorage = InMemoryStorage()` and `$0.defaultAppStorage = UserDefaults(suiteName: "<name>-\(UUID())")!`.
- Don't link `Dependencies` (or anything the app target already links) to the test target.
- Keychain service literal: `fm.playola.PlayolaInterviewEditor.playolaToken`; account = environment raw value. `KeychainClient` / `KeychainStore` are **not touched**.
- Bundle id `fm.playola.PlayolaInterviewEditor`, team `FSRSPV9N9Q` unchanged.
- Callback scheme `playola-interview-editor`; the callback must be exactly `playola-interview-editor://auth/callback`.
- Base URLs: production `https://admin-api.playola.fm`, staging `https://admin-api-staging.playola.fm`, local `http://localhost:10020`. Release builds always use production.
- Paths: `GET /v1/auth/desktop/authorize?state&code_challenge&code_challenge_method=S256` (no `provider`), `POST /v1/auth/desktop/token {code, codeVerifier}` → `{playolaToken}`, `GET /v1/users/me` with `Authorization: Bearer <token>`.
- Never log the token, the code, the verifier or the state. Use `AppLog.playola`.
- Must compile on Xcode 16.4 (CI) under Swift 6 strict concurrency. Nonisolated AppKit/AuthenticationServices callbacks that touch main-actor state use `MainActor.assumeIsolated` (see `AppDelegate`).
- Use `…` (U+2026) in copy, never `...`.
- Iterate with `make test-fast ONLY=PlayolaInterviewEditorTests/<Suite>` from `QuickInterviewEditor/`. Run `make generate` **only** in Task 1 (the one `project.yml` change). Before the final commit: full `make test-fast`, `make format-check`, `make lint`.
- Commits: no `Co-Authored-By` or other trailers.

### Exact copy (from `design/interview-editor.pen` section 09)

| Key | Text |
|---|---|
| welcome title | `Welcome to Playola Interview Editor` |
| welcome message | `Sign in with your Playola account to get the interviews assigned to you.` |
| welcome waiting message | `Finish signing in in your browser. This window continues on its own when you're done.` |
| waiting status | `Waiting for Playola…` |
| sign-in button | `Sign In with Playola…` |
| retry button (Welcome failed state) | `Try Again` |
| local-file button | `Use a Local Audio File` |
| cancel button | `Cancel` |
| sign-in failed | `Couldn't sign in to Playola. Check your connection and try again.` |
| rejected by Playola | `You were signed out of Playola. Sign in again to continue.` |
| settings tab | `Playola` (system image `person.crop.circle`) |
| settings account header | `Account` |
| signed-in row label / value | `Signed in as:` / `<firstName> <lastName>` (just `firstName` when `lastName` is nil), detail = email |
| signed in, no user yet | value `Signed in`, no detail |
| signed-out row label / value / detail | `Status:` / `Not signed in` / `Sign in to get the interviews assigned to you on Playola.` |
| sign-out button | `Sign Out` |
| sign-out failed (detail) | `Couldn't sign out. Try again.` |
| server header / label / help | `Server (debug builds only)` / `Server:` / `Production, Staging, or Local. Each server keeps its own sign-in.` |

## Review Focus

1. **Opening an existing `.pie` while signed out** must open the project, never Welcome (it starts `.queued`). Pinned by `gateIsPassThroughForNonEmptyPhases` in Task 7.
2. **A Keychain read error at launch** must leave the item alone and show signed out. Pinned by `restoreKeychainErrorSignsOutWithoutDeleting` in Task 6.
3. **A late answer from an old attempt or server** must not publish or save: `/me` after sign-out, an exchange after Cancel, a switch away and back mid-restore. Pinned by the `stale…` tests in Task 6.
4. **The token never goes to another server.** Pinned by `currentUserRequestTargetsEnvironmentBaseURL` and `noRedirectDelegateRefusesRedirects` (Task 4) and `serverSwitchLoadsOnlyThatServersToken` (Task 6).
5. **Closing the window that started sign-in** must not abort the attempt, and every other empty window keeps mirroring it. Views start sign-in with `Task { await model.signInTapped() }`, never `.task {}`, and the attempt state lives on the session, not the window. Pinned by `welcomeMirrorsSessionAttemptAcrossWindows` in Task 7.

## File map

Create (app, under `QuickInterviewEditor/QuickInterviewEditor/`):
- `Models/PlayolaEnvironment.swift`: environment enum, base URLs, labels, Release resolution
- `Models/PlayolaAccount.swift`: `PlayolaAccount`, `PlayolaUser`
- `State/PlayolaAccountKeys.swift`: `.playolaAccount` (in memory), `.playolaEnvironment` (appStorage)
- `Core/SecureRandomClient.swift`: random bytes dependency
- `Core/PlayolaTokenStore.swift`: Keychain token dependency, plus `PlayolaKeychain` live wrapper
- `Core/PlayolaAPIClient.swift`: API dependency, request builders, response mapping, DTOs, no-redirect delegate
- `Core/PlayolaBrowserAuthClient.swift`: `ASWebAuthenticationSession` dependency
- `Views/Pages/PlayolaSession/PlayolaPKCE.swift`: PKCE, authorize URL and callback validation (pure)
- `Views/Pages/PlayolaSession/PlayolaSessionModel.swift`
- `Views/Pages/Welcome/WelcomePageModel.swift`, `WelcomePageView.swift`
- `Views/Pages/Settings/PlayolaSettingsModel.swift`, `PlayolaSettingsView.swift`

Modify: `Core/AppLog.swift` (`playola` category), `project.yml` (ATS), `Views/Pages/Project/ProjectHostView.swift` (gate), `QuickInterviewEditorApp.swift` (session, restore, fifth tab).

Tests (under `QuickInterviewEditor/QuickInterviewEditorTests/`): `Models/PlayolaEnvironmentTests.swift`, `Core/PlayolaTokenStoreTests.swift`, `Core/PlayolaAPIClientTests.swift`, `Views/Pages/PlayolaSession/PlayolaPKCETests.swift`, `Views/Pages/PlayolaSession/PlayolaSessionModelTests.swift`, `Views/Pages/Welcome/WelcomePageTests.swift`, `Views/Pages/Settings/PlayolaSettingsModelTests.swift`. (If `QuickInterviewEditorTests/Models/` doesn't exist, put the environment tests next to the closest existing model tests.)

---

### Task 1: Environment, account types, shared keys, logging, ATS

**Files:**
- Create: `Models/PlayolaEnvironment.swift`, `Models/PlayolaAccount.swift`, `State/PlayolaAccountKeys.swift`
- Modify: `Core/AppLog.swift`, `project.yml` (`targets.PlayolaInterviewEditor.info.properties`)
- Test: `QuickInterviewEditorTests/Models/PlayolaEnvironmentTests.swift`

**Interfaces:**
- Produces:
  - `enum PlayolaEnvironment: String, Codable, CaseIterable, Sendable { case production, staging, local }` with `var baseURL: URL`, `var label: String` ("Production" / "Staging" / "Local"), `static var allowsSwitching: Bool` (`true` in DEBUG, `false` otherwise), `static func resolved(_ setting: PlayolaEnvironment, allowsSwitching: Bool) -> PlayolaEnvironment`.
  - `PlayolaAccount` and `PlayolaUser` exactly as in `models.md`, plus `PlayolaUser: Decodable` (keys `id`, `firstName`, `lastName?`, `email`; unknown keys ignored) and `var displayName: String` on `PlayolaUser`.
  - `PlayolaAccount.isSignedOut: Bool` (true for any `.signedOut`).
  - `@Shared(.playolaAccount)`: `InMemoryKey<PlayolaAccount>`, key `"playolaAccount"`, default `PlayolaAccount(environment: .production, status: .restoring)`.
  - `@Shared(.playolaEnvironment)`: `AppStorageKey<PlayolaEnvironment>`, key `"playolaEnvironment"`, default `.production`.
  - `AppLog.playola` (`category: "playola"`).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func baseURLsMatchIOSConfig() {
  expectNoDifference(PlayolaEnvironment.production.baseURL.absoluteString, "https://admin-api.playola.fm")
  expectNoDifference(PlayolaEnvironment.staging.baseURL.absoluteString, "https://admin-api-staging.playola.fm")
  expectNoDifference(PlayolaEnvironment.local.baseURL.absoluteString, "http://localhost:10020")
}
@Test func releaseAlwaysResolvesToProduction() {
  expectNoDifference(PlayolaEnvironment.resolved(.staging, allowsSwitching: false), .production)
  expectNoDifference(PlayolaEnvironment.resolved(.local, allowsSwitching: true), .local)
}
@Test func displayNameJoinsFirstAndLastName() {
  expectNoDifference(PlayolaUser(id: "u", firstName: "Brian", lastName: "Keane", email: "b@p.fm").displayName, "Brian Keane")
  expectNoDifference(PlayolaUser(id: "u", firstName: "Brian", lastName: nil, email: "b@p.fm").displayName, "Brian")
}
```

- [ ] **Step 2: Run, expect a compile failure** (`make test-fast ONLY=PlayolaInterviewEditorTests/PlayolaEnvironmentTests`).
- [ ] **Step 3: Implement the files above.** In `project.yml` add under `info.properties`:

```yaml
        # Scoped ATS exception so debug builds can reach the local Playola server
        # (http://localhost:10020). Not arbitrary loads.
        NSAppTransportSecurity:
          NSAllowsLocalNetworking: true
```

  Then run `make generate` (once) and confirm the generated `Info.plist` contains `NSAllowsLocalNetworking`.
- [ ] **Step 4: Run the tests and confirm they pass.**
- [ ] **Step 5: Commit:** `feat: add Playola environments and account types`.

---

### Task 2: PKCE, authorize URL and callback validation

**Files:**
- Create: `Core/SecureRandomClient.swift`, `Views/Pages/PlayolaSession/PlayolaPKCE.swift`
- Test: `QuickInterviewEditorTests/Views/Pages/PlayolaSession/PlayolaPKCETests.swift`

**Interfaces:**
- Consumes: `PlayolaEnvironment.baseURL`.
- Produces:
  - `struct SecureRandomClient: Sendable { var bytes: @Sendable (Int) -> Data }`, a `\.secureRandom` accessor. `liveValue` uses `SecRandomCopyBytes`. `testValue` returns `Data(repeating: 0, count: n)`. Add `static func constant(_ data: Data) -> SecureRandomClient`.
  - `struct PlayolaAuthAttempt: Equatable, Sendable { let state: String; let verifier: String; let challenge: String }`
  - `enum PlayolaPKCE`:
    - `static let callbackScheme = "playola-interview-editor"`
    - `static func base64URL(_ data: Data) -> String` (no padding, `+`→`-`, `/`→`_`)
    - `static func makeAttempt(stateBytes: Data, verifierBytes: Data) -> PlayolaAuthAttempt`. The challenge is `base64URL(SHA256(ascii(verifier)))` via CryptoKit.
    - `static func authorizeURL(environment: PlayolaEnvironment, attempt: PlayolaAuthAttempt) -> URL`
    - `static func code(fromCallback url: URL, expectedState: String) throws(PlayolaCallbackError) -> String`
  - `enum PlayolaCallbackError: Error, Equatable { case invalidCallback, providerError }`

- [ ] **Step 1: Write the failing tests.** Use the RFC 7636 Appendix B vector:

```swift
static let rfcVerifierBytes = Data([116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
                                    22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121])

@Test func attemptMatchesRFC7636Vector() {
  let attempt = PlayolaPKCE.makeAttempt(stateBytes: Data(repeating: 1, count: 32), verifierBytes: Self.rfcVerifierBytes)
  expectNoDifference(attempt.verifier, "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
  expectNoDifference(attempt.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}
@Test func authorizeURLHasStateChallengeAndS256AndNoProvider()
  // URLComponents of the result: host admin-api-staging.playola.fm, path /v1/auth/desktop/authorize,
  // query items exactly [state, code_challenge, code_challenge_method=S256]; no "provider".
@Test func callbackWithMatchingStateReturnsCode()
  // playola-interview-editor://auth/callback?code=abc&state=S → "abc"
@Test func callbackRejectsWrongSchemeHostOrPath()        // each → .invalidCallback
@Test func callbackRejectsMissingOrDuplicateCode()       // → .invalidCallback
@Test func callbackRejectsMismatchedState()              // → .invalidCallback
@Test func callbackWithErrorParameterIsProviderError()   // ?error=access_denied&state=S → .providerError
```

  Assert thrown errors with `#expect(throws: PlayolaCallbackError.invalidCallback) { … }`.
- [ ] **Step 2: Run and confirm the tests fail.**
- [ ] **Step 3: Implement.** Generate `state` and `verifier` with `base64URL` of 32 bytes each. Validation order: `error=` present → `.providerError`; then scheme, host `auth` and path `/callback` must match exactly; then exactly one `code` and exactly one `state` equal to `expectedState`.
- [ ] **Step 4: Run the tests and confirm they pass.**
- [ ] **Step 5: Commit:** `feat: add PKCE and sign-in callback checks`.

---

### Task 3: Token store (Keychain)

**Files:**
- Create: `Core/PlayolaTokenStore.swift`
- Test: `QuickInterviewEditorTests/Core/PlayolaTokenStoreTests.swift`

**Interfaces:**
- Consumes: `PlayolaEnvironment`, `AppLog.playola`.
- Produces:
  - `struct PlayolaTokenStore: Sendable { var load: @Sendable (PlayolaEnvironment) async throws -> String?; var save: @Sendable (String, PlayolaEnvironment) async throws -> Void; var delete: @Sendable (PlayolaEnvironment) async throws -> Void }`, accessor `\.playolaTokenStore`.
  - `testValue`/`previewValue`: `.inMemory()`. Add `static func inMemory(_ initial: [PlayolaEnvironment: String] = [:]) -> PlayolaTokenStore` backed by `Mutex`.
  - `enum PlayolaKeychain`: `static let service = "fm.playola.PlayolaInterviewEditor.playolaToken"`, `static func token(from data: Data) throws(PlayolaKeychainError) -> String`, and the synchronous `load/save/delete(environment:)`.
  - `enum PlayolaKeychainError: Error, Equatable { case unexpectedStatus(OSStatus), unreadableData }`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func serviceIdIsStable() {
  expectNoDifference(PlayolaKeychain.service, "fm.playola.PlayolaInterviewEditor.playolaToken")
}
@Test func nonUTF8ItemDataIsAnErrorNotAbsent() {
  #expect(throws: PlayolaKeychainError.unreadableData) { try PlayolaKeychain.token(from: Data([0xFF, 0xFE])) }
}
@Test func inMemoryStoreKeepsEachEnvironmentSeparate() async throws
  // save "p" for .production and "s" for .staging; load(.staging) == "s"; delete(.staging); load(.production) == "p"
```

- [ ] **Step 2: Run and confirm the tests fail.**
- [ ] **Step 3: Implement.**
  - The live Keychain code mirrors `KeychainStore` (update, then add, then retry the update on a duplicate), with account = `environment.rawValue`.
  - `load` returns nil **only** for `errSecItemNotFound`. Bad data throws `.unreadableData`.
  - `delete` treats `errSecItemNotFound` as success.
  - The live `liveValue` runs every call on **one private serial `DispatchQueue`**, wrapped in `withCheckedThrowingContinuation`, so calls run in the order they were made (not an actor, whose job order isn't FIFO).
- [ ] **Step 4: Run the tests and confirm they pass.**
- [ ] **Step 5: Commit:** `feat: store the Playola sign-in in the Keychain per server`.

---

### Task 4: API client

**Files:**
- Create: `Core/PlayolaAPIClient.swift`
- Test: `QuickInterviewEditorTests/Core/PlayolaAPIClientTests.swift`

**Interfaces:**
- Consumes: `PlayolaEnvironment`, `PlayolaUser`.
- Produces:
  - `struct PlayolaAPIClient: Sendable { var exchangeCode: @Sendable (_ environment: PlayolaEnvironment, _ code: String, _ codeVerifier: String) async throws -> String; var currentUser: @Sendable (_ environment: PlayolaEnvironment, _ token: String) async throws -> PlayolaUser }`, accessor `\.playolaAPI`. `testValue` has both closures `unimplemented(...)` (IssueReporting).
  - `enum PlayolaAPIError: Error, Equatable { case unauthorized, badStatus(Int), invalidResponse }`
  - `enum PlayolaAPIRequests`: `static func exchange(environment:code:codeVerifier:) -> URLRequest` (POST JSON `{"code","codeVerifier"}`, no `Authorization`), `static func currentUser(environment:token:) -> URLRequest` (GET, `Authorization: Bearer <token>`).
  - `enum PlayolaAPIResponse`: `static func validated(_ data: Data, _ response: URLResponse) throws(PlayolaAPIError) -> Data` (401 → `.unauthorized`, other non-2xx → `.badStatus`, non-HTTP → `.invalidResponse`).
  - `struct DesktopTokenResponse: Decodable { let playolaToken: String }`
  - `final class PlayolaNoRedirectDelegate: NSObject, URLSessionTaskDelegate`, which completes every redirect with `nil`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func currentUserRequestTargetsEnvironmentBaseURL() {
  let request = PlayolaAPIRequests.currentUser(environment: .staging, token: "T")
  expectNoDifference(request.url?.absoluteString, "https://admin-api-staging.playola.fm/v1/users/me")
  expectNoDifference(request.value(forHTTPHeaderField: "Authorization"), "Bearer T")
}
@Test func exchangeRequestPostsCodeAndVerifierWithoutAuthorization()
  // POST https://admin-api.playola.fm/v1/auth/desktop/token, JSON body decodes to ["code": "c", "codeVerifier": "v"],
  // Authorization header nil, Content-Type application/json
@Test func unauthorizedStatusMapsToUnauthorized()      // 401 → .unauthorized
@Test func otherStatusMapsToBadStatus()                // 500 → .badStatus(500), 400 → .badStatus(400)
@Test func userDecodesWithNullLastNameAndUnknownFields()
  // {"id":"u1","firstName":"Ana","lastName":null,"email":"a@p.fm","role":"admin","profileImageUrl":"x"}
  // → PlayolaUser(id: "u1", firstName: "Ana", lastName: nil, email: "a@p.fm")
@Test func tokenResponseDecodes()                      // {"playolaToken":"eyJ"} → "eyJ"
@Test func noRedirectDelegateRefusesRedirects() async
  // call urlSession(_:task:willPerformHTTPRedirection:newRequest:) and assert it returns nil
```

- [ ] **Step 2: Run and confirm the tests fail.**
- [ ] **Step 3: Implement `liveValue`.**
  - Use one `URLSession(configuration: .ephemeral, delegate: PlayolaNoRedirectDelegate(), delegateQueue: nil)`.
  - Each call is `session.data(for: PlayolaAPIRequests…)`, then `PlayolaAPIResponse.validated`, then `JSONDecoder` decoding.
  - Log failures with `AppLog.playola`, using the status code and the error type only.
- [ ] **Step 4: Run the tests and confirm they pass.**
- [ ] **Step 5: Commit:** `feat: add the Playola API client`.

---

### Task 5: Browser auth client

**Files:**
- Create: `Core/PlayolaBrowserAuthClient.swift`

**Interfaces:**
- Produces:
  - `struct PlayolaBrowserAuthClient: Sendable { var authenticate: @MainActor @Sendable (_ url: URL, _ callbackScheme: String) async throws -> URL; var cancel: @MainActor @Sendable () -> Void }`, accessor `\.playolaBrowserAuth`. `testValue` is `unimplemented(...)` for `authenticate` and a no-op for `cancel`.
  - `enum PlayolaBrowserAuthError: Error, Equatable { case canceled, couldNotStart }`

- [ ] **Step 1: Implement the live value.** A `@MainActor final class PlayolaWebAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding` owns the in-flight session, a `CheckedContinuation`, and a `finished` flag so the continuation resumes **exactly once**. The live client holds one shared instance.
  - **Anchor:** captured at start as `NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()`. `presentationAnchor(for:)` is nonisolated on the SDK, so return the stored anchor via `MainActor.assumeIsolated`.
  - **Completion handler:** hop to the main actor. A URL resumes with the URL. `ASWebAuthenticationSessionError.canceledLogin` resumes with `.canceled`. Any other error resumes with that error.
  - **Start failure:** `start()` returning `false` resumes with `.couldNotStart`.
  - **Session setup:** `prefersEphemeralWebBrowserSession = false`.
  - **`cancel`:** calls `session.cancel()` and resumes with `.canceled` if the session hasn't finished.
  - **A second `authenticate` while one is running:** cancel the old one first (the session model never does this, but the client must not leak a continuation).
- [ ] **Step 2: Build.** Run `make test-fast ONLY=PlayolaInterviewEditorTests/PlayolaPKCETests`. The build must succeed with no concurrency warnings in this file. There are no unit tests: this needs a real browser, and manual QA covers it.
- [ ] **Step 3: Commit:** `feat: run Playola sign-in in the browser`.

---

### Task 6: PlayolaSessionModel

**Files:**
- Create: `Views/Pages/PlayolaSession/PlayolaSessionModel.swift`
- Test: `QuickInterviewEditorTests/Views/Pages/PlayolaSession/PlayolaSessionModelTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces:

```swift
@MainActor @Observable final class PlayolaSessionModel: ViewModel {
  enum Attempt: Equatable { case idle, waiting, failed }
  // Shared State
  @ObservationIgnored @Shared(.playolaAccount) var account
  @ObservationIgnored @Shared(.playolaEnvironment) var environmentSetting
  // Properties
  let allowsServerSwitching: Bool
  private(set) var attempt: Attempt = .idle
  private(set) var signOutFailed = false
  init(allowsServerSwitching: Bool = PlayolaEnvironment.allowsSwitching)
  // User Actions
  func appLaunched() async            // restore once per launch; second call is a no-op
  func signInTapped() async           // no-op while .waiting or when signed in
  func cancelSignInTapped()
  func signOutTapped() async
  func environmentPicked(_ environment: PlayolaEnvironment) async
}
```

  Private state: `token: String?`, `generation: Int`, `didLaunch: Bool`. The only side effect allowed in `init` is setting `account.environment = PlayolaEnvironment.resolved(environmentSetting, allowsSwitching:)`, with the status left `.restoring`.

**Behavior** (each async step captures `(environment, generation)` before awaiting and returns silently if either changed when it resumes):
- **Restore:**
  - `load` returning a token → `.signedIn(nil)`, then `/me`.
  - `load` returning nil → `.signedOut(nil)`.
  - `load` throwing → log it, `.signedOut(nil)`, and **never** call `delete`.
- **`/me`:**
  - Success → `.signedIn(user)`.
  - `.unauthorized` → check the generation, delete the token (log a delete failure), clear `token`, and set `.signedOut(.rejectedByPlayola)`.
  - Any other error → log it and stay `.signedIn(nil)`.
- **Sign in:**
  1. Bump the generation and set `attempt = .waiting`.
  2. Build the attempt with `PlayolaPKCE.makeAttempt` from `secureRandom.bytes(32)`, called twice.
  3. Run `browserAuth.authenticate(authorizeURL, PlayolaPKCE.callbackScheme)`.
  4. Validate with `PlayolaPKCE.code(fromCallback:expectedState:)`.
  5. Call `api.exchangeCode`, check the generation, then `tokenStore.save`, then check the generation again.
  6. Set `.signedIn(nil)`, `attempt = .idle`, `signOutFailed = false`, then run `/me`.
  - On failure: `.canceled` → `.idle`; anything else (including a save failure) → log the error type and set `.failed`. Both apply only if the generation still matches.
- **Cancel:** only while `.waiting`. Bump the generation, set `attempt = .idle`, and call `browserAuth.cancel()`.
- **Sign out:**
  - Bump the generation, then `tokenStore.delete(environment)`.
  - Success → clear `token`, set `.signedOut(nil)`, `signOutFailed = false`.
  - Throw → stay signed in, set `signOutFailed = true`.
- **Environment picked:**
  - Ignored when `!allowsServerSwitching` or the environment is unchanged.
  - Otherwise: bump the generation, cancel the browser if `.waiting`, and reset `attempt = .idle` and `signOutFailed = false`.
  - Write `environmentSetting`, clear `token`, set `account = PlayolaAccount(environment: new, status: .restoring)`, then restore.

- [ ] **Step 1: Write the failing tests.** Every test wraps model creation and the actions in `withDependencies { $0.defaultInMemoryStorage = InMemoryStorage(); $0.defaultAppStorage = …; $0.secureRandom = .constant(Data(repeating: 7, count: 32)); … }` and reads the account through a local `@Shared(.playolaAccount) var account`.
  - **Callback stub:** for a successful browser stub, compute the state with `PlayolaPKCE.base64URL(Data(repeating: 7, count: 32))` and return `playola-interview-editor://auth/callback?code=C&state=<that>`.
  - **Interleaving:** for tests that interleave, gate the double with `AsyncStream.makeStream()`, as `LiveCutSuggesterTests` does. The double yields to a `started` stream, then awaits a `release` stream. The test runs `let task = Task { await model.signInTapped() }`, awaits the first `started` element, acts, finishes `release`, then `await task.value`.

```swift
@Test func signInSuccessSavesTokenForActiveEnvironmentThenLoadsUser()
  // store .inMemory(); exchange returns "T"; /me returns user
  // → store.load(.production) == "T"; account.status == .signedIn(user); attempt == .idle
  // also assert exchangeCode received codeVerifier == PlayolaPKCE.base64URL(Data(repeating: 7, count: 32))
@Test func signInCanceledInBrowserReturnsToSignedOutWithoutFailure()   // attempt == .idle, status .signedOut(nil)
@Test func signInStateMismatchFailsAndSavesNothing()                   // attempt == .failed, store empty
@Test func signInProviderErrorFails()                                  // ?error=access_denied → .failed
@Test func signInExchange400And401AndNetworkErrorFail()                // parameterized: .badStatus(400), .unauthorized, URLError(.notConnectedToInternet)
@Test func signInSaveFailureIsAFailedSignIn()                          // save throws → .failed, status .signedOut(nil)
@Test func secondSignInWhileWaitingDoesNotStartAnotherBrowserSession() // authenticate call count == 1
@Test func cancelDuringExchangeDropsLateSuccessAndSavesNothing()       // gate exchangeCode; cancelSignInTapped(); release → store empty, status .signedOut(nil)
@Test func restoreWithTokenIsSignedInBeforeMeAnswers()                 // gate currentUser; after started: status == .signedIn(nil)
@Test func restoreWithoutTokenIsSignedOut()
@Test func restoreKeychainErrorSignsOutWithoutDeleting()               // load throws; delete call count == 0
@Test func appLaunchedTwiceRestoresOnce()                              // load call count == 1
@Test func meUnauthorizedDeletesTokenAndSignsOutAsRejected()           // status .signedOut(.rejectedByPlayola); store.load == nil
@Test func meNetworkErrorStaysSignedInWithoutUser()                    // .signedIn(nil); token still stored
@Test func staleMeAfterSignOutIsDropped()                              // gate /me, sign out, release with user → .signedOut(nil)
@Test func staleMeUnauthorizedAfterServerSwitchDeletesNothing()        // gate prod /me, pick staging, release .unauthorized → prod token still stored
@Test func switchingAwayAndBackMidRestoreRestoresTheRightToken()      // gate prod load; pick staging; pick production; release → status from the second prod restore
@Test func serverSwitchLoadsOnlyThatServersToken()                    // store [prod: "P", stag: "S"]; pick staging → currentUser received (.staging, "S"), never (.staging, "P")
@Test func serverSwitchIgnoredWhenSwitchingNotAllowed()               // allowsServerSwitching: false → environment stays .production, setting unchanged
@Test func signOutDeletesOnlyActiveEnvironmentToken()                 // store [prod, stag]; sign out on prod → staging token remains
@Test func signOutDeleteFailureStaysSignedInAndFlagsIt()              // delete throws → .signedIn(...), signOutFailed == true
```

  Record calls with `LockIsolated` or `Mutex` arrays. Assert account values with `expectNoDifference`.
- [ ] **Step 2: Run and confirm the tests fail.**
- [ ] **Step 3: Implement the model per the behavior above.**
- [ ] **Step 4: Run `make test-fast ONLY=PlayolaInterviewEditorTests/PlayolaSessionModelTests`.** Run it 3 times. All runs must pass, and none may hang.
- [ ] **Step 5: Commit:** `feat: add the Playola session (sign in, stay signed in, sign out)`.

---

### Task 7: Welcome screen, host gate, app wiring

**Files:**
- Create: `Views/Pages/Welcome/WelcomePageModel.swift`, `Views/Pages/Welcome/WelcomePageView.swift`
- Modify: `Views/Pages/Project/ProjectHostView.swift`, `QuickInterviewEditorApp.swift`
- Test: `QuickInterviewEditorTests/Views/Pages/Welcome/WelcomePageTests.swift`

**Interfaces:**
- Consumes: `PlayolaSessionModel` (`account`, `attempt`, `signInTapped()`, `cancelSignInTapped()`, `appLaunched()`), `ProjectModel.phase`.
- Produces:

```swift
@MainActor @Observable final class WelcomePageModel: ViewModel {
  enum Gate: Equatable { case waitingForRestore, welcome, passThrough }
  enum Notice: Equatable { case error(String), warning(String) }
  init(session: PlayolaSessionModel, project: ProjectModel)
  var gate: Gate
  var title: String; var message: String; var notice: Notice?
  var showsProgress: Bool; var waitingText: String
  var showsSignInButtons: Bool; var signInButtonTitle: String; var localFileButtonTitle: String
  var showsCancelButton: Bool; var cancelButtonTitle: String
  func signInTapped() async
  func cancelTapped()
  func useLocalFileTapped()
}
```

  The gate works as follows:
  - `.passThrough` unless `project.phase == .empty` and this window hasn't chosen a local file.
  - Otherwise, `.waitingForRestore` while the status is `.restoring`.
  - `.welcome` while signed out.
  - `.passThrough` when signed in.

  Copy comes from the Global Constraints table. `notice` is `.error(failed text)` when `attempt == .failed`, `.warning(rejected text)` when the status is `.signedOut(.rejectedByPlayola)` and not waiting, and nil otherwise. `signInButtonTitle` is `Try Again` when failed.

- [ ] **Step 1: Write the failing tests.** Build an empty project with `ProjectModel(file: nil, plan: nil, audio: nil, sink: <the sink the existing ProjectModel tests use>)`. For the other phases, set `project.phase` directly. Drive the account through a local `@Shared(.playolaAccount)` (`$account.withLock { … }`) and the attempt through the session's own actions with stubbed dependencies.

```swift
@Test func gateShowsWelcomeForEmptyProjectWhileSignedOut()
@Test func gateWaitsWhileRestoring()                     // .waitingForRestore
@Test func gateIsPassThroughWhenSignedIn()
@Test func gateIsPassThroughForNonEmptyPhases()          // parameterized: .queued, .transcribing(nil), .loaded, .failed("x")
@Test func useLocalFileTappedPassesThroughForThisWindowOnly()  // a second WelcomePageModel on another empty project still shows .welcome
@Test func signedOutStateCopy()                          // title, message, notice nil, button titles
@Test func waitingStateShowsProgressAndCancelOnly()      // showsProgress, waitingText, showsCancelButton, !showsSignInButtons
@Test func failedStateShowsErrorNoticeAndTryAgain()
@Test func rejectedStateShowsWarningNotice()
@Test func welcomeMirrorsSessionAttemptAcrossWindows()   // two WelcomePageModels on one session: start a gated sign-in from the first; both show waiting
```

- [ ] **Step 2: Run and confirm the tests fail.**
- [ ] **Step 3: Implement the model and view.**
  - **View:** the same layout as Model Setup (02.1.1): the centered `dot.radiowaves.left.and.right` symbol in accent color, a title, a secondary message, then the notice in red for `.error` and orange for `.warning`.
  - **Waiting state:** a linear indeterminate `ProgressView` with `waitingText`, plus a bordered Cancel button.
  - **Other states:** a prominent sign-in button and a bordered local-file button.
  - **Buttons:** sign-in uses `Button { Task { await model.signInTapped() } }`, never a `.task` modifier.
- [ ] **Step 4: Wire the host and the app.**
  - **`ProjectHostView`:**
    - Add an `init` parameter `session: PlayolaSessionModel`.
    - Build the `ProjectModel` into a local, then `_model = State(initialValue: project)` and `_welcome = State(initialValue: WelcomePageModel(session: session, project: project))`.
    - In `content`, `switch welcome.gate`:
      - `.waitingForRestore` → `Color.clear`
      - `.welcome` → `WelcomePageView(model: welcome)`
      - `.passThrough` → today's `if launch.showsModelSetup … else ProjectView` unchanged
    - All existing modifiers stay on `content`'s caller, outside the branches.
  - **`QuickInterviewEditorApp`:**
    - Add an `init()` that creates the session once and stores it with `_session = State(initialValue:)`; Task 8 adds the settings model there too.
    - Unless the unit-test host is running, start `Task { await session.appLaunched() }`.
    - Move `AppDelegate`'s private `isRunningUnitTests` into a file-level `var isRunningUnitTests: Bool` that both use.
    - Pass `session:` to `ProjectHostView`.
- [ ] **Step 5: Run the Welcome tests, then the full suite: `make test-fast`.** All tests pass. This is the touched-area regression check for the host gate.
- [ ] **Step 6: Commit:** `feat: show a Playola welcome in empty windows while signed out`.

---

### Task 8: Settings ▸ Playola tab

**Files:**
- Create: `Views/Pages/Settings/PlayolaSettingsModel.swift`, `Views/Pages/Settings/PlayolaSettingsView.swift`
- Modify: `QuickInterviewEditorApp.swift`
- Test: `QuickInterviewEditorTests/Views/Pages/Settings/PlayolaSettingsModelTests.swift`

**Interfaces:**
- Consumes: `PlayolaSessionModel` (all of it).
- Produces:

```swift
@MainActor @Observable final class PlayolaSettingsModel: ViewModel {
  init(session: PlayolaSessionModel)
  var tabTitle: String; var tabSystemImage: String; var accountHeader: String
  var accountRowLabel: String; var accountValue: String
  var accountDetail: String?; var accountDetailIsError: Bool
  var showsAccountButton: Bool; var accountButtonTitle: String; var accountButtonIsProminent: Bool
  var showsServerPicker: Bool; var serverHeader: String; var serverLabel: String; var serverHelp: String
  var environments: [PlayolaEnvironment]; var selectedEnvironment: PlayolaEnvironment
  func accountButtonTapped() async   // signed in → signOutTapped; waiting → cancelSignInTapped; else signInTapped
  func environmentPicked(_ environment: PlayolaEnvironment) async
}
```

  The account row by state (copy from the Global Constraints table):

  | State | Label | Value | Detail | Button |
  |---|---|---|---|---|
  | restoring | `Status:` | (empty) | — | hidden |
  | signed in, user loaded | `Signed in as:` | `displayName` | email | `Sign Out` |
  | signed in, no user | `Signed in as:` | `Signed in` | none | `Sign Out` |
  | signed out | `Status:` | `Not signed in` | the signed-out detail, or the rejected text after a 401 | `Sign In with Playola…` (prominent) |
  | waiting | `Status:` | `Waiting for Playola…` | — | `Cancel` |
  | failed | `Status:` | `Not signed in` | the failed text (error) | `Sign In with Playola…` |

  When `signOutFailed`, the detail is `Couldn't sign out. Try again.` (error).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func signedInWithUserShowsNameEmailAndSignOut()
@Test func signedInWithoutUserShowsSignedIn()
@Test func signedOutShowsNotSignedInAndSignInButton()
@Test func rejectedShowsRejectedDetail()
@Test func waitingShowsWaitingTextAndCancel()
@Test func failedShowsErrorDetail()
@Test func signOutFailureShowsCouldNotSignOut()
@Test func serverPickerHiddenWhenSwitchingNotAllowed()   // session(allowsServerSwitching: false) → !showsServerPicker
@Test func serverPickerShowsAllEnvironmentsWhenAllowed() // environments == [.production, .staging, .local]
```

- [ ] **Step 2: Run and confirm the tests fail.**
- [ ] **Step 3: Implement the model and view.**
  - **View:** a `Form`, padded and with the same width as `PlaybackLatencySettingsView`. Use an `Account` section and a `Server (debug builds only)` section, shown only when `showsServerPicker`.
  - **Picker:** binds through `Binding(get: { model.selectedEnvironment }, set: { env in Task { await model.environmentPicked(env) } })`, with labels from `PlayolaEnvironment.label`.
  - **Detail text:** red when `accountDetailIsError`, otherwise secondary.
- [ ] **Step 4: Wire the tab.** In `QuickInterviewEditorApp.init()`, set `_playolaSettings = State(initialValue: PlayolaSettingsModel(session: session))`. Add the fifth tab after Playback Latency: `PlayolaSettingsView(model: playolaSettings).tabItem { Label(playolaSettings.tabTitle, systemImage: playolaSettings.tabSystemImage) }`.
- [ ] **Step 5: Run the settings tests and confirm they pass.**
- [ ] **Step 6: Commit:** `feat: add the Playola tab to Settings`.

---

### Task 9: Whole-branch verification

- [ ] **Step 1:** In `QuickInterviewEditor/`, run `make test-fast`. Every test passes, including the existing suite.
- [ ] **Step 2:** Run `make format-check` and `make lint`. No warnings.
- [ ] **Step 3:** Run `make test` (fastlane, CI parity). It passes.
- [ ] **Step 4:** Launch a debug build. Check the following:
  - An empty window flashes nothing, then shows Welcome while signed out.
  - "Use a Local Audio File" shows today's drop target, or Model Setup in packaged builds with missing models.
  - Opening an existing `.pie` opens the project.
  - Settings shows the Playola tab with the server picker.
  - (Sign-in itself waits for the server endpoints; see the spec's manual QA list.)
- [ ] **Step 5:** Commit any fixes: `chore: fix lint and formatting`, only if needed.

The adversarial Codex review (review + challenge + Excess Audit) runs after this task. PR creation (base `main`, draft, title `feature: sign in to Playola`, CHANGELOG `[Unreleased]` entry) is delegated to Codex per `~/.claude/CLAUDE.md`.
