# Design: Transcript Page (macOS app — feature 1)

**Status:** approved; Step-1 fixture generated + committed; ready for implementation plan
**Date:** 2026-07-04
**Depends on:** `plans/roadmap-macos-app.md` (Phase 3, transcript half), `ux-prototype/README.md`, `CLAUDE.md`
**Architecture reviewed with Codex** (consult, session `019f2d79`).

## Goal

Stand up the SwiftUI macOS app **Quick Interview Editor** and its first page: a
read-only **Transcript** view that loads a real `edit-plan.json`, renders the
interview words, supports two-click word selection, and tints "run-together"
words red. This kills the Terminal for the *reading + selecting* step and proves
the whole architecture (XcodeGen project, Point-Free stack, engine-as-dependency,
tested `@Observable` model, dumb view) end to end on the smallest surface.

## Two-step delivery

The "import an audio file → process → show transcription" goal is split so a
working app lands before the hard (subprocess) part:

- **Step 1 (this spec):** scaffold + Transcript page against the **committed real
  fixture**, with a **sensitivity slider**. No subprocess — nothing can wedge.
  Day-one demoable: the real Hayes Carll transcript with adjustable red.
- **Step 2 (next spec):** wire the live `EngineClient` to run the engine (in dev,
  shell out to `.venv/bin/python -m logic_markers.cli`), add **file import** (drag
  / open panel) and a **progress UI**, so any clip transcribes live. The
  *packaged/notarized* engine remains roadmap Phase 1, still deferred.

## Scope (Step 1)

**In:**
- XcodeGen-generated Xcode project (`project.yml`) with the Point-Free SPM stack.
- `EditPlan` Codable model mirroring the engine's real JSON, **sample-native**.
- A tiny `EngineClient` dependency: `loadPlan(URL) async throws -> EditPlan`.
- `TranscriptPageModel` (`@Observable`, tested) + `TranscriptPageView` (dumb).
- Two-click word selection (anchor → focus inclusive; third click resets).
- Red "run-together" words derived from inter-word gaps, with a **sensitivity
  slider** (`runTogetherMaxGapMs`, default 30).
- The committed **real** `edit-plan.json` fixture (already generated; see below).
- Swift Testing suite for the model.

**Out (deliberately — avoids fake architecture / rework):**
- Waveform (Phase 4), slices/export (Phase 3 back half + 5), transport/playback,
  toolbar, zoom, fine-tune insets, undo/redo, markers.
- File import + spawning the engine subprocess (`transcribe`) — that's **Step 2**;
  `EngineClient` has **only** `loadPlan` for now.
- `@Shared` global state — the plan stays model-local until a second page needs it.
- Any use of `silences` / `segments` — decoded but **unused** in Step 1 (red comes
  from word gaps alone).

## Architecture

### Project layout (XcodeGen)

```
QuickInterviewEditor/
├── project.yml
├── QuickInterviewEditor/
│   ├── QuickInterviewEditorApp.swift
│   ├── Assets.xcassets/
│   ├── Resources/Fixtures/edit-plan.json      # real engine output, bundled
│   ├── Core/EngineClient.swift
│   ├── Models/EditPlan.swift
│   ├── State/SharedKeys.swift                 # placeholder; empty for now
│   └── Views/
│       ├── Reusable Components/ViewModel.swift
│       └── Pages/TranscriptPage/
│           ├── TranscriptPageModel.swift
│           └── TranscriptPageView.swift
└── QuickInterviewEditorTests/
    └── Views/Pages/TranscriptPage/TranscriptPageTests.swift
```

We drop a copy/symlink of `CLAUDE.md` into `QuickInterviewEditor/` once scaffolded
(per earlier decision).

### `project.yml` essentials

- **Target:** `QuickInterviewEditor`, `type: application`, `platform: macOS`,
  deployment target macOS 15, `PRODUCT_BUNDLE_IDENTIFIER: fm.playola.QuickInterviewEditor`
  (prefix to be confirmed; Codex assumed `com.playola.*`), `SWIFT_VERSION: 6.0`,
  `ENABLE_TESTABILITY: YES`.
- **Packages:** `swift-dependencies` (product `Dependencies`), `swift-sharing`
  (`Sharing`), `swift-identified-collections` (`IdentifiedCollections`),
  `xctest-dynamic-overlay` (`IssueReporting`), and `swift-custom-dump`
  (`CustomDump`, test target only).
- **Test target:** `QuickInterviewEditorTests`, `type: bundle.unit-test`. Links
  `DependenciesTestSupport` + `CustomDump` **only** — not the app's already-linked
  products (avoids duplicate-link issues).

**Gotchas (Codex-confirmed):**
- Swift Testing is built into the toolchain — **not** an SPM dependency; tests
  just `import Testing`.
- `swift test` won't work for an app project; run headless via
  `xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS'`.
- Commit `Package.resolved` after first generate.

### Data model — `EditPlan.swift`

