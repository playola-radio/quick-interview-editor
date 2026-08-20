# Plan: Speed up the Swift test/iterate loop

**Status: RESOLVED BY THE CHEAP WIN (`make test-fast`). SPM extraction
deprioritized — probably not worth it for speed alone (see Measured Results).**

## Measured Results (2026-08-19, Xcode 27 beta, this machine)

Ran `xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS'
CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/qie-fasttest-dd` (dedicated
warm-able DerivedData, no fastlane, no signing):

| Run | Wall time | Notes |
|-----|-----------|-------|
| **COLD** (DerivedData wiped) | **50s** | machine SPM/module caches still warm; compiled app + 79 test files + ran tests |
| **WARM** (no code change) | **15s** | ~9s of that is executing the tests |

- `826 tests in 78 suites passed after 9.055s` — real, not a no-op build.
- `CodeSign` invocations: **0** (CODE_SIGNING_ALLOWED=NO worked).

**Conclusion:** app compilation is NOT the bottleneck — the unsigned + warm loop
was measured directly at ~15s. What was **measured** is only the fast path; the
~10-min `make test` cost was **not isolated**. The likely contributors — the
fastlane/xcbeautify wrapper, **code signing** (Apple ID token fetch/stalls, see
the build memory note), and/or clean builds from `xcodegen generate` busting
DerivedData — are a hypothesis, not separately timed. If we ever want the exact
split, time `bundle exec fastlane mac test` (signed) against the same warm
DerivedData and compare. Note `make test` signs locally but disables signing in
CI (the Fastfile adds `CODE_SIGNING_ALLOWED=NO` when `ENV['CI']`).

**The 9s test-execution floor caps further gains.** Even a perfect SPM extraction
can't beat the ~9s it takes to run 826 tests, and the warm build overhead is only
~6s on top. So EditorCore would move the warm loop from ~15s to maybe single
digits — a real but small marginal win that does not justify the migration cost
*for speed*. Keep the SPM plan below only if we later want it for architectural
reasons (portability, module boundaries), not for the loop.

---

## SUPERSEDED — original SPM/EditorCore extraction plan (historical reference only)

Everything below predates the Measured Results above. It is retained as reference
material for a possible *architecture-motivated* extraction. **It is NOT current
speed guidance and NOT an active recommendation** — do not implement it to speed
up the test loop. Where the text below calls the extraction "the durable fix,"
read that as the original framing, now superseded by the measured conclusion that
the cheap win resolves the speed problem.

### Problem (original framing)

Running `QuickInterviewEditorTests` takes ~10 min to build + execute. CI-fine,
terrible for iteration.

**Root cause (as originally understood):** the test target
`QuickInterviewEditorTests` (`bundle.unit-test`) depends on the full app target
`QuickInterviewEditor` (`application`). So every test run compiles all ~91 app
Swift files (including ~26 SwiftUI/AppKit view + TextKit/waveform renderer files +
the App shell), builds Sparkle from source, and **code-signs an app bundle + a
test bundle** before a single model test runs. (Measurement later showed the
compile portion is fast; signing + wrapper + clean builds are the suspected cost.)

**Key facts that make the extraction clean:**

- Every tested type (11 `*Model.swift` view models + `Models/` + `State/` + most
  of `Core/`) imports only Foundation, Dependencies, Observation, IssueReporting,
  Sharing, IdentifiedCollections, CoreGraphics. **Zero SwiftUI, zero AppKit.**
  ("No logic in views" held.)
- **No swift-syntax macros anywhere** → macro compilation is NOT the bottleneck.
- Only 4 `Core` clients have platform-coupled *live* impls: `WorkspaceClient`
  (AppKit), `InstallLocation` (AppKit), `UpdaterClient` (Sparkle),
  `KeychainClient` (Security/Synchronization — NOT Sparkle; corrected during
  Codex review). Tests use their `testValue`, never the live impl.

### Approach (validated by Codex, consult session `01a01c9a-9a15-7013-98bd-517a49157ae2`)

Extract the pure-logic layer into ONE local Swift Package library target
`EditorCore`. The Xcode app target depends on it and keeps only views/renderers/
App-shell + the platform-coupled *live* client impls. Model tests move into the
package and run via `swift test` (Swift Testing runs natively). Expected loop:
seconds incrementally, ~30–90s cold, vs 10 min.

**Do NOT over-split.** One `EditorCore` target first. Splitting into
`Models`/`EditorFeature`/`EngineClient` now buys nothing for the loop and creates
access-control churn + more chances to double-link Point-Free deps.

### Module split

- `EditorCore` (SPM lib): `Models/`, `State/`, pure `Core/`, all pure
  `*Model.swift` view models, dependency-client **interfaces + testValues**.
  Declares the Point-Free deps in its `Package.swift`. Must NOT import
  Sparkle/AppKit.
- `QuickInterviewEditor` (app): SwiftUI/AppKit/Sparkle app shell, views,
  renderers, key monitors, Commands, and the **live** client impls (AppKit /
  Sparkle / Security).

### Platform clients — option (a): interface+testValue in package, live in app

