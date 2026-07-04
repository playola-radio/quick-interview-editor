# Design: Step 2 — Import + Live Engine (macOS app)

**Status:** approved (brainstorm); ready for implementation plan
**Date:** 2026-07-04
**Depends on:** `plans/roadmap-macos-app.md` (Phase 3 front half), Step 1 spec
(`docs/superpowers/specs/2026-07-04-transcript-page-macos-design.md`),
`docs/superpowers/STEP1-FOLLOWUPS.md`, `CLAUDE.md`, `ux-prototype/README.md`.
**Architecture reviewed with Codex** (consult, session `019f2ef9`).

## Goal

"Drop any clip and watch it transcribe." Turn the Step-1 fixture-only Transcript
page into a real, multi-song app:

1. **File import** — drag an audio file onto the window, or use an open panel.
2. **Live engine** — `EngineClient` grows a `transcribe` surface that, in dev,
   shells out to `.venv/bin/python -m logic_markers.cli` (the packaged/notarized
   path stays roadmap Phase 1, deferred).
3. **Progress + cancel + real errors** — transcription takes minutes and downloads
   WhisperX models on first run, so we need honest progress, a cancel path, and
   real error handling (the live engine can fail, unlike a bundled fixture).
4. **Multi-song tabs** — each imported clip opens in its own tab and transcribes
   independently; the result flows into the existing Transcript rendering.

**Out of scope (unchanged from the roadmap):** waveform (Phase 4), slices/export
(Phase 5), app packaging/notarization (Phase 1), `@Shared` promotion, native
inference.

## Why a new engine command (the key design problem)

The Transcript page consumes an `EditPlan`: `source` (sample_rate/channels/
duration_samples) + `words` **with samples** + `silences` + `segments`. Today that
exact shape is produced **only** by the CLI `cut` command. A fresh import →
`transcript` produces a different, thinner artifact: words with **seconds only**
(no `start_sample`/`end_sample`), whisper segments, and **no** silences or source
metadata — because samples and silences come from the AIFF conversion that only
`cut` performs.

`cut` is an **export** command: it parses an *edited* transcript, resolves kept
blocks, snaps boundaries, slices AIFFs, and writes files next to the source. Import
needs **analysis, not rendering**. Faking import through a "trivial single-block
cut" would (a) write slice AIFFs to disk (Phase-5 export, out of scope), (b)
pollute the user's folder, and (c) couple import to export semantics — an
immediate design smell.

**Decision: add a new `plan` subcommand that analyzes without cutting.** This is
the roadmap's "engine analyzes; export renders" split (decision 3) and makes
samples the stable coordinate system Phases 4–5 depend on.

## Engine: the `plan` subcommand

```
.venv/bin/python -m logic_markers.cli plan <audio> \
    --work-dir <dir> [--sample-rate 44100] [--refresh]
```

- **stdout:** exactly one `edit-plan.json` (machine JSON, nothing else).
- **stderr:** structured progress events (below) + tolerated third-party noise
  (tqdm/model-download chatter).

Steps (reusing existing engine internals — `_load_or_transcribe_transcript`,
`convert_to_aiff`, `read_aiff_mono`, `detect_silences`, `build_edit_plan`):

