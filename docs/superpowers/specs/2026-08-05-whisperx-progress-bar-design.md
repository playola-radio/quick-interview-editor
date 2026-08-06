# WhisperX transcription progress bar + expectation-setting

**Date:** 2026-08-05
**Status:** Approved (design) — ready for implementation plan

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
   live, self-calibrating **"About X min remaining"** estimate derived from
   measured progress.

Non-goals: benchmarking the machine to quote a fixed "N minutes per minute of
audio" figure (rejected — hardware/model-dependent and made redundant by the
live ETA); progress for the render/export path (already determinate); diarization
progress.

## Feasibility (verified)

WhisperX 3.8.6 (installed) exposes `progress_callback: Optional[Callable[[float],
None]]` in **both** `transcribe()` (`asr.py`) and `align()` (`alignment.py`),
plus a `combined_progress: bool` flag. With `combined_progress=True`:

- `transcribe` reports **0 → 50%** (one callback per VAD segment as it is
  decoded).
- `align` reports **50 → 100%** (one callback per segment as it is aligned).

So we get a genuine, unified 0–100% signal with **no print-scraping and no
monkeypatching** — we just pass a callback.

The one unavoidable indeterminate window: before the first callback, WhisperX
loads the model (first run only; normally cached) and runs VAD across the whole
file to build the segment list. That prep emits no per-chunk progress. It is
short relative to transcription. We show an indeterminate "Preparing audio…"
state until the first fraction arrives, then flip to the determinate bar.

## Architecture

Reuses the existing streaming-progress plumbing end to end — the **render/export
path already does exactly this** with `index`/`total`, and the model-download
screen already renders `ProgressView(value:)`. This feature threads a numeric
`fraction` through the same channel for the transcribe phase.

```
whisperx.transcribe / align  --progress_callback(0..100)-->
  cli.py run_plan callback  --QIE_EVENT {..,"fraction":0..1} on stderr-->
    LiveEngine stderr reader  --.progress(EngineProgress w/ fraction)-->
      SongTabModel.progressFraction / etaMessage / progressNote
        --> SongTabView: ProgressView(value:) + note + ETA
```

### Python (`logic_markers`)

**Thread an optional progress callback down the plan pipeline.** The callback is
owned by `run_plan` in `cli.py` (it already owns `_emit_event` / `_progress`) and
passed keyword-only with a `None` default through each layer, so existing callers
(`transcribe_words`, tests, non-`plan` uses) are unaffected:

```
run_plan (cli.py)
  → _load_or_transcribe_transcript_in(..., on_progress=cb)
    → transcribe_transcript(..., progress_callback=cb)
      → _aligned_segments(..., progress_callback=cb)
        → model.transcribe(audio, batch_size=16,
                           combined_progress=True, progress_callback=cb)
        → whisperx.align(..., combined_progress=True, progress_callback=cb)
```

**The callback emits a throttled progress event.** WhisperX hands it a float in
0–100. The callback:

- Converts to a fraction (0.0–1.0).
- **Throttles**: emits only when the whole-number percent changes, so stderr is
  not spammed (long files have many segments).
- Chooses the label from the fraction: `"Transcribing audio…"` below 50%,
  `"Aligning words…"` at/above 50%.
- Emits `QIE_EVENT {"type":"progress","phase":"transcribing",
  "message":<label>,"fraction":<0..1>}`.

Before the first callback, `run_plan` still emits the existing single
`_progress("transcribing", "Preparing audio…")` (message reworded) with **no
fraction** — this drives the indeterminate "Preparing audio…" state.

`combined_progress=True` is passed so the single 0–100 scale is produced by
WhisperX (transcribe 0–50, align 50–100). We accept WhisperX's split; align is
much faster than transcribe, so the bar advances steadily to ~50% then completes
the back half quickly. That is honest (it is measured, not estimated) and
acceptable.

### Swift — wire + model

**`EngineProgress`** (`Core/EngineEvent.swift`): add `var fraction: Double?`
(nil for phase-only events). **`LiveEngine.WireEvent`**: decode the `fraction`
field (currently dropped). Mirrors `RenderWireEvent`'s handling of `index`/`total`.

**`SongTabModel`** gains, following the app's model conventions (all display text
and derived values on the model, zero logic in the view):

