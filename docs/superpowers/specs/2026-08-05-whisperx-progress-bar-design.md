# WhisperX transcription progress bar + expectation-setting

**Date:** 2026-08-05
**Status:** Approved (design), revised after Codex consult — ready for implementation plan

## Problem

When transcribing a large interview, the "Transcribing with WhisperX" state
shows an **indeterminate spinner** and nothing else for minutes at a time. The
spinner is animated by SwiftUI itself, so it keeps moving even if the subprocess
has wedged or died — it proves nothing. Users cannot tell a slow-but-working run
from a hung one, and have no sense of how long to expect. (In the motivating
incident the run was fine; it was just slow and silent.)

## Goal

Replace the meaningless spinner with a **real, subprocess-driven progress bar**
plus **expectation-setting**, so a long wait reads as normal progress rather than
a hang.

Two user-visible outcomes:

1. A progress bar that advances **only when the Python engine reports real work
   from inside WhisperX's own loops**. If the subprocess freezes, the bar
   freezes — the signal that is missing today.
2. Expectation-setting: an upfront "this can take a while" note, giving way to a
   live **"About X min remaining"** estimate during transcription.

Non-goals: benchmarking the machine to quote a fixed "N minutes per minute of
audio" figure (rejected — hardware/model-dependent and made redundant by the
live ETA); progress for the render/export path (already determinate).

## Global constraints

- **`whisperx>=3.8.6`** — the `progress_callback` parameter this feature relies
  on was added in 3.8.6. Pin this floor in the engine's requirements so the
  callback contract cannot silently disappear. The 0–50 / 50–100
  transcribe/align split of `combined_progress` is WhisperX-internal; we do not
  depend on the exact 50 boundary for correctness (only for the cosmetic
  label swap — see below).
- Model everything the model needs as display strings/derived values; the view
  holds zero logic (project MV convention).
- No `Task.sleep` in tests; use `TestClock`/`ImmediateClock`.

## Feasibility (verified)

WhisperX 3.8.6 (installed at `.venv/…/whisperx`) exposes
`progress_callback: Optional[Callable[[float], None]]` in **both** `transcribe()`
(`asr.py:208`) and `align()` (`alignment.py:127`), plus `combined_progress: bool`.
With `combined_progress=True`:

- `transcribe` reports **0 → 50** (one callback per VAD segment as decoded).
- `align` reports **50 → 100** (one callback per segment as aligned).

So we get a genuine unified 0–100 signal with **no print-scraping and no
monkeypatching** — we pass a callback. The callback receives a float in 0–100.

## Two honest caveats baked into the design

**(a) The pre-callback window is real work, not just model load.** Before the
first callback, the Python step does, in order: `_load_audio_16k_mono` (shells
out to `afconvert` — non-trivial on a large file), `whisperx.load_model` (first
run downloads; normally cached), and VAD segmentation across the whole file to
build the segment list. None of this emits per-chunk progress. We show an
indeterminate **"Preparing audio…"** state for this window, then flip to the
determinate bar when the first fraction arrives.

**(b) WhisperX reaching 100% is not the end of the job.** `run_plan` continues
after transcription with `converting` → `analyzing_silence` → `writing_plan`
(each a single existing phase-level event, and all fast relative to
transcription). So the bar must represent **the transcription phase only**: it
fills 0→100 during transcribe+align, then when the next phase event arrives the
UI drops back to an indeterminate state showing that phase's label
("Converting audio", "Finding silence", "Preparing transcript"). The user never
sees a full bar followed by an unexplained wait — the label changes and the bar
goes indeterminate for the short tail.

## Architecture

Reuses the existing streaming-progress plumbing. The render/export path already
does exactly this with `index`/`total`; the model-download screen already
renders `ProgressView(value:)`. This feature threads a numeric `fraction`
through the same stderr `QIE_EVENT` channel for the transcribe phase.

```
whisperx.transcribe / align  --progress_callback(0..100)-->
  cli.py callback  --QIE_EVENT {phase:"transcribing", message, fraction:0..1}-->
    LiveEngine stderr reader  --.progress(EngineProgress{fraction})-->
      SongTabModel (fraction derived from phase; elapsed via Clock)
        --> SongTabView: ProgressView(value:) + note + ETA
```

### Python (`logic_markers`)

**Thread an optional progress callback down the `plan` pipeline only.** Passed
keyword-only with a `None` default through each layer so every other caller
(`transcribe_words`, the `transcript` command, tests) is unaffected and emits
nothing:

```
run_plan (cli.py)                       # owns _emit_event; builds the callback
  → _load_or_transcribe_transcript_in(..., on_progress=cb)
    → transcribe_transcript(..., progress_callback=cb)
      → _aligned_segments(..., progress_callback=cb)
        → model.transcribe(audio, batch_size=16,
                           combined_progress=True, progress_callback=cb)
        → whisperx.align(..., combined_progress=True, progress_callback=cb)
```

