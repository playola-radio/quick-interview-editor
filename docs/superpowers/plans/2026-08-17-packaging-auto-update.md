# Packaging + Self-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift tasks:** before writing any Swift, invoke the relevant `pfw-*` skills
> per `CLAUDE.md` (at minimum `pfw-dependencies` for `UpdaterClient`,
> `pfw-observable-models` for the models, `pfw-testing` + `pfw-custom-dump` for
> tests). List them in your checklist.

**Goal:** Distribute QuickInterviewEditor as a notarized DMG downloaded from
Brian's website, with in-app Sparkle self-update off an S3 `appcast.xml`, such
that updating preserves the user's Keychain-stored API key.

**Architecture:** Add Sparkle 2.x to the app (in-app "Check for Updates…" + a
background check) reading an `appcast.xml` on an existing S3 bucket; ship one
notarized+stapled DMG as both the website download and the Sparkle enclosure.
A local `fastlane mac release` lane builds → signs (inside-out) → notarizes →
DMGs → EdDSA-signs the update → appends the appcast → uploads to S3. The API key
survives because the in-place `.app` swap keeps the same code-signing designated
requirement.

**Tech Stack:** SwiftUI (macOS, MV + `@Observable`), swift-dependencies,
Sparkle 2.x (SPM), XcodeGen, fastlane, PyInstaller-frozen Python engine, AWS CLI,
`create-dmg`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-17-packaging-auto-update-design.md`
(read it alongside this plan).

## Global Constraints

Copied verbatim from the spec; every task inherits these.

- **Never change these three identifiers** (breaks silent Keychain read):
  Team ID `FSRSPV9N9Q`; bundle id `fm.playola.QuickInterviewEditor`; Keychain
  service `fm.playola.QuickInterviewEditor.anthropicAPIKey` / account `anthropic`
  (no `kSecAttrAccessGroup`, no sandbox, no synchronizable).
- **Deployment / update floor:** macOS deployment target **15.0**;
  `sparkle:minimumSystemVersion` = **`15.0.0`** (Sparkle requires a three-component
  major.minor.patch string for correct system-version filtering).
- **Distribution:** Developer ID, **not** sandboxed, **not** App Store.
- **`sparkle:version` == `CFBundleVersion`** — a monotonically increasing
  **integer**, never a git SHA. `CFBundleShortVersionString` is the display version.
- **Enclosure:** one notarized+stapled **DMG** for both website and Sparkle. Full
  updates only, no deltas. Old DMGs retained in S3 for rollback.
- **Signing:** inside-out (nested Mach-O → executables → frameworks → app);
  `--deep` only for verification.
- **Entitlements:** app `app.entitlements` stays empty; engine keeps
  `com.apple.security.cs.disable-library-validation`. No `get-task-allow`. No
  Sparkle sandbox/XPC entitlements (app isn't sandboxed).
- **EdDSA private key** lives in the login Keychain + an encrypted offline backup;
  never in git. Public key ships in Info.plist as `SUPublicEDKey`.
- **Swift 6 strict concurrency + CI Xcode skew:** CI runs an older Xcode than
  local (see memory `qie-ci-xcode-version-skew`). Prefer `@MainActor`-explicit,
  `@Sendable`-clean code; build must pass on the CI toolchain, not just locally.
- **Config, not literals:** `SUFeedURL`, `RELEASE_S3_BUCKET`, `RELEASE_S3_PREFIX`
  are set once (project.yml / env). **Resolved (PR 1):** appcast.xml + DMG both
  live on S3 and are served by the **raw S3 URL**, exactly how the sibling
  **PlayolaAudioProcessor** distributes (no Netlify/CloudFront in the path — nothing
  new to configure anywhere). Bucket `playola-static`, prefix
  `downloads/QuickInterviewEditor`, uploaded with `AWS_PROFILE=default` (already
  writes to this bucket). So
  `SUFeedURL=https://playola-static.s3.amazonaws.com/downloads/QuickInterviewEditor/appcast.xml`
  (baked into project.yml), `RELEASE_S3_BUCKET=playola-static`,
  `RELEASE_S3_PREFIX=downloads/QuickInterviewEditor`,
  `RELEASE_DOWNLOAD_HOST=https://playola-static.s3.amazonaws.com`. Upload appcast.xml
  with `--cache-control no-cache` so clients aren't served a stale feed. (Trade-off:
  the baked-in `SUFeedURL` is tied to the `playola-static` bucket name; if we ever
  leave that bucket we'd ship an app update pointing the feed elsewhere first. Fine
  at this user count, and it matches the sibling.)

---

## PR split

- **PR 1 = Setup Task 0 + Tasks 1–6** (Sparkle in the app). Mergeable before any
  release machinery exists: the app builds, tests pass, the updater points at a
  not-yet-live feed and simply reports "no updates."
- **PR 2 = Tasks 7–12** (the release pipeline). Produces the DMG + appcast and
  puts the feed live.

Execute PR 1 fully (in its own fresh context), merge, then PR 2 in a new context.

---

## Setup Task 0: Generate the Sparkle EdDSA keypair (one-time, prerequisite for PR 1)

**Why first:** PR 1 bakes the **public** key into Info.plist, so the keypair must
exist before Task 2. This is a manual, one-time human step (no code, no commit of
secrets).

**Files:** none committed. Produces a public key string used in Task 2.

- [ ] **Step 1: Obtain Sparkle's `generate_keys` tool.** After Task 1 resolves the
  Sparkle SPM package, the binaries live in the resolved artifact bundle. Locate it:

