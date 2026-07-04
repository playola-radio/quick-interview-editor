# Quick Interview Editor — macOS app

A native macOS (SwiftUI) app that cuts a long spoken-word interview into Logic
Pro-ready AIFF chunks. It drives the existing, tested Python engine
(`logic_markers/`) as a subprocess and builds its UI on the engine's
`edit-plan.json` contract. See `plans/roadmap-macos-app.md` for the phase plan
and `ux-prototype/README.md` for the high-fidelity design reference.

**The Swift app is structured exactly like the sibling app
`~/playola/playola-radio-ios`:** MV architecture with `@Observable`, fully tested
view models, and **zero logic in the views**. When in doubt about a pattern, look
at how `playola-radio-ios` does it (especially its `Views/Pages/**` trios and its
`.claude/` docs) and match it.

---

## ALWAYS use the Point-Free Workflow (pfw-*) skills

This app is built on Point-Free libraries (`swift-dependencies`, `swift-sharing`,
`swift-identified-collections`, `swift-custom-dump`, and Swift Testing). **Before
writing or planning any Swift code in this repo, invoke every `pfw-*` skill that
applies to the task.** This is mandatory, not optional.

Rough mapping:

- Writing/editing an `@Observable` model (any `*Model.swift` in `Views/Pages/`) → `pfw-observable-models`
- Writing/editing a dependency client (`@Dependency`, `liveValue`/`testValue`) → `pfw-dependencies`
- Writing tests (mutation/action tests) → `pfw-testing` **and** `pfw-custom-dump` (use `expectNoDifference` / `expectDifference`, not raw `#expect(a == b)`, for value comparisons)
- Adding/editing `@Shared` keys / state → `pfw-sharing`
- Working with `IdentifiedArrayOf<…>` → `pfw-identified-collections`
- Asserting on enum cases with associated values → `pfw-case-paths`
- SwiftUI views (bindings, `@State` init, modern patterns) → `pfw-modern-swiftui`
- Error reporting (`reportIssue`, `withErrorReporting`) → `pfw-issue-reporting`
- Snapshot testing → `pfw-snapshot-testing`

If you dispatch subagents, instruct each one to invoke the relevant `pfw-*`
skills before writing code and to list them in its checklist.

---

## Architecture

**Pattern: MV with `@Observable` models (not MVVM, not TCA).** A page is a trio,
colocated in one folder:

```
Views/Pages/<Name>Page/
├── <Name>PageModel.swift   # @Observable view model — all state + behavior
├── <Name>PageView.swift    # SwiftUI view — visuals only
└── <Name>PageTests.swift   # Swift Testing suite for the model
```

All view models inherit from a shared `ViewModel` base class and are `@MainActor`:

```swift
@MainActor
class ViewModel: Hashable {
  init() {}
  nonisolated static func == (lhs: ViewModel, rhs: ViewModel) -> Bool {
    ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
  }
  nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}
```

### Model structure

Organize every model with these `// MARK:` sections, in this order:

```swift
@MainActor
@Observable
class TranscriptPageModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.engine) var engine

  // MARK: - Shared State
  @ObservationIgnored @Shared(.editPlan) var editPlan

  // MARK: - Initialization
  init(...) { ...; super.init() }

  // MARK: - Properties
  var words: IdentifiedArrayOf<WordVM> = []
  var isLoading = false
  var presentedAlert: PlayolaAlert?

  // MARK: - View Helpers        (derived display values — computed vars)
  var selectionSummary: String { ... }

  // MARK: - User Actions        (named after what the user did)
  func viewAppeared() async { }
  func wordTapped(_ id: Word.ID) { }

  // MARK: - Private Helpers
  private func recompute() { }
}
```

### Model / View responsibilities

**The Model is the complete, portable representation of the page.** If we ever
port to another platform, only the View should need rebuilding. The Model holds
everything: all text, all derived display values, all state, all behavior.

**Model (everything except pixels):**
- All display text (titles, labels, button text, empty/error states)
- All computed display values (formatted times, durations, counts, red/tight-join
  flags derived from `edit-plan.json` boundary status)
- All business logic, state, and validation
- All action handlers

**View (visuals only):**
- Layout, spacing, colors, fonts, the waveform/transcript rendering
- Binds to model properties for **all** content — never hardcode a string
- Calls model methods for **all** user actions
- **Contains zero logic — not even a conditional deciding which text to show.**
  If a view needs to decide *what* to display, that decision belongs on the model
  as a computed property (`var xLabel: String`, `var shouldShowY: Bool`).

```swift
// View
Text(model.emptyStateMessage)   // Good
Text("No slices yet")           // Bad — hardcoded string
if model.shouldShowFineTunePanel { ... }   // Good — model decides
```

**Action-method naming** — describe the user action, not the implementation:

```swift
func addSliceTapped() { }    // Good
func exportAllTapped() async { }  // Good
func createSlice() { }       // Bad — describes implementation
```

---