Only the `plan` command constructs a real callback; be explicit in the code that
this is intentional and other entry points get progress-free behavior.

**The callback emits validated, throttled events with guaranteed endpoints.**
WhisperX hands it a float 0–100. The callback:

- Converts to a fraction and **clamps to `0.0…1.0`**; if the value is `NaN`/inf,
  it is dropped (never emitted). WhisperX is monotonic, but the Swift side
  clamps and never moves the bar backward regardless.
- **Always emits the first callback** (so a short file that starts mid-range
  still shows a bar) and, after `align()` returns successfully, **emits an
  explicit `fraction: 1.0`** so the bar is guaranteed to reach full before the
  next phase. Between those, it **throttles**: emits only when the whole-number
  percent changes, so stderr is not spammed.
- Chooses the label from the fraction: `"Transcribing audio…"` below 0.5,
  `"Aligning words…"` at/above 0.5. (Cosmetic only; correctness does not depend
  on the exact boundary.)
- Emits `QIE_EVENT {"type":"progress","phase":"transcribing",
  "message":<label>,"fraction":<0.0…1.0>}`.

Before the first callback, `run_plan` emits the existing single
`_progress("transcribing", "Preparing audio…")` (message reworded) with **no
`fraction`** — this drives the indeterminate "Preparing audio…" state.

`combined_progress=True` yields the single 0–100 scale (transcribe 0–50, align
50–100). We accept WhisperX's split; align is much faster than transcribe, so the
bar advances steadily through the first half then completes the back half
quickly. That is measured, not estimated.

### Swift — wire + model

**`EngineProgress`** (`Core/EngineEvent.swift`): add `var fraction: Double?`
(nil for phase-only events). It stays `Equatable, Sendable`; the decoder rejects
`NaN`/out-of-range so a `NaN` is never stored (avoids `NaN != NaN` surprises and
a `ProgressView(value: .nan)` footgun). **`LiveEngine.WireEvent`**: decode
`fraction`, and on decode clamp to `0…1` / drop `NaN` (invalid fraction drops
only the fraction, not the whole event). Mirrors `RenderWireEvent`'s
`index`/`total` handling.

**`SongTabModel`** — single source of truth is `phase`; progress is *derived*,
not stored in parallel (avoids desync):

- `var progressFraction: Double?` — **computed** from the current
  `phase`'s `EngineProgress.fraction` (nil unless the phase is `.transcribing`
  with a fraction). Never moves backward: expose the max-seen within a run if a
  stray lower value arrives.
- `var isProgressDeterminate: Bool { progressFraction != nil }`.
- `var determinateValue: Double` — non-optional 0…1 for the view to bind when
  `isProgressDeterminate` (so the view has no `?? 0` fallback logic).
- **Elapsed time** via a `Clock` dependency (`@Dependency(\.continuousClock)`).
  A **single, separately-owned cancellable tick task** starts once when a run
  begins and is cancelled on completion, failure, cancel, retry/overtake, and
  deinit. It updates an `elapsed`-derived display ~once/second so the ETA/label
  stay live between progress events. It must **not** alter existing cancellation
  behavior: `cancel()` still just cancels the transcription task and leaves final
  progress on screen (tab teardown), and `onReadyForNext?()` semantics are
  unchanged.
- View-helper computed properties:
  - `var progressNote: String` — upfront reassurance, e.g. `"This can take
    several minutes — longer files take longer."` Shown while transcribing.
  - `var etaMessage: String?` — see ETA rules below.
- Progress-derived state resets when a new run starts (via the phase reset) and
  the tick task is torn down on `.loaded`/`.failed` without racing `EditorModel`
  creation on the main actor.

**ETA rules (kept honest across the transcribe/align split).** A naive
`elapsed × (1−f)/f` on the combined 0–100 badly overestimates just past 0.5
(all of transcribe is in `elapsed`, but only the fast align remains). So:

- **While transcribing (`fraction < 0.5`):** progress-within-transcribe is
  `fraction / 0.5`; ETA = `elapsed × (1 − p) / p` where `p` is that value, shown
  as a friendly unit — `"Less than a minute remaining"`, `"About 2 min
  remaining"`. Only shown once `p` passes a small threshold (~`0.05`) to avoid
  wild early numbers.
- **While aligning (`fraction ≥ 0.5`):** do **not** show a numeric ETA (it would
  collapse); show `"Aligning words — almost done"`. Elapsed keeps ticking.
- ETA/elapsed clear on `.loaded`/`.failed`.

### Swift — view

`SongTabView` transcribing branch:

- If `model.isProgressDeterminate`: `ProgressView(value: model.determinateValue)`
  (same pattern as `ModelSetupView`); else the existing indeterminate
  `ProgressView()` for the prep window and the tail phases.