```bash
find ~/Library/Developer/Xcode/DerivedData "$(pwd)" \
  -name generate_keys -type f 2>/dev/null | head
```

  (If not yet present, this step waits until Task 1 has resolved packages, then
  returns here. The tool ships in Sparkle's `Sparkle-for-Swift-Package-Manager`
  artifact / the `Sparkle.xcframework` distribution under `bin/`.)

- [ ] **Step 2: Generate the keypair into the login Keychain.** Reuse the path
  captured in Step 1 (`GK`) — `generate_keys` is not on `PATH`, so don't assume
  the current directory:

```bash
GK="$(find ~/Library/Developer/Xcode/DerivedData "$(pwd)" \
       -name generate_keys -type f 2>/dev/null | head -1)"
[ -x "$GK" ] || { echo "generate_keys not found — resolve Sparkle (Task 1) first" >&2; exit 1; }
"$GK"                 # generate (idempotent: reuses an existing Keychain key)
"$GK" -p             # print the existing public key for automation
```

  This prints a **public** key (base64) and stores the **private** key in the
  login Keychain (item "Private key for signing Sparkle updates"). Copy the
  printed public key — it goes into Task 2. **(DONE in PR 1:** public key
  `WyAypjfp2RUEqO+iIb/iYTTYwVq5AaXJWUxT9pwzrog=`, already in `project.yml`.)

- [ ] **Step 3: Back up the private key offline (encrypted).**

```bash
"$GK" -x sparkle_private_key.pem   # export
# Move sparkle_private_key.pem into an encrypted store (e.g. an encrypted disk
# image or 1Password), then shred the plaintext:
rm -P sparkle_private_key.pem
```

  Record in `packaging/README.md` (Task 12) that if this key is lost, updates are
  **still recoverable** (not permanently broken): because the app is Developer ID
  code-signed, Sparkle supports EdDSA key rotation — ship a new update signed with
  the *same* Developer ID and a *new* `SUPublicEDKey` (do not change the Developer
  ID cert and the EdDSA key in the same release). Losing the key only forces that
  one-time rotation, so still back it up to avoid the hassle.

**Deliverable:** the public key string (for Task 2) + a secured private-key backup.

---

## PR 1 — Sparkle in the app

### Task 1: Add Sparkle as an SPM dependency

**Files:**
- Modify: `QuickInterviewEditor/project.yml`
- Regenerate: `QuickInterviewEditor/QuickInterviewEditor.xcodeproj` (via XcodeGen)

**Interfaces:**
- Produces: the `Sparkle` product importable as `import Sparkle` in the app target.

- [ ] **Step 1: Add the package + dependency.** In `project.yml` under `packages:`
  add (pin an exact tag — `2.9.6` is what shipped in PR 1 and is recorded in
  `Package.resolved`; bump only deliberately):

```yaml
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    exactVersion: "2.9.6"
```

  And under `targets: QuickInterviewEditor: dependencies:` add:

```yaml
      - package: Sparkle
        product: Sparkle
```

- [ ] **Step 2: Regenerate + resolve.**

```bash
cd QuickInterviewEditor && make generate   # or: xcodegen generate
```

  (Check `Makefile` for the exact generate target; the repo uses XcodeGen.)

- [ ] **Step 3: Verify it compiles.** Add a temporary `import Sparkle` at the top of
  `QuickInterviewEditorApp.swift`, then:

```bash
cd QuickInterviewEditor && xcodebuild -scheme QuickInterviewEditor \
  -destination 'platform=macOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```

  Expected: `BUILD SUCCEEDED`. Remove the temporary import.

- [ ] **Step 4: Commit.**

```bash
git add QuickInterviewEditor/project.yml QuickInterviewEditor/QuickInterviewEditor.xcodeproj QuickInterviewEditor/QuickInterviewEditor.xcworkspace 2>/dev/null; \
git add QuickInterviewEditor/QuickInterviewEditor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "build: add Sparkle 2.x SPM dependency"
```

### Task 2: Info.plist keys + version settings (XcodeGen `info:` block)

**Files:**
- Modify: `QuickInterviewEditor/project.yml`

**Interfaces:**
- Produces: `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`,
  `SUScheduledCheckInterval` in the built app's Info.plist; `MARKETING_VERSION`
  and `CURRENT_PROJECT_VERSION` as the single version source of truth.

- [ ] **Step 1: Add version settings.** Under
  `targets: QuickInterviewEditor: settings: base:` add:

```yaml
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: "1"
```

- [ ] **Step 2: Add the Sparkle Info.plist keys.** `GENERATE_INFOPLIST_FILE: YES`
  cannot set arbitrary keys, so add an `info:` block to the target (this
  generates a plist Xcode merges). Under `targets: QuickInterviewEditor:` add:

```yaml
    info:
      path: QuickInterviewEditor/Info.plist
      properties:
        SUFeedURL: https://playola-static.s3.amazonaws.com/downloads/QuickInterviewEditor/appcast.xml
        SUPublicEDKey: REPLACE_WITH_PUBLIC_KEY_FROM_SETUP_TASK_0
        SUEnableAutomaticChecks: true
        SUScheduledCheckInterval: 86400
```

  Set `SUPublicEDKey` to the exact string from Setup Task 0. Brian sets
  `SUFeedURL`'s host. Keep `GENERATE_INFOPLIST_FILE: YES` — XcodeGen's generated
  Info.plist is merged with the auto-generated keys.

- [ ] **Step 3: Regenerate + build, then confirm the keys land in the app.**