1. Load or create the transcript in `--work-dir` (**not** beside the user's clip).
2. Convert the source to a canonical PCM AIFF (in the work dir / temp).
3. Read the **actual** sample rate, channels, and duration from that AIFF.
4. Compute `start_sample`/`end_sample` for every word. Fill a missing word `end`
   using the same fallback `editplan._word_end` uses (next word's start, or a short
   assumed duration for the last word) so the UI always has a range.
5. Detect silences (samples), same params as `cut`.
6. Emit `edit-plan.json` with `segments: []` (no cut yet).

`plan` must **never** write `.transcript.json`, `.txt`, `.aiff`, or
`.edit-plan.json` beside the user's clip. The existing `markers`/`transcript`/`cut`
commands keep their current next-to-source behavior; only the GUI-facing `plan`
command is work-dir-clean.

### Progress events (stderr NDJSON)

One JSON object per line, prefixed so Swift can filter engine events from noise:

```
QIE_EVENT {"type":"progress","phase":"transcribing","message":"Transcribing with WhisperX (first run downloads models)"}
QIE_EVENT {"type":"progress","phase":"converting","message":"Converting audio"}
QIE_EVENT {"type":"progress","phase":"analyzing_silence","message":"Finding silence"}
QIE_EVENT {"type":"progress","phase":"writing_plan","message":"Preparing transcript"}
```

Phases: `transcribing`, `converting`, `analyzing_silence`, `writing_plan`. **No
percentages** — first-run model download is genuinely indeterminate; phase + spinner
is the honest signal. We do **not** parse the existing human `[1/4]` stdout lines
(accidental UI). stdout stays pure JSON.

### Engine tests (pytest)

- `plan` emits valid JSON to stdout with `source`, sample-bearing `words`,
  `silences`, and `segments == []`.
- `plan` writes nothing next to the source (assert the source dir is unchanged;
  caches land in `--work-dir`).
- Progress `QIE_EVENT` lines appear on stderr, in order, one JSON object per line.
- Every word has a non-null `end_sample` (fallback fills the last word).
- Reuse a small cached transcript fixture so tests never run WhisperX.

## Swift: `EngineClient.transcribe`

```swift
struct EngineClient: Sendable {
  var loadPlan: @Sendable (URL) async throws -> EditPlan
  var transcribe: @Sendable (URL, URL) -> AsyncThrowingStream<EngineEvent, Error>
  //                          audio  workDir
}

enum EngineEvent: Equatable, Sendable {
  case progress(EngineProgress)
  case completed(EditPlan)
}

struct EngineProgress: Equatable, Sendable {
  enum Phase: String, Equatable, Sendable {
    case transcribing, converting, analyzingSilence, writingPlan
  }
  var phase: Phase
  var message: String
}
```

The page/model consumes the stream and never touches subprocess details. The stream
yields zero or more `.progress` then exactly one `.completed`, or throws.

### Live implementation (dev)

- Resolve the dev engine: `<repo>/.venv/bin/python -m logic_markers.cli plan …`.
  The interpreter/repo path is a dev-only constant for Step 2 (documented as such;
  the packaged helper is Phase 1). If the `.venv` python is missing, throw a clear
  `EngineClientError` the UI surfaces ("dev engine not found at …").
- Spawn python in **its own process group** (`posix_spawn` with
  `POSIX_SPAWN_SETPGROUP`, or a small spawn helper) — `Foundation.Process` gives no
  clean new-process-group knob, and `process.terminate()` alone leaves the child
  `afconvert` / model-download processes running.
- Read stderr line-by-line: lines starting `QIE_EVENT ` decode to `.progress`;
  everything else is ignored (logged at debug). Read stdout fully; on clean exit,
  decode it to `EditPlan` and yield `.completed`.
- **Cancellation:** on `Task` cancel, `SIGTERM` the process group (`kill(-pgid, …)`),
  wait briefly, then `SIGKILL` if it lingers. Drain both pipes so shutdown doesn't
  deadlock.
- **Errors:** non-zero exit, un-decodable stdout, or a spawn failure throw a typed
  `EngineClientError` carrying a user-facing message and captured stderr tail.

### Work directory

Swift creates a per-job dir under
`~/Library/Application Support/Quick Interview Editor/Jobs/<stable-id>/` and passes
it as `--work-dir`. Caches + the temp AIFF live there, off the user's folder.
(Cleanup policy is a later concern; Step 2 may leave them.)

### `testValue` hardening (Step-1 follow-up)

Missing overrides must **fail cleanly**, not SIGTRAP via a `Bundle.main`
force-unwrap:

```swift
extension EngineClient: TestDependencyKey {
  static let testValue = EngineClient(
    loadPlan: { _ in
      reportIssue("EngineClient.loadPlan called without a test override")
      throw EngineClientError.unimplemented("loadPlan")
    },
    transcribe: { _, _ in
      AsyncThrowingStream { $0.finish(throwing: EngineClientError.unimplemented("transcribe")) }
      // also reportIssue at creation time
    }
  )
  static let previewValue = EngineClient(
    loadPlan: { _ in .fixture },
    transcribe: { _, _ in
      AsyncThrowingStream { c in c.yield(.completed(.fixture)); c.finish() }
    }
  )
}
```

Existing `loadPlan` tests already override `engine.loadPlan`; the one live-decode
test calls `liveValue` directly. Previews use `previewValue`. Tests never silently
hit bundled app resources.

## Swift: app structure (in-app tabs)

Chosen over native window tabs / `DocumentGroup` because this app's architecture is
tested `@Observable` models with zero logic in views; in-app tabs keep window state
in plain models we control and test, and port to native tabs later if wanted.

```
Views/
├── Pages/
│   ├── RootPage/            # tab host + empty import screen
│   │   ├── RootModel.swift
│   │   ├── RootView.swift
│   │   └── RootTests.swift
│   ├── ImportPage/          # empty-state drop zone + open panel + Load sample
│   │   ├── ImportPageModel.swift
│   │   ├── ImportPageView.swift
│   │   └── ImportPageTests.swift
│   └── SongTab/             # one imported song: progress → transcript
│       ├── SongTabModel.swift
│       ├── SongTabView.swift
│       └── SongTabTests.swift
└── Pages/TranscriptPage/    # Step-1 trio: pure renderer of a loaded EditPlan
```

### `RootModel`

- **Properties:** `tabs: IdentifiedArrayOf<SongTabModel>`, `selectedTabID: SongTabModel.ID?`,
  plus display strings (window/empty copy).
- **View helpers:** `showsEmptyState: Bool` (`tabs.isEmpty`), `tabTitles`, etc.
- **User actions:** `fileDropped(_ urls: [URL])` / `filePicked(_ url:)` →
  `openSong(url:)` (append a `SongTabModel`, select it, start its transcription);
  `loadSampleTapped()` (open a tab seeded directly with `EditPlan.fixture` in the
  `.loaded` phase — no engine call, a zero-wait demo); `tabSelected(_:)`,
  `tabClosed(_:)` (cancel that tab's job).
- Dropping a file works whether the empty screen or an existing tab is showing.

### `SongTabModel`

Owns one song end to end:

- **Dependencies:** `@Dependency(\.engine)`.
- **Properties:** `sourceURL: URL`, `workDir: URL`, `phase: TabPhase`
  (`.transcribing(EngineProgress?)` → `.loaded(EditPlan)` → `.failed(message)`),
  the transcript rendering state (Step-1 `TranscriptPageModel` logic — words,
  selection, `runTogetherMaxGapMs`, `presentedAlert`), and a handle to the running
  `Task` for cancellation.
- **User actions:** `startTranscription() async` (consume the `transcribe` stream,
  map `.progress` → `phase`, `.completed` → load words), `cancelTapped()`
  (cancel the task → back to import or close tab), `retryTapped()`,
  plus the Step-1 word/selection/sensitivity actions.
- Progress and transcript live in one tab model, but subprocess mechanics stay in
  `EngineClient` — the model only consumes the event stream.

The existing `TranscriptPageModel`/`View` become the **loaded-state renderer** the
`SongTabView` shows once `phase == .loaded`. (Implementation plan decides whether
`SongTabModel` composes a child `TranscriptPageModel` or absorbs its properties;
either keeps views logic-free.)

### Views (dumb)

`RootView` renders the tab strip + selected tab or the empty `ImportPageView`.
`SongTabView` switches on `model.phase` to show a progress view (spinner + phase
message + Cancel) or the transcript renderer. Every string binds to a model; zero
logic in views (no phase conditionals deciding copy — the model exposes
`progressMessage`, `showsCancel`, etc.).

## EditPlan model fixes (before more code hardens around it)

Codex-flagged latent issues:

1. **`Silence` is samples, typed as seconds.** The engine emits silences in
   **samples** but `Silence.start/end` are `Double` and read like seconds. Retype
   to `Int` samples (e.g. `startSample`/`endSample`) so the coordinate system is
   honest. Decoded-but-unused today; fix now to avoid Phase-4 drift.
2. **Two meanings of "segment."** Whisper transcript segments ≠ cut/export
   segments. Keep the `EditPlan.segments` field meaning *cut* segments; a fresh
   `plan` emits `segments: []`. Do not overload it with whisper segments.
3. **Canonical sample rate.** `plan` declares one canonical rate (default 44100,
   overridable) so a plan's samples and any later export agree. Document it on the
   contract.

Decoding an **empty** `segments` array must work (it already should, as `[Segment]`).
Add a fixture/test for the empty-segments plan shape.

## Testing plan (Swift Testing, colocated)

Mock the engine with `withDependencies { $0.engine.transcribe = { _,_ in stream } }`;
no subprocess, no audio, no `Task.sleep`. Value comparisons via
`expectNoDifference`/`expectDifference`.

- **RootModel:** dropping a file opens a new tab and starts it; a second drop opens
  a second tab; closing a tab cancels its job and removes it; empty state shows when
  no tabs; `loadSampleTapped` opens a tab with the fixture.
- **SongTabModel:** consuming a stream of `.progress` then `.completed` walks
  `phase` `transcribing → loaded` and populates words (count matches fixture);
  a throwing stream → `phase == .failed` with the right message + alert;
  `cancelTapped` cancels the task and leaves the expected state; retry re-runs.
  Selection/red-word/sensitivity behavior carried from Step-1 tests.
- **EngineClient:** `testValue.transcribe`/`loadPlan` without override fails cleanly
  (reportIssue/unimplemented), does **not** trap; `previewValue` yields the fixture.
- **EditPlan:** empty-`segments` plan decodes; `Silence` decodes as `Int` samples.
- Use a bundled `edit-plan.json` fixture (Step-1's, plus an empty-segments variant).

## Build / tooling facts (do not rediscover)

- Build/test: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor
  -destination 'platform=macOS' -allowProvisioningUpdates`.
- Test target must **not** directly link `swift-dependencies` (transitive via app
  target, else `withDependencies` overrides break).
- Signing team `FSRSPV9N9Q`.
- Engine env is `.venv` (Homebrew python3.12; uses `afconvert`, not ffmpeg).
- Regenerate the fixture with `scripts/regen-fixture.sh`.
- Run engine tests with `python3 -m pytest -q`.

## Risks / open questions

- **Cancellation is the sharpest risk.** Ship-only-`Process.terminate()` leaks
  `afconvert`/model-download children. Process-group kill is required, and
  `Foundation.Process` needs help to set a new group — the implementation plan must
  budget for a small spawn helper and test the kill path (best-effort, since real
  subprocess kills are hard to unit-test; cover the Swift-side task/stream logic and
  verify the kill manually).
- **Concurrency:** two tabs transcribing at once = two heavy WhisperX processes.
  Allowed (just slower) per decision; no queue in Step 2. Note the CPU cost.
- **Contract drift / sample agreement** across `plan` and future export — mitigated
  by the canonical-rate rule and sample-typed silences above.
- **Dev engine path** is hard-coded for Step 2; clearly marked as dev-only so it's
  not mistaken for the shippable helper (Phase 1).
- **First-run model download** can take minutes with no percentage — copy must set
  expectations ("first run downloads models") so a slow first import doesn't read as
  a hang.

## Out of scope / deferred

Waveform, slices/export, transport/zoom/fine-tune, undo/redo, markers, packaging/
notarization, native inference, `@Shared` promotion, work-dir cleanup policy,
transcription queueing. The `EditPlan` contract, sample-native coordinates, and
per-tab models leave room for all of them.