Codable structs mirroring the engine's emitted shape exactly, with snake_case
`CodingKeys`. **Samples are the app's internal coordinate system**; seconds are
retained because the contract emits them and silence-gap math needs them.

```swift
struct EditPlan: Codable, Equatable {
  var schemaVersion: Int          // "schema_version"
  var source: Source
  var words: [Word]
  var silences: [Silence]
  var segments: [Segment]
}

struct Source: Codable, Equatable {
  var path: String
  var sampleRate: Int             // "sample_rate"
  var channels: Int
  var durationSamples: Int        // "duration_samples"
}

struct Word: Codable, Equatable, Identifiable {
  var id: Int
  var text: String
  var start: Double
  var end: Double?
  var startSample: Int?           // "start_sample"
  var endSample: Int?             // "end_sample"
}

struct Silence: Codable, Equatable {   // NOTE: engine emits SAMPLES here (not
  var start: Double                    // seconds), unlike words. Decoded but
  var end: Double                      // UNUSED in Step 1. Normalize in Phase 2.
}

struct Segment: Codable, Equatable, Identifiable {   // decoded, unused in feature 1
  var id: Int { index }
  var index: Int
  var outputName: String
  var wordIDs: [Int]
  var contentStartSample: Int
  var contentEndSample: Int
  var sourceStartSample: Int
  var sourceEndSample: Int
  var startStatus: String        // BoundaryStatus later; snapped|padded|…
  var endStatus: String
  var overlapsPrevious: Bool
  var overlapsNext: Bool
  var segmentIDs: [Int]
  var warnings: [String]
}

extension EditPlan { static var fixture: EditPlan { /* decode bundled JSON */ } }
```

The decoded plan is held model-local (`var editPlan: EditPlan?`), **not** `@Shared`.

### `EngineClient.swift`

```swift
struct EngineClient: Sendable {
  var loadPlan: @Sendable (URL) async throws -> EditPlan
}

extension EngineClient: DependencyKey {
  static var liveValue = EngineClient(
    loadPlan: { url in try JSONDecoder().decode(EditPlan.self, from: Data(contentsOf: url)) }
  )
}
extension EngineClient: TestDependencyKey {
  static var testValue = EngineClient(loadPlan: { _ in .fixture })
}
extension DependencyValues {
  var engine: EngineClient {
    get { self[EngineClient.self] } set { self[EngineClient.self] = newValue }
  }
}
```

No `transcribe`/`renderSlices` yet — added in **Step 2** (file import + live engine).

### Red "run-together" — definition (validated on real data)

**A pair of adjacent words is "run-together" (red) when the inter-word gap is
below a sensitivity threshold — `gap < runTogetherMaxGapMs` (default 30 ms).**
This is the "looks like one word on the waveform but functions as two" signal, and
it warns about *edit difficulty* on the raw transcript, before any cut.

Derivation (in the model, once, from `words` only):

- For adjacent `(wordᵢ, wordᵢ₊₁)`, `gapMs = (wordᵢ₊₁.start − wordᵢ.end) × 1000`.
- If `gapMs < runTogetherMaxGapMs`, both `wordᵢ` and `wordᵢ₊₁` get
  `isRunTogether = true`.

**Why gap size, not silence overlap (the original spec was wrong here):** verified
against the real Hayes Carll fixture. The engine's `silences` array only registers
pauses ≥120 ms *and is stored in samples, not seconds* — comparing it to per-word
gaps degenerates (flags 0 or ~all words). The honest signal is the raw inter-word
gap. WhisperX's alignment floor is ~20 ms; the 25/121 pairs sitting at that floor
(`want→to`, `in→the`, `you're→my`, `amp→in→the→trunk`) are exactly the fused ones.
`30 ms` cleanly captures the floor without over-flagging (40 ms → 73 pairs, too
many).

**Sensitivity setting:** `runTogetherMaxGapMs` is model state, exposed to the user
as a slider. Changing it recomputes `words` and the red highlights live — a first
demonstration that the red logic lives in the tested model, not the view. Suggested
range ~10–80 ms, default 30.