- Below the bar, stacked in the existing centered VStack (constrained to a
  sensible max width so the note wraps cleanly): `Text(model.progressMessage)`
  (existing), `Text(model.progressNote)`, and when non-nil `Text(model.etaMessage)`.
- Cancel button unchanged.

No new strings or branch decisions live in the view — every label and the
determinate/indeterminate choice come from the model.

## Testing

**Python (`tests/`, pytest):** test the callback/emission in isolation — do
**not** drive full `run_plan` (it then converts audio, reads AIFF, detects
silence, builds a plan).

- Inject a fake `whisperx` backend (monkeypatch at the module path
  `transcribe_transcript`/`_aligned_segments` actually import) whose
  `transcribe`/`align` invoke the passed `progress_callback` with a scripted
  sequence of 0–100 values. Capture stderr and assert the emitted `QIE_EVENT`
  lines' `fraction` values match, in order.
- First-and-final: a scripted sequence that starts above 0 still emits a first
  event; after align, exactly one `fraction: 1.0` event is emitted.
- Throttle: repeated callbacks at the same whole percent emit at most one event.
- Clamp/NaN: a callback value `>100`, `<0`, or `NaN` never produces an
  out-of-range or `NaN` `fraction` (dropped or clamped).
- Label switch: `< 0.5` → "Transcribing audio…"; `≥ 0.5` → "Aligning words…".
- Backward-compat: callers passing no callback invoke nothing and don't crash.
- **One integration/manual check** (not a stubbed unit test) that runs the real
  CLI `plan` on a short real audio file with the installed WhisperX 3.8.6 and
  confirms real `QIE_EVENT … "fraction"` lines appear in order and end at 1.0.
  This is the only check that catches wrong kwarg placement, callback scale, or
  timing — stubs cannot.

**Swift (`SongTabTests.swift`, Swift Testing + custom-dump):**

- Stub `EngineClient.transcribe` to yield a scripted `AsyncThrowingStream` of
  `.progress` events (fractions), then `.completed`.
- `progressFraction`/`isProgressDeterminate`: nil/false during "Preparing audio…"
  (no fraction) and during a tail-phase event (`converting` etc.); set/true for
  `.transcribing` events with a fraction (`expectNoDifference`).
- Monotonic: a stray lower fraction does not move the bar backward.
- `determinateValue` equals the clamped fraction when determinate.
- `etaMessage`: nil below the threshold; with a `TestClock` advanced a known
  amount at a known `fraction < 0.5`, equals the expected formatted string; is
  the non-numeric "almost done" string when `fraction ≥ 0.5`.
- `progressNote` present while transcribing, cleared on `.loaded`/`.failed`.
- Tick-task lifecycle: starting a second run resets state; `.loaded`/`.failed`
  tears the tick task down; existing `cancel()` / `onReadyForNext` behavior
  unchanged.

## Edge cases acknowledged

- **Cached transcript / `--refresh`:** `run_plan` uses a fresh work dir per job,
  so the in-work transcript cache misses on every normal app run and WhisperX
  always runs. If a cached transcript is ever returned (no callbacks fire), the
  UI simply stays indeterminate ("Preparing…") and then flips through the fast
  tail phases — correct, just no bar. No special-casing needed now.
- **stderr sharing:** `run_plan` redirects fd1→fd2 for analysis, so progress
  JSON shares stderr with library logs. The existing `QIE_EVENT ` prefix filter
  handles this; keep the one-line-JSON-per-event invariant intact.

## Point-Free skills to apply during implementation

`pfw-observable-models`, `pfw-dependencies` (the `Clock`), `pfw-testing` +
`pfw-custom-dump` (`expectNoDifference`, `TestClock`), `pfw-modern-swiftui`.

## Files touched (anticipated)

- `logic_markers/cli.py` — build callback in `run_plan`; thread `on_progress`
  through `_load_or_transcribe_transcript_in`; reword pre-transcribe message;
  clamp/throttle/first+final emission.
- `logic_markers/whisperx_backend.py` — `progress_callback` params on
  `transcribe_transcript` and `_aligned_segments`; pass to `model.transcribe` /
  `whisperx.align` with `combined_progress=True`; explicit 1.0 after align.
- engine requirements — pin `whisperx>=3.8.6`.
- `QuickInterviewEditor/…/Core/EngineEvent.swift` — `fraction` on `EngineProgress`.
- `QuickInterviewEditor/…/Core/LiveEngine.swift` — decode + clamp `fraction`.
- `QuickInterviewEditor/…/Views/Pages/SongTab/SongTabModel.swift` — derived
  fraction, clock/elapsed tick task, ETA + note helpers.
- `QuickInterviewEditor/…/Views/Pages/SongTab/SongTabView.swift` — determinate
  bar + note + ETA.
- Python tests + integration check + `SongTabTests.swift`.