```bash
cd QuickInterviewEditor && xcodegen generate && xcodebuild -scheme QuickInterviewEditor \
  -destination 'platform=macOS' -configuration Debug -derivedDataPath /tmp/qie-dd \
  CODE_SIGNING_ALLOWED=NO build >/dev/null 2>&1
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' -c 'Print :SUPublicEDKey' \
  -c 'Print :CFBundleVersion' -c 'Print :CFBundleShortVersionString' \
  /tmp/qie-dd/Build/Products/Debug/QuickInterviewEditor.app/Contents/Info.plist
```

  Expected: prints the feed URL, the public key, `1`, and `1.0.0`.

- [ ] **Step 4: Commit.**

```bash
git add QuickInterviewEditor/project.yml QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "build: Info.plist Sparkle keys + version single-source"
```

### Task 3: `UpdaterClient` dependency

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Core/UpdaterClient.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Core/UpdaterClientTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct UpdaterClient: Sendable {
    var checkForUpdates: @MainActor @Sendable () -> Void
    var canCheckForUpdates: @MainActor @Sendable () -> Bool
  }
  extension DependencyValues { var updater: UpdaterClient { get set } }
  ```
  `testValue` no-ops (`canCheckForUpdates` returns `true`). `liveValue` wraps a
  `@MainActor` singleton holding `SPUStandardUpdaterController`.

- [ ] **Step 1: Write the failing test.** Invoke `pfw-dependencies` + `pfw-testing`
  first, then:

```swift
import Dependencies
import Testing
@testable import QuickInterviewEditor

@MainActor
struct UpdaterClientTests {
  @Test func testValueIsSafeNoOp() {
    let client = UpdaterClient.testValue
    client.checkForUpdates()                    // must not crash
    #expect(client.canCheckForUpdates() == true)
  }
}
```

- [ ] **Step 2: Run it, expect failure** (type `UpdaterClient` undefined).

```bash
cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor \
  -destination 'platform=macOS' -only-testing:QuickInterviewEditorTests/UpdaterClientTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

- [ ] **Step 3: Implement.**

```swift
import Dependencies
import Foundation
import Sparkle

/// Wraps Sparkle's updater so the app's models can trigger an update check and
/// reflect its availability without importing Sparkle or holding a non-Sendable
/// controller. Live path drives `SPUStandardUpdaterController`; tests get no-ops.
struct UpdaterClient: Sendable {
  var checkForUpdates: @MainActor @Sendable () -> Void
  var canCheckForUpdates: @MainActor @Sendable () -> Bool
}

extension UpdaterClient: DependencyKey {
  static var liveValue: UpdaterClient {
    let holder = LiveUpdaterHolder.shared
    return UpdaterClient(
      checkForUpdates: { holder.controller.updater.checkForUpdates() },
      canCheckForUpdates: { holder.controller.updater.canCheckForUpdates }
    )
  }
}

extension UpdaterClient: TestDependencyKey {
  static var testValue: UpdaterClient {
    UpdaterClient(checkForUpdates: {}, canCheckForUpdates: { true })
  }
  static var previewValue: UpdaterClient { testValue }
}

extension DependencyValues {
  var updater: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}

/// Owns the single Sparkle controller for the app's lifetime. `startingUpdater:
/// true` begins scheduled background checks immediately.
@MainActor
final class LiveUpdaterHolder {
  static let shared = LiveUpdaterHolder()
  let controller = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  private init() {}
}
```

- [ ] **Step 4: Run the test, expect pass.**

```bash
cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor \
  -destination 'platform=macOS' -only-testing:QuickInterviewEditorTests/UpdaterClientTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

- [ ] **Step 5: Commit.**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Core/UpdaterClient.swift \
  QuickInterviewEditor/QuickInterviewEditorTests/Core/UpdaterClientTests.swift
git commit -m "feat: UpdaterClient dependency wrapping Sparkle"
```

### Task 4: "Check for Updates…" menu command + model

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Commands/UpdaterCommands.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Commands/UpdaterCommandsModel.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/QuickInterviewEditorApp.swift:14-16`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Commands/UpdaterCommandsModelTests.swift`

**Interfaces:**
- Consumes: `UpdaterClient` (Task 3).
- Produces: `UpdaterCommandsModel` with
  `var checkForUpdatesLabel: String`, `var canCheckForUpdates: Bool`,
  `func checkForUpdatesTapped()`; `UpdaterCommands: Commands`.

- [ ] **Step 1: Write the failing model test.** (Invoke `pfw-observable-models`,
  `pfw-dependencies`, `pfw-testing` first.)

```swift
import Dependencies
import Testing
@testable import QuickInterviewEditor

@MainActor
struct UpdaterCommandsModelTests {
  @Test func checkForUpdatesTappedInvokesClient() {
    let called = LockIsolated(false)
    let model = withDependencies {
      $0.updater = UpdaterClient(
        checkForUpdates: { called.setValue(true) },
        canCheckForUpdates: { true })
    } operation: { UpdaterCommandsModel() }

    model.checkForUpdatesTapped()
    #expect(called.value == true)
  }

  @Test func labelIsUserFacing() {
    let model = withDependencies { $0.updater = .testValue } operation: {
      UpdaterCommandsModel()
    }
    #expect(model.checkForUpdatesLabel == "Check for Updates…")
  }
}
```

- [ ] **Step 2: Run it, expect failure** (`UpdaterCommandsModel` undefined). Command
  as in Task 3 Step 2 with `-only-testing:.../UpdaterCommandsModelTests`.

- [ ] **Step 3: Implement the model.**

```swift
import Dependencies
import Observation