- `var progressFraction: Double?` — nil until the first real fraction; set from
  each `.progress` event's `fraction`.
- Elapsed-time tracking via a **`Clock` dependency** (`@Dependency(\.continuousClock)`),
  started when transcription begins. A cancellable tick loop updates an
  `elapsed`-derived display roughly once per second so the ETA/label stay live
  even between progress events. Testable with `TestClock`/`ImmediateClock`; no
  `Task.sleep` in tests.
- View-helper computed properties:
  - `var progressNote: String` — the upfront reassurance line, e.g.
    `"This can take several minutes — longer files take longer."` Shown while
    transcribing.
  - `var etaMessage: String?` — nil until `progressFraction` passes a small
    threshold (e.g. `>= 0.03`) to avoid wild early estimates; then
    `remaining = elapsed * (1 - fraction) / fraction`, formatted to a friendly
    unit (`"Less than a minute remaining"`, `"About 2 min remaining"`).
  - `var isProgressDeterminate: Bool` — `progressFraction != nil`.

`progressFraction`, `etaMessage`, and `progressNote` reset when a new run starts
and clear on completion/failure.

### Swift — view

`SongTabView` transcribing branch:

- If `model.isProgressDeterminate`: `ProgressView(value: model.progressFraction ?? 0)`
  (same pattern as `ModelSetupView`); else the existing indeterminate
  `ProgressView()` for the prep gap.
- Below the bar: `Text(model.progressMessage)` (existing), `Text(model.progressNote)`,
  and, when non-nil, `Text(model.etaMessage)`.
- Cancel button unchanged.

No new strings or conditionals are hardcoded in the view — every label and the
determinate/indeterminate decision come from the model.

## Testing

**Python (`tests/`, pytest):**

- Callback threads through: running `run_plan` (with a stubbed/fake whisperx
  backend that invokes the callback with a sequence of 0–100 values) emits
  `QIE_EVENT` progress lines whose `fraction` matches, in order.
- Throttling: repeated callbacks at the same whole percent emit at most one
  event per percent.
- Label switch: fraction `< 0.5` → "Transcribing audio…"; `>= 0.5` →
  "Aligning words…".
- Backward compatibility: `transcribe_words` / callers passing no callback still
  work (no callback invoked, no crash).

**Swift (`SongTabTests.swift`, Swift Testing + custom-dump):**

- Stub `EngineClient.transcribe` to yield a scripted `AsyncThrowingStream` of
  `.progress` events carrying fractions, then `.completed`.
- `progressFraction` is nil before the first fractioned event, then advances with
  each event (`expectNoDifference`).
- `isProgressDeterminate` is false during "Preparing audio…" (fraction nil), true
  after.
- `etaMessage` is nil below the threshold; after the threshold, with a `TestClock`
  advanced a known amount, it equals the expected formatted string
  (`expectNoDifference`).
- `progressNote` present while transcribing, cleared on `.loaded`/`.failed`.
- Reset behavior: starting a second run clears prior `progressFraction`/`etaMessage`.

## Point-Free skills to apply during implementation

`pfw-observable-models` (model changes), `pfw-dependencies` (the `Clock`
dependency), `pfw-testing` + `pfw-custom-dump` (tests, `expectNoDifference`,
`TestClock`), `pfw-modern-swiftui` (view bindings).

## Files touched (anticipated)

- `logic_markers/cli.py` — callback in `run_plan`, thread through
  `_load_or_transcribe_transcript_in`; reword the pre-transcribe message.
- `logic_markers/whisperx_backend.py` — `progress_callback` params on
  `transcribe_transcript` and `_aligned_segments`; pass to `model.transcribe` /
  `whisperx.align` with `combined_progress=True`.
- `QuickInterviewEditor/…/Core/EngineEvent.swift` — `fraction` on `EngineProgress`.
- `QuickInterviewEditor/…/Core/LiveEngine.swift` — decode `fraction` in `WireEvent`.
- `QuickInterviewEditor/…/Views/Pages/SongTab/SongTabModel.swift` — progress
  fraction, clock/elapsed, ETA + note helpers.
- `QuickInterviewEditor/…/Views/Pages/SongTab/SongTabView.swift` — determinate
  bar + note + ETA.
- Python tests + `SongTabTests.swift`.