**Future:** may graduate to a first-class engine field (`word.tight_next`) so the
UI reads truth instead of a heuristic; `isRunTogether` stays the stable model seam.
Note this is a *different concept* from the engine's cut-boundary `padded` status
(that's about a chosen slice boundary landing where there is no silence); the two
share the theme "no clean gap" but must not be conflated.

### Selection model

- State: `selectionAnchorID: Word.ID?`, `selectionFocusID: Word.ID?` (IDs, never
  indices — indices break under future edits/reordering), and
  `runTogetherMaxGapMs: Double = 30` (the sensitivity setting).
- Derived (computed once per state change, and whenever the sensitivity slider
  moves): `words: IdentifiedArrayOf<WordViewState>` and
  `selectedSampleRange: Range<Int>?`.

```swift
struct WordViewState: Identifiable, Equatable {
  var id: Word.ID
  var text: String
  var startSample: Int?
  var endSample: Int?
  var isSelected: Bool
  var isRunTogether: Bool
}
```

`selectedSampleRange` is exposed now (view ignores it) so Phase 4 waveform sync
needs no model reshape.

Two-click behavior in `wordTapped(_ id: Word.ID)`:
1. No selection (or third click): `anchor = focus = id`.
2. Anchor set, second distinct click: `focus = id` → inclusive range selected.
3. Third click: reset to a fresh single-word anchor.

### `TranscriptPageModel` (per CLAUDE.md MARK order)

- **Dependencies:** `@Dependency(\.engine)`.
- **Properties:** `editPlan`, `selectionAnchorID`, `selectionFocusID`,
  `runTogetherMaxGapMs` (sensitivity), `words: IdentifiedArrayOf<WordViewState>`,
  `isLoading`, `presentedAlert`, plus all display strings (empty/error text,
  legend copy, caption labels, sensitivity slider label/bounds).
- **View Helpers:** `selectionSummary`, `selectedSampleRange`, `hasSelection`,
  `runTogetherCountLabel`, etc.
- **User Actions:** `viewAppeared() async` (loads the fixture via engine),
  `wordTapped(_:)`, `clearSelectionTapped()`, `sensitivityChanged(_ ms: Double)`.
- **Private Helpers:** `recomputeWords()` (rebuilds `WordViewState` from plan +
  selection + gap-derived run-together at the current `runTogetherMaxGapMs`).

### `TranscriptPageView` (dumb)

Renders `model.words` (Playola dark theme from `ux-prototype/README.md`: `#000`
bg, red `#cc6666` selection, run-together `#e39393`, Inter/Space Grotesk),
binds every string to the model, calls `model.wordTapped(id)`. **Zero logic** — no
range checks, no color decisions, no conditional strings.

## Fixture strategy (real engine output — DONE)

The fixture is generated and committed at
`QuickInterviewEditor/Resources/Fixtures/edit-plan.json`: 122 words, 25 silences,
1 segment, from a 42 s Hayes Carll interview clip. It exercises the red signal
(25/121 run-together pairs at 30 ms).

Workflow (durable + reproducible, no copyrighted audio in git):
- **Source clip** lives in one canonical, gitignored, durable location outside the
  ephemeral worktrees: `~/playola/logic-utils/.context/audio/hayes-carll-intro.m4a`
  (`.context/` is now in the tracked `.gitignore` so it is ignored in the main
  checkout too, not just via Conductor's local exclude). The clip is **not**
  committed (licensing + size).
- **`scripts/regen-fixture.sh [audio]`** (committed) re-runs `transcript` + `cut`
  and installs a normalized `edit-plan.json` into the fixtures dir. Defaults to the
  canonical clip via `QIE_FIXTURE_AUDIO`; normalizes `source.path` to
  `fixtures/hayes-carll-intro.m4a`. Requires a `.venv` engine env in the workspace.
- Regeneration is rare (clip or engine-param change); the committed JSON is what
  the app and tests consume, so it travels through git to every workspace.

## Testing plan (Swift Testing, colocated)

`TranscriptPageTests` (`@MainActor struct`, `import Testing`), value comparisons
via `expectNoDifference`/`expectDifference`:

- `viewAppeared` loads the plan → `words` populated (count matches fixture).
- First tap sets anchor → single word selected.
- Second tap extends inclusive range (assert exact selected IDs + `selectedSampleRange`).
- Third tap resets to new single-word selection.
- Tapping the anchor again / same word behaves per rule.
- `clearSelectionTapped` empties selection.
- Run-together at default 30 ms: known fused pairs (e.g. `want`/`to`, `in`/`the`)
  have `isRunTogether == true`; a clearly-separated pair does not.
- Sensitivity: `sensitivityChanged(10)` shrinks the run-together set;
  `sensitivityChanged(80)` grows it (assert exact counts against the fixture).
- `selectionSummary` / `runTogetherCountLabel` / display strings correct for empty
  and active selection.

Mock via `withDependencies { $0.engine.loadPlan = { _ in .fixture } }`; no
subprocess, no audio, no `Task.sleep`.

## Risks / open questions

- **Bundle-ID prefix** unconfirmed (`fm.playola.*` vs `com.playola.*`).
- **Swift 6 language mode** may surface Sendable friction with `@Observable` +
  Point-Free; fall back to Swift 5 mode for the target if it fights us (match
  `playola-radio-ios`).

Resolved during brainstorm: fixture clip chosen + generated; engine env set up in
this worktree; red definition validated on real data (gap-based, not silence);
`silences` confirmed sample-valued (decoded but unused in Step 1).

## Out of scope / deferred

Waveform, slices, export, transport, zoom, fine-tune, undo/redo, markers, engine
subprocess, `@Shared` promotion, native inference. The `EditPlan` contract and
sample-native model leave room for all of them.