@MainActor
@Observable
final class UpdaterCommandsModel {
  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.updater) var updater

  // MARK: - View Helpers
  var checkForUpdatesLabel: String { "Check for Updates…" }
  var canCheckForUpdates: Bool { updater.canCheckForUpdates() }

  // MARK: - User Actions
  func checkForUpdatesTapped() { updater.checkForUpdates() }
}
```

- [ ] **Step 4: Implement the command (view — no logic).**

```swift
import SwiftUI

/// "Check for Updates…" under the app menu. All behavior lives on the model.
struct UpdaterCommands: Commands {
  @State private var model = UpdaterCommandsModel()

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button(model.checkForUpdatesLabel) { model.checkForUpdatesTapped() }
        .disabled(!model.canCheckForUpdates)
    }
  }
}
```

- [ ] **Step 5: Wire into the app.** In `QuickInterviewEditorApp.swift`, extend the
  `.commands` block:

```swift
    .commands {
      TranscriptionCommands(root: model.root)
      UpdaterCommands()
    }
```

- [ ] **Step 6: Run tests, expect pass** (`-only-testing:.../UpdaterCommandsModelTests`).

- [ ] **Step 7: Commit.**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Commands/UpdaterCommands.swift \
  QuickInterviewEditor/QuickInterviewEditor/Views/Commands/UpdaterCommandsModel.swift \
  QuickInterviewEditor/QuickInterviewEditor/QuickInterviewEditorApp.swift \
  QuickInterviewEditor/QuickInterviewEditorTests/Views/Commands/UpdaterCommandsModelTests.swift
git commit -m "feat: Check for Updates menu command"
```

### Task 5: First-launch "move to /Applications" guard (anti-translocation)

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Core/InstallLocation.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Core/InstallLocationTests.swift`
- Modify: the app-launch model that runs on appear (find it:
  `grep -rln "func .*[Aa]ppeared" QuickInterviewEditor/QuickInterviewEditor`;
  likely `AppLaunchModel`).

**Interfaces:**
- Produces: pure decision
  `InstallLocation.shouldOfferMoveToApplications(bundlePath: String, isTranslocated: Bool) -> Bool`
  and a `@MainActor` `offerMoveToApplications()` that performs the move
  (NSWorkspace/`PFMoveToApplicationsFolderIfNecessary`-style; see note).

- [ ] **Step 1: Write the failing test** (pure decision only — the actual move is a
  thin side-effect not unit-tested).

```swift
import Testing
@testable import QuickInterviewEditor

struct InstallLocationTests {
  @Test func fromApplicationsFolderNoOffer() {
    #expect(InstallLocation.shouldOfferMoveToApplications(
      bundlePath: "/Applications/QuickInterviewEditor.app",
      isTranslocated: false) == false)
  }
  @Test func fromDiskImageOffers() {
    #expect(InstallLocation.shouldOfferMoveToApplications(
      bundlePath: "/Volumes/QuickInterviewEditor/QuickInterviewEditor.app",
      isTranslocated: false) == true)
  }
  @Test func translocatedOffers() {
    #expect(InstallLocation.shouldOfferMoveToApplications(
      bundlePath: "/private/var/folders/xy/AppTranslocation/ABC/d/QuickInterviewEditor.app",
      isTranslocated: true) == true)
  }
  @Test func fromUserApplicationsNoOffer() {
    let home = NSHomeDirectory()
    #expect(InstallLocation.shouldOfferMoveToApplications(
      bundlePath: "\(home)/Applications/QuickInterviewEditor.app",
      isTranslocated: false) == false)
  }
}
```

- [ ] **Step 2: Run it, expect failure.**

- [ ] **Step 3: Implement the decision.**

```swift
import Foundation

/// Decides whether to nudge the user to move the app into /Applications on first
/// launch. Running from the DMG (read-only) or a translocated path breaks
/// self-update and can surface Gatekeeper "damaged app" errors, so we offer to
/// relocate. Pure so it is unit-testable; the actual move is a side-effecting
/// helper below.
enum InstallLocation {
  static func shouldOfferMoveToApplications(bundlePath: String, isTranslocated: Bool) -> Bool {
    if isTranslocated { return true }
    let inSystemApps = bundlePath.hasPrefix("/Applications/")
    let inUserApps = bundlePath.hasPrefix("\(NSHomeDirectory())/Applications/")
    return !(inSystemApps || inUserApps)
  }
}
```

- [ ] **Step 4: Run tests, expect pass.**

- [ ] **Step 5: Add the side-effecting move + wire into launch.** Add to
  `InstallLocation` a `@MainActor static func offerMoveToApplicationsIfNeeded()`
  that reads `Bundle.main.bundlePath`, detects translocation via
  `SecTranslocateIsTranslocatedURL` (from `Security`), and if
  `shouldOfferMoveToApplications` is true, presents an alert offering to copy the
  app to `/Applications` and relaunch (use `NSWorkspace`; or vendor the small,
  battle-tested **LetsMove** `PFMoveToApplicationsFolderIfNecessary` — allowed as
  a Layer-1 dependency). Call it from the app-launch model's appear method. Guard
  so it never runs in `#if DEBUG` / tests (no move during development).

- [ ] **Step 6: Build + full test run, expect pass.**

```bash
cd QuickInterviewEditor && bundle exec fastlane mac test 2>&1 | tail -15
```

- [ ] **Step 7: Commit.**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Core/InstallLocation.swift \
  QuickInterviewEditor/QuickInterviewEditorTests/Core/InstallLocationTests.swift \
  QuickInterviewEditor/QuickInterviewEditor/  # + the modified launch model