```swift
// EditorCore
public struct WorkspaceClient: Sendable { public var chooseDirectory: @Sendable () async -> URL?; public var reveal: @Sendable ([URL]) -> Void }
extension WorkspaceClient: TestDependencyKey { public static let testValue = ... }
extension DependencyValues { public var workspace: WorkspaceClient { ... } }
```

```swift
// app target
import AppKit; import EditorCore
extension WorkspaceClient: DependencyKey {
  public static let liveValue = WorkspaceClient(
    chooseDirectory: { /* NSOpenPanel */ },
    reveal: { NSWorkspace.shared.activateFileViewerSelecting($0) })
}
```

Same for `UpdaterClient` (keep `SPUStandardUpdaterController` out of EditorCore).
`InstallLocation` likewise. `KeychainClient` optional — its live impl is
`Security`, not Sparkle, so lower build-cost class, but keep live OS side effects
out of the fast package for consistency.

Keeping Sparkle out of EditorCore's graph is correct even if it's cached — the
big win is removing the app bundle + view files + signing.

### XcodeGen consumption (`project.yml`)

```yaml
packages:
  EditorCore: { path: EditorCore }
  Sparkle: { url: https://github.com/sparkle-project/Sparkle, exactVersion: "2.9.6" }
```

App target `dependencies:` → `package: EditorCore, product: EditorCore` +
Sparkle. Move the Point-Free deps OUT of `project.yml` into
`EditorCore/Package.swift`; remove them from the app target unless an app-only
file imports one directly. **Pin to the currently-resolved versions and commit
the new `Package.resolved`** — moving constraints from XcodeGen to Package.swift
does NOT guarantee an identical transitive graph. Current resolved versions:
swift-dependencies 1.14.1, swift-sharing 2.9.1, swift-identified-collections
1.1.1, swift-custom-dump 1.6.1, xctest-dynamic-overlay 1.10.1, Sparkle 2.9.6.

### The `@TaskLocal` double-link trap (highest-risk item)

Old bad shape: test bundle links `Dependencies` AND app bundle links
`Dependencies` + `@testable import QuickInterviewEditor` → two copies of the
task-local storage → `withDependencies` overrides silently miss. **In the new
world it goes away** because `EditorCoreTests → EditorCore → Dependencies` is one
SwiftPM graph product and no app bundle is loaded. SPM tests may import
`Dependencies` directly and still be fine. Keep it minimal: test target depends
on `EditorCore`, `CustomDump`, and only the Point-Free products it imports
directly. Transition danger: while both the app target's direct Point-Free deps
and the package coexist, you can get ambiguous/duplicated linkage — remove the
app target's direct Point-Free deps as the importing files move.

### Fixtures

`resources: [.copy("Fixtures/edit-plan.json"), .copy("Fixtures/edit-plan-v2.json"), .copy("Fixtures/project-state.json")]`
on `EditorCoreTests`. Change the fixture helper from `Bundle(for: BundleToken.self)`
to `Bundle.module`. Keep any runtime-needed app fixtures in the app target
separately — don't conflate test and app resources.

### Stages (each keeps the app building + tests green; independently shippable)

#### Stage 1: EditorCore package skeleton

**Goal**: `EditorCore/Package.swift` + empty `EditorCore` target + dep
declarations + one smoke test. No production code moved.
**Success**: `cd EditorCore && swift test` passes.

#### Stage 2: Move pure Models/State/Core

**Goal**: Move `Models/`, `State/`, pure `Core/` into `EditorCore`; app imports
`EditorCore`; move matching tests + fixture helper; convert to `Bundle.module`.
**Success**: app builds; moved tests pass under `swift test`.

#### Stage 3: Split platform clients (the important architectural PR)

**Goal**: `WorkspaceClient`, `UpdaterClient`, `InstallLocation`, optionally
`KeychainClient` — interfaces/testValues in EditorCore, live AppKit/Sparkle/
Security impls in app-only files.
**Success**: app builds; `swift test` does NOT resolve Sparkle.

#### Stage 4: Move page models + remaining logic tests

**Goal**: Move pure `*Model.swift` into `EditorCore`; views stay in app and
import `EditorCore`; move remaining model tests into `EditorCoreTests`.
**Success**: app builds; the bulk of the suite runs via `swift test`.

#### Stage 5: Retire app-dependent unit tests

**Goal**: Shrink `QuickInterviewEditorTests` to true app integration/smoke tests
only (or remove). Dev loop becomes `cd EditorCore && swift test`; CI still
builds/tests the app.

### Cheap wins (these are what actually resolved the speed problem)

```sh
xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

with **warm DerivedData** and **without** re-running `xcodegen generate`:

- `CODE_SIGNING_ALLOWED=NO` for local test builds (now `make test-fast`)
- stop running `xcodegen generate` every loop (only on `project.yml` change)
- `-only-testing:QuickInterviewEditorTests/SomeSuite` for focused iteration

Measurement (above) showed warm+unsigned drops to ~15s, so these mitigations —
not the SPM extraction — are the fix.

### Process note

If ever picked up for architectural reasons: follow the repo's
Architect-with-Codex pipeline — the architecture above is already Codex-validated
(consult session id in `.context/codex-session-id` if saved); implement via
TDD/incremental commits; run Codex review + challenge on the final diff before
the PR. Invoke the relevant `pfw-*` skills (pfw-dependencies, pfw-spm,
pfw-testing) before writing code.