## Dependencies (`swift-dependencies`)

Every side-effecting boundary is a `Sendable` dependency-client struct with a
`liveValue` and a `testValue`, injected via `@Dependency` and overridden in tests
with `withDependencies { $0.x = ... }`.

**The Python engine is a dependency.** It's wrapped as an `EngineClient`
(spawns the packaged `logic-markers-engine`, talks JSON over stdio, returns a
decoded `EditPlan`). This keeps models testable against fixtures with **no
subprocess, no audio, no models downloaded** in tests:

```swift
struct EngineClient: Sendable {
  var transcribe: @Sendable (URL) async throws -> EditPlan
  var renderSlices: @Sendable (EditPlan) async throws -> [URL]
}

extension EngineClient: TestDependencyKey {
  static var testValue: EngineClient {
    EngineClient(
      transcribe: { _ in .fixture },        // load a bundled edit-plan.json
      renderSlices: { _ in [] }
    )
  }
}
extension DependencyValues {
  var engine: EngineClient {
    get { self[EngineClient.self] } set { self[EngineClient.self] = newValue }
  }
}
```

Keep model logic driven by the decoded `EditPlan`, never by re-parsing raw audio
in the UI. The engine analyzes and (on export) revalidates + renders; all
interactivity (selection, zoom, fine-tune, undo/redo) lives in Swift model state.

---

## State management (`swift-sharing`)

Cross-view state (the loaded edit plan, current selection, slices) uses
`@Shared`. Model-local state is a plain `@Observable` property.

In tests, declare `@Shared` **locally inside each test** with an initial value —
never as class-level properties, never `$shared.withLock` in tests:

```swift
@Test func selectingWordsUpdatesSelection() {
  @Shared(.editPlan) var editPlan = .fixture
  let model = TranscriptPageModel()
  // ...
}
```

---

## Testing

**Every view model is tested. Test the model, never the view.** Because the view
holds no logic, testing the model tests the behavior.

- **Framework: Swift Testing** (`import Testing`, `@MainActor struct X…Tests`,
  `@Test`, `#expect`). Match the newest `playola-radio-ios` tests
  (e.g. `RecordIntroPageTests.swift`).
- **Colocated**: `TranscriptPageModel.swift` → `TranscriptPageTests.swift` in the
  same folder.
- **Value comparisons** use `expectNoDifference` / `expectDifference` from
  `swift-custom-dump`, not raw `#expect(a == b)`.
- **Test naming**: camelCase, no underscores (`testWordTappedExtendsSelection`).
- **Prefer TDD**; always add a regression test for a bug fix.
- **Mock dependencies** via `withDependencies { $0.engine = ... }`; use
  `ImmediateClock` / `withMainSerialExecutor` for time and ordering.
- **NEVER use `Task.sleep` in tests** — it makes them slow and flaky. Use
  synchronous assertions and test doubles that resolve immediately.
- Use bundled `edit-plan.json` fixtures so tests never touch real audio or the
  Python subprocess.

---

## Project structure (target)

```
pangyo/
├── logic_markers/        # Python engine (stays; driven as a subprocess)
├── tests/                # Python engine tests (pytest)
├── ux-prototype/         # HTML design reference (do NOT ship)
├── plans/                # roadmap-macos-app.md
└── QuickInterviewEditor/ # the SwiftUI app (to be scaffolded)
    ├── Core/             # dependency clients (EngineClient, audio, waveform)
    ├── Models/           # Codable data models (EditPlan, Word, Slice)
    ├── State/            # @Shared key definitions
    └── Views/
        ├── Pages/        # each page = Model + View + Tests
        └── Reusable Components/   # incl. ViewModel base class
```

## macOS specifics

- SwiftUI-first; drop to `NSViewRepresentable`/`AppKit` only where needed (the
  custom waveform renderer — see roadmap Phases 4–5). Even then, all decisions and
  state stay in the model; the representable is a dumb renderer bound to model data.
- Single main window with the standard traffic-light title bar.
- Model everything in **samples** (per roadmap decision 4) so Swift and the engine
  agree on coordinates.

## Code style / tooling (to establish when scaffolding the Xcode project)

- **Linting**: SwiftLint. **Formatting**: swift-format. Wire both to a
  `make format` / `make lint` and a pre-commit hook, mirroring `playola-radio-ios`.
- Use `async/await`, no completion handlers.
- Alerts via a `PlayolaAlert` enum; navigation via a coordinator enum
  (mirror the iOS app's patterns).

---

## The Python engine (`logic_markers/`) — do not rewrite

The engine already does the hard parts (WhisperX forced alignment, silence-aware
chunking that never clips a word, tight-join fades, AIFF `MARK` writing) and is
covered by the `tests/` pytest suite. Keep it a boring, deterministic function
`audio + edit-plan → resolved plan + AIFFs`. `edit-plan.json` is the contract
between it and the app (roadmap decision 3). Run engine tests with
`python3 -m pytest -q`.