git commit -m "feat: offer move to /Applications on first launch (anti-translocation)"
```

### Task 6: Engine-path translocation regression guard

**Files:**
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Core/EngineResolverTests.swift`
  (add a case; the file exists per `EngineResolution.swift`'s doc reference).

**Interfaces:**
- Consumes: `EngineResolver.resolve` (existing).

- [ ] **Step 1: Add a test locking in that a bundled helper resolves regardless of
  path** (documents that resolution is bundle-relative, so translocation to a
  random path still finds the engine):

```swift
@Test func bundledHelperUnderTranslocatedPathStillResolves() {
  let helper = URL(fileURLWithPath:
    "/private/var/folders/xy/AppTranslocation/ABC/d/QuickInterviewEditor.app/Contents/Resources/engine/logic-markers-engine")
  let launch = EngineResolver.resolve(
    bundledHelper: helper,
    repoRootOverride: nil,
    filePathRepoRoot: URL(fileURLWithPath: "/repo"),
    isExecutable: { $0 == helper })
  #expect(launch.isBundled == true)
  #expect(launch.executable == helper)
  #expect(launch.workingDirectory == helper.deletingLastPathComponent())
}
```

- [ ] **Step 2: Run it, expect pass** (behavior already correct — this is a
  regression guard, not a fix).

- [ ] **Step 3: Commit.**

```bash
git add QuickInterviewEditor/QuickInterviewEditorTests/Core/EngineResolverTests.swift
git commit -m "test: engine resolves under translocated bundle path"
```

**End of PR 1.** Run `bundle exec fastlane mac test` + `fastlane mac lint_code`,
open the PR, then run the Codex adversarial review (`/codex review`,
`/codex challenge`) per `CLAUDE.md` before declaring done.

---

## PR 2 — the release pipeline

> Run PR 2 in a fresh context after PR 1 merges. It touches `packaging/` +
> `fastlane/` + CI; no app-source changes.

### Task 7: `make-dmg.sh` — build the notarized DMG

**Files:**
- Create: `packaging/make-dmg.sh`

**Interfaces:**
- Consumes: a signed+notarized+stapled `.app` at
  `packaging/dist/QuickInterviewEditor.app`, plus `NOTARY_PROFILE` + the Developer
  ID identity (same as `sign-app.sh`).
- Produces: `packaging/dist/QuickInterviewEditor-<short>-<build>.dmg`, itself
  **signed, notarized, and stapled**.

**Why sign+notarize the DMG (not just the app):** Gatekeeper checks the outermost
container the user opens. A stapled ticket on the DMG lets it validate offline. And
the filename carries **both** `CFBundleShortVersionString` *and* the integer
`CFBundleVersion` so two builds that share a marketing version (e.g. two `1.0.0`
builds) don't collide — otherwise the second upload overwrites the first DMG and
the earlier appcast signature no longer matches its URL, breaking rollback.

- [ ] **Step 1: Install the tool.**

```bash
brew install create-dmg
```

- [ ] **Step 2: Write the script.**

```bash
#!/usr/bin/env bash
# Build a distributable DMG from the signed+notarized app, then sign + notarize +
# staple the DMG itself.  packaging/make-dmg.sh  (reads versions from Info.plist)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/packaging/dist"
APP="$DIST/QuickInterviewEditor.app"
[ -d "$APP" ] || { echo "error: no app at $APP (run build/sign/notarize first)" >&2; exit 1; }
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Playola Radio, Incorporated (FSRSPV9N9Q)}"
NOTARY_PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile)}"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$DIST/QuickInterviewEditor-$SHORT-$BUILD.dmg"
rm -f "$DMG"
create-dmg \
  --volname "QuickInterviewEditor $SHORT" \
  --app-drop-link 480 200 \
  --icon "QuickInterviewEditor.app" 160 200 \
  --window-size 640 400 \
  "$DMG" "$APP"
echo "==> Signing the DMG (Developer ID)"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
echo "==> Stapling DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "==> DMG: $DMG"
du -sh "$DMG" | awk '{print "    dmg size: " $1}'
```

  The release lane (Task 10) and `appcast.rb` (Task 9) must build the enclosure URL
  from this same `QuickInterviewEditor-<short>-<build>.dmg` filename.

- [ ] **Step 3: `chmod +x packaging/make-dmg.sh`.**

- [ ] **Step 4: Verify (manual, needs a prior signed+notarized app).** Documented
  in Task 12's runbook; not run in CI. Expected: `stapler validate` prints "The
  validate action worked!".

- [ ] **Step 5: Commit.**

```bash
git add packaging/make-dmg.sh && git commit -m "feat(packaging): make-dmg.sh (notarized, stapled DMG)"
```

### Task 8: Harden `sign-app.sh` — fail if any Mach-O is left unsigned

**Files:**
- Modify: `packaging/sign-app.sh`

**Context:** `sign-app.sh` signs the engine tree inside-out correctly, but its
`Contents/Frameworks` loop only matches `*.framework`/`*.dylib` and signs each
match **flatly** (a single `codesign` with no recursion). That was fine before
Sparkle. **Sparkle 2.x breaks this assumption** (confirmed against the built app
in PR 1): `Sparkle.framework` embeds nested code bundles that must be signed
inside-out *before* the framework —
- `Sparkle.framework/Versions/B/Autoupdate` (a Mach-O executable),
- `Sparkle.framework/Versions/B/Updater.app` (a nested app bundle), and
- `Sparkle.framework/Versions/B/XPCServices/Downloader.xpc` + `Installer.xpc`.

A flat `codesign` of `Sparkle.framework` leaves those nested bundles ad-hoc/unsigned,
so notarization + Gatekeeper (and Sparkle's own installer launch) will fail. This
was surfaced by the PR 1 Codex review. So Task 8 has **two** parts: actually sign
Sparkle's nested bundles inside-out (Step 0), **and** add the belt-and-suspenders
Mach-O guard (Step 1).

- [ ] **Step 0: Sign Sparkle's nested bundles inside-out.** Before the existing
  framework loop signs `Sparkle.framework`, sign each nested `.xpc`, then
  `Updater.app`, then the `Autoupdate` executable, with the hardened runtime (no
  entitlements needed — Sparkle isn't sandboxed here). Deepest-first, e.g.:

```bash
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  echo "==> Signing Sparkle nested helpers (inside-out)"
  for xpc in "$SPARKLE/Versions/B/XPCServices/"*.xpc; do
    [ -e "$xpc" ] && codesign --force --sign "$IDENTITY" --options runtime --timestamp "$xpc"
  done
  [ -d "$SPARKLE/Versions/B/Updater.app" ] && \
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$SPARKLE/Versions/B/Updater.app"
  [ -f "$SPARKLE/Versions/B/Autoupdate" ] && \
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$SPARKLE/Versions/B/Autoupdate"
fi
```

  Then let the existing `*.framework` loop sign `Sparkle.framework` itself (now
  that its innards are signed). Verify Sparkle's version tag (`Versions/B`) against
  the pinned Sparkle release before shipping — bump the path if a future Sparkle
  changes it.

- [ ] **Step 1: Add a post-sign verification loop** before the final "Signed OK"
  line (this guard would *catch* the unsigned Sparkle helpers above, but Step 0 is
  what actually *fixes* them):

```bash
echo "==> Guard: every Mach-O must be signed with Team FSRSPV9N9Q"
unsigned=0
while IFS= read -r macho; do
  [ -z "$macho" ] && continue
  if ! codesign -dvvv "$macho" 2>&1 | grep -q "TeamIdentifier=FSRSPV9N9Q"; then
    echo "   UNSIGNED/wrong-team: $macho" >&2
    unsigned=$((unsigned + 1))
  fi
done < <(find "$APP" -type f -print0 | xargs -0 file 2>/dev/null \
           | grep 'Mach-O' | cut -d: -f1)
[ "$unsigned" -eq 0 ] || { echo "error: $unsigned Mach-O binaries not properly signed" >&2; exit 1; }
echo "    all Mach-O binaries signed with our Team ID"
```

- [ ] **Step 2: Verify against a built app** (manual, per Task 12 runbook). Expected:
  "all Mach-O binaries signed with our Team ID".

- [ ] **Step 3: Commit.**

```bash
git add packaging/sign-app.sh && git commit -m "fix(packaging): guard against any unsigned Mach-O after signing"
```

### Task 9: `appcast.rb` — append a signed appcast item (inline release notes)

**Files:**
- Create: `packaging/appcast.rb`

**Interfaces:**
- Consumes: the DMG (Task 7), `sign_update` output (EdDSA sig + length), version
  fields from the app's Info.plist, and a release-notes string.
- Produces / mutates: `packaging/dist/appcast.xml` (append one `<item>`; create
  the file with an RSS skeleton if absent). Idempotent per version (replaces an
  existing item with the same `sparkle:version`).

- [ ] **Step 1: Locate `sign_update`** (ships with Sparkle SPM, like `generate_keys`):

```bash
find ~/Library/Developer/Xcode/DerivedData "$(pwd)" -name sign_update -type f 2>/dev/null | head
```

- [ ] **Step 2: Write the script.** It runs `sign_update <dmg>` (reads the private
  key from the Keychain), parses `sparkle:edSignature="…" length="…"`, reads
  `CFBundleVersion` / `CFBundleShortVersionString` from the app, and appends:

```ruby
#!/usr/bin/env ruby
# Append a signed <item> to packaging/dist/appcast.xml for the current DMG.
#   packaging/appcast.rb <dmg> <public-download-url> <sign_update_path> [notes_file]
# Inline release notes (CDATA). Idempotent: replaces an item with the same
# sparkle:version. A malformed appcast breaks the update channel, so it validates
# XML before writing.
require "rexml/document"
require "time"

dmg, url, sign_update, notes_file = ARGV
abort "usage: appcast.rb <dmg> <download-url> <sign_update> [notes_file]" unless dmg && url && sign_update

app = File.join(File.dirname(dmg), "QuickInterviewEditor.app")
def plist(app, key) = `/usr/libexec/PlistBuddy -c 'Print :#{key}' "#{app}/Contents/Info.plist"`.strip
version    = plist(app, "CFBundleVersion")            # sparkle:version (integer)
short      = plist(app, "CFBundleShortVersionString") # display
min_os     = "15.0.0"                                # 3-component, Sparkle requirement
notes      = notes_file ? File.read(notes_file) : "See the changelog."

# A bad appcast breaks the update channel for everyone, so validate the SEMANTICS
# before writing — not just that the output is well-formed XML. Empty PlistBuddy
# reads (missing key / wrong path) must fail loudly rather than emit blank fields.
abort "CFBundleVersion missing or non-integer: #{version.inspect}" unless version =~ /\A\d+\z/
abort "CFBundleShortVersionString empty" if short.empty?
abort "download url must be https: #{url}" unless url.start_with?("https://")
abort "download url must end in the dmg name" unless url.end_with?(File.basename(dmg))

sig_line = `#{sign_update} "#{dmg}"`.strip            # sparkle:edSignature="..." length="..."
abort "sign_update produced no signature" if sig_line.empty?
ed  = sig_line[/sparkle:edSignature="([^"]+)"/, 1] or abort "no edSignature in: #{sig_line}"
len = sig_line[/length="(\d+)"/, 1] or abort "no length in: #{sig_line}"
abort "enclosure length must be > 0" unless len.to_i.positive?

path = File.join(File.dirname(dmg), "appcast.xml")
doc = File.exist?(path) ? REXML::Document.new(File.read(path)) : nil
if doc.nil?
  doc = REXML::Document.new(<<~XML)
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel><title>QuickInterviewEditor</title></channel>
    </rss>
  XML
end
channel = doc.elements["rss/channel"]
# Idempotent: drop any existing item with this sparkle:version.
channel.elements.each("item") do |it|
  v = it.elements["sparkle:version"]&.text
  channel.delete(it) if v == version
end

item = channel.add_element("item")
item.add_element("title").text = "Version #{short}"
item.add_element("pubDate").text = Time.now.utc.rfc2822
item.add_element("sparkle:version").text = version
item.add_element("sparkle:shortVersionString").text = short
item.add_element("sparkle:minimumSystemVersion").text = min_os
desc = item.add_element("description")
desc.add_text(REXML::CData.new(notes))
enc = item.add_element("enclosure")
enc.add_attribute("url", url)
enc.add_attribute("length", len)
enc.add_attribute("type", "application/octet-stream")
enc.add_attribute("sparkle:edSignature", ed)

# Validate by re-parsing what we're about to write, then re-assert the freshly
# built item carries every required field before it goes near S3.
out = String.new
doc.write(output: out, indent: 2)
reparsed = REXML::Document.new(out) or abort "generated appcast is not well-formed"
built = reparsed.elements.to_a("rss/channel/item").find { |i| i.elements["sparkle:version"]&.text == version } \
  or abort "generated item for version #{version} is missing"
%w[title sparkle:version sparkle:shortVersionString sparkle:minimumSystemVersion].each do |field|
  t = built.elements[field]&.text
  abort "generated item missing #{field}" if t.nil? || t.empty?
end
enc_out = built.elements["enclosure"] or abort "generated item missing enclosure"
%w[url length sparkle:edSignature].each do |attr|
  abort "enclosure missing #{attr}" if (enc_out.attribute(attr)&.value).to_s.empty?
end
File.write(path, out)
puts "Wrote #{path} (version #{version}, len #{len})"
```

- [ ] **Step 3: Self-check with a fake input** (no real DMG needed for the XML path):

```bash
# Fabricate a fake sign_update + app to exercise parsing/idempotency, or run
# against a real DMG during the Task 12 dry run. Minimum: `ruby -c packaging/appcast.rb`
ruby -c packaging/appcast.rb   # syntax check; expect "Syntax OK"
```

- [ ] **Step 4: Commit.**

```bash
git add packaging/appcast.rb && git commit -m "feat(packaging): signed appcast item generator (inline notes)"
```

### Task 10: `fastlane mac release` lane

**Files:**
- Modify: `QuickInterviewEditor/fastlane/Fastfile`

**Interfaces:**
- Consumes: all `packaging/*.sh`, `packaging/appcast.rb`, Task 0's Keychain key,
  env: `RELEASE_S3_BUCKET` (default `playola-static`), `RELEASE_S3_PREFIX`
  (default `downloads/QuickInterviewEditor`), `AWS_PROFILE` (default `default`),
  `RELEASE_DOWNLOAD_HOST` (default `https://playola-static.s3.amazonaws.com`),
  `NOTARY_PROFILE`.

- [ ] **Step 1: Add the lane.** In `platform :mac do`:

```ruby
  desc "Build, sign, notarize, DMG, sign appcast, upload to S3 (LOCAL release)"
  lane :release do
    ensure_git_status_clean
    bucket = ENV.fetch("RELEASE_S3_BUCKET", "playola-static")
    prefix = ENV.fetch("RELEASE_S3_PREFIX", "downloads/QuickInterviewEditor")
    host   = ENV.fetch("RELEASE_DOWNLOAD_HOST", "https://playola-static.s3.amazonaws.com")
    profile = ENV.fetch("AWS_PROFILE", "default")

    sh("cd .. && packaging/package-engine.sh")          # reuse-cached logic lives in the script
    sh("cd .. && packaging/package-cut-suggester.sh")
    sh("cd .. && packaging/build-app.sh")
    sh("cd .. && packaging/sign-app.sh packaging/dist/QuickInterviewEditor.app")
    sh("cd .. && NOTARY_PROFILE=#{ENV['NOTARY_PROFILE']} packaging/notarize-app.sh packaging/dist/QuickInterviewEditor.app")
    sh("cd .. && packaging/make-dmg.sh")

    plist = "packaging/dist/QuickInterviewEditor.app/Contents/Info.plist"
    short = sh("cd .. && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' #{plist}").strip
    build = sh("cd .. && /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' #{plist}").strip
    name = "QuickInterviewEditor-#{short}-#{build}.dmg"     # matches make-dmg.sh
    dmg  = "packaging/dist/#{name}"
    url  = "#{host}/#{prefix}/#{name}"
    sign_update = sh("cd .. && find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f 2>/dev/null | head -1").strip

    # Pull the LIVE appcast down first so every prior <item> is preserved (rollback
    # depends on old entries staying in the feed). A clean release machine otherwise
    # regenerates a one-item feed and the upload drops history. Missing object is OK
    # only for the very first release; any other download error must fail the lane.
    sh(<<~SH)
      cd .. && if aws --profile #{profile} s3 cp 's3://#{bucket}/#{prefix}/appcast.xml' packaging/dist/appcast.xml 2>/dev/null; then
        echo "fetched existing appcast"
      elif aws --profile #{profile} s3 ls 's3://#{bucket}/#{prefix}/appcast.xml' 2>/dev/null; then
        echo "error: appcast exists but could not be downloaded" >&2; exit 1
      else
        echo "no existing appcast — first release"
      fi
    SH

    sh("cd .. && ruby packaging/appcast.rb '#{dmg}' '#{url}' '#{sign_update}'")

    # Keep old DMGs (no --delete). Upload the DMG, then the appended appcast last.
    sh("cd .. && aws --profile #{profile} s3 cp '#{dmg}' 's3://#{bucket}/#{prefix}/' ")
    sh("cd .. && aws --profile #{profile} s3 cp packaging/dist/appcast.xml 's3://#{bucket}/#{prefix}/appcast.xml' --content-type application/xml --cache-control no-cache")

    UI.success("Released #{short} (#{build}). Run the manual verification checklist (packaging/README.md) before announcing.")
  end
```

- [ ] **Step 2: Version bump helper.** Add a `bump` lane (or inline) that edits
  `MARKETING_VERSION` + increments the integer `CURRENT_PROJECT_VERSION` in
  `QuickInterviewEditor/project.yml`, then runs `xcodegen generate`. Run it before
  `release`, or accept a `version:` option. Keep it explicit so a release never
  reuses a `CFBundleVersion`.

- [ ] **Step 3: Dry-run validation** (no upload): run through `make-dmg` locally on
  a throwaway build, confirm `appcast.xml` gets a well-formed item. Documented in
  Task 12.

- [ ] **Step 4: Commit.**

```bash
git add QuickInterviewEditor/fastlane/Fastfile
git commit -m "feat(fastlane): mac release lane (build→sign→notarize→dmg→appcast→S3)"
```

### Task 11: CI appcast/version validation job

**Files:**
- Modify: `.github/workflows/tests.yml`

**Interfaces:** cheap checks only; CI never builds the DMG.

- [ ] **Step 1: Add a `validate` job** that (a) runs `ruby -c packaging/appcast.rb`,
  (b) `chmod`-checks the packaging scripts are executable, (c) asserts
  `CURRENT_PROJECT_VERSION` in `project.yml` is an integer and `MARKETING_VERSION`
  is semver, and (d) if `packaging/dist/appcast.xml` is ever committed, parses it.
  Example step:

```yaml
      - name: Validate release scripts + versions
        run: |
          ruby -c packaging/appcast.rb
          grep -Eq 'CURRENT_PROJECT_VERSION: "[0-9]+"' QuickInterviewEditor/project.yml
          grep -Eq 'MARKETING_VERSION: "[0-9]+\.[0-9]+\.[0-9]+"' QuickInterviewEditor/project.yml
          test -x packaging/make-dmg.sh
```

- [ ] **Step 2: Push branch, confirm the job passes in Actions.**

- [ ] **Step 3: Commit** (folded into the branch's PR).

### Task 12: Release runbook + invariants doc + Keychain round-trip test

**Files:**
- Modify: `packaging/README.md` (create if absent)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Core/KeychainClient.swift`
  (add an invariants comment)

- [ ] **Step 1: Write the runbook** in `packaging/README.md`:
  - Prerequisites: notarytool profile `qie-notary`, EdDSA key in Keychain +
    offline backup, `AWS_PROFILE`, `create-dmg`.
  - One-command release: `bundle exec fastlane mac release` (+ the `bump` first).
  - The **release-verification checklist** (from the spec's Testing section),
    verbatim, including the **Keychain round-trip**: install vN from DMG → save
    API key → publish vN+1 → in vN "Check for Updates…" → confirm the key still
    works with **no** Keychain prompt; and `codesign -d -r-` DR compare.
  - **Invariants** that must never change (Team ID, bundle id, Keychain
    service/account) and **why losing the EdDSA key is unrecoverable**.
  - Rollback: old DMGs stay in S3; to roll back, point the appcast's latest item
    back at a prior DMG.

- [ ] **Step 2: Add the invariants comment** near `KeychainStore.service` in
  `KeychainClient.swift` (one line: "Changing this string, the bundle id, or the
  Team ID breaks silent key reads across app updates — see packaging/README.md").

- [ ] **Step 3: Commit.**

```bash
git add packaging/README.md QuickInterviewEditor/QuickInterviewEditor/Core/KeychainClient.swift
git commit -m "docs(packaging): release runbook, invariants, Keychain round-trip test"
```

**End of PR 2.** Run the full local release once to a **staging prefix** in S3,
execute the Keychain round-trip test, then run `/codex review` + `/codex
challenge` on the diff before declaring done.

---

## Self-review (author check against the spec)

- **Spec coverage:** Sparkle integration (T1–T4), Keychain preservation (Global
  Constraints + T12 round-trip), one-DMG enclosure (T7), no deltas (constraint),
  local release lane (T10), inside-out signing guard (T8), appcast w/ inline notes
  + `sparkle:version`==`CFBundleVersion` + minimumSystemVersion (T2, T9),
  translocation (T5 + T6), EdDSA custody (Setup T0 + T12), CI validation (T11),
  version single-source (T2 + T10), rollback/old-DMG retention (T10 + T12). All
  spec sections map to a task.
- **Placeholders:** the only intentional `REPLACE_WITH_*` values are the public
  host + EdDSA public key, which are real inputs Brian supplies (called out in
  T2 and Setup T0), not undefined work.
- **Type consistency:** `UpdaterClient.{checkForUpdates,canCheckForUpdates}` used
  identically in T3/T4; `EngineResolver.resolve` signature matches
  `EngineResolution.swift`; `InstallLocation.shouldOfferMoveToApplications` used
  identically in T5.
```
