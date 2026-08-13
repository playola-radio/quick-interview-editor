# Per-phase progress reporting — "Phase X of N · <label> · NN%"

**Status:** Approved (brainstormed + Codex-consult validated 2026-08-13)
**Supersedes the UI model of:** `2026-08-05-whisperx-progress-bar-design.md`
(single folded 0–100% bar).

## Problem

The `plan` command is CPU-only and slow (an 84-min interview can run 30–75 min).
Today the app shows a **single 0–100% bar** for the whole transcription: WhisperX's
two stages are folded into one sweep (transcribe → 0.0–0.5, align → 0.5–1.0) and the
three tail steps (convert, silence, build) are message-only. A long run feels stalled
and gives no sense of "which stage am I in / how many are left."

## Goal

Replace the single combined bar with an explicit **multi-phase** model that reads
**"Phase 2 of 3 · Aligning words · 42%"**, where each phase advances its own 0–100%
and the user can see how many phases remain. The **engine owns the pipeline shape**;
the app just renders what it's told.

## Decisions (settled with the user + Codex)

1. **Fixed N = 3 for `plan`**, engine-*declared* on every event (not app-hardcoded):
   1. **Transcribing** (WhisperX transcribe) — real per-phase 0–100%
   2. **Aligning words** (wav2vec2 forced alignment) — real per-phase 0–100%
   3. **Finalizing** (convert AIFF + detect silence + build plan) — **indeterminate**
      (no fraction), but emits **changing sub-messages** ("Converting audio…" →
      "Finding silence…" → "Preparing transcript…") so it's a live, labeled phase,
      **not a dead spinner**. (Resolves Codex's "opaque tail" objection without
      inventing fake fractions or expanding N.)
2. **Self-describing events, no manifest.** `phase_index`/`phase_count`/`label` ride
   on every `progress` event. A manifest only earns its keep for localization or
   pre-work validation — YAGNI here, and repeating the fields is robust for a
   line-stream the app may start reading mid-stream.
3. **Single stage-tagged backend callback** `progress_callback(stage, fraction)`
   (`stage ∈ {"transcribe","align"}`), not two callbacks — easier to test with
   ordered assertions, doesn't bake exactly-two-WhisperX-stages into the Python API.
4. **App is phase-string-agnostic for display.** Determinacy is `fraction != nil`,
   never "the phase string equals `transcribing`" (that coupling is today's bug
   class). The raw phase string is kept only for logs.
5. **Per-phase ETA**, not whole-job (align is slower per-unit than transcribe, so a
   combined number would systematically lie). Worded "in this phase", hidden until a
   minimum elapsed + minimum fraction so it doesn't jump around.

## Event contract (stderr `QIE_EVENT` lines; stdout stays pure plan JSON)

```
QIE_EVENT {"type":"progress","phase":"aligning","phase_index":2,"phase_count":3,
           "label":"Aligning words","message":"Aligning words…","fraction":0.42}
```

New optional fields, added alongside the existing `phase`/`message`/`fraction`:

| field         | type        | meaning                                             |
|---------------|-------------|-----------------------------------------------------|
| `phase_index` | int ≥ 1     | 1-based position of this phase in the run           |
| `phase_count` | int ≥ 1     | total phases for this run (3 for `plan`)            |
| `label`       | string      | human phase name ("Transcribing", "Aligning words") |
| `fraction`    | number/null | 0–1 per-phase progress; **absent or `null` ⇒ indeterminate** |

**Invariant:** phase indices are strictly increasing within one job. **Not every
phase must emit** (a cached transcript skips phases 1–2 and jumps to phase 3). A
skipped phase **never** manufactures a `finish()`/100%.

## Engine changes (Python)

### `whisperx_backend.py`
- `_aligned_segments` / `transcribe_transcript` take **one** optional
  `progress_callback(stage: str, fraction: float)`. It stops folding the two stages
  into a single 0.0–1.0 sweep: transcribe reports its own raw 0–1 as
  `("transcribe", f)`, align reports its own raw 0–1 as `("align", f)`.
- Existing callers (`transcribe_words`, `_load_or_transcribe_transcript`) pass no
  callback → unaffected.

### `cli.py`
- Generalize `_ProgressEmitter` → **`_PhaseEmitter(index, count, phase, label,
  emit=…)`**: same whole-percent throttle, same first-callback-always, same
  clamp/drop of junk, same monotonic-within-a-phase guarantee. It now emits the new
  fields. `finish()` still no-ops if the phase never emitted (so a skipped/cached
  phase never fakes 100%) and otherwise emits a final 1.0 for **its** phase.
- `_progress(...)` gains index/count/label so the message-only phase-3 events carry
  the phase metadata too.
- `run_plan` wires:
  - phase 1 emitter (`transcribing`, "Transcribing") ← `stage == "transcribe"`
  - phase 2 emitter (`aligning`, "Aligning words") ← `stage == "align"`
  - phase 3 (`finalizing`, "Finalizing") = the existing convert/silence/build
    `_progress` calls, re-labeled with index 3 / count 3 and their changing messages.
  A tiny router maps the backend's `(stage, fraction)` to the matching emitter.
- **stdout purity untouched:** `_cmd_plan`'s fd-level `os.dup2(2, 1)` redirect stays
  exactly where it is; all events remain stderr-only.
- Naming: labels are phase names, not "real %" claims (WhisperX's callback may be
  chunk-count, not wall-time).

## App changes (Swift)

### `EngineEvent.swift` — `EngineProgress`
Carry the raw string + new optional metadata; keep it lenient:
```swift
struct EngineProgress: Equatable, Sendable {
  var phase: String          // raw, for logs — no longer an enum gate
  var phaseIndex: Int?
  var phaseCount: Int?
  var label: String?
  var message: String
  var fraction: Double?      // absent OR null ⇒ indeterminate
}
```

### `LiveEngine.swift` — decode
- **Never drop** a progress event on an unknown/renamed phase string (today's decoder
  filters via `EngineProgress.Phase(rawValue:)` → silently drops; that goes away).
- Decode the new fields; `fraction: null` decodes the same as absent.
- Keep `sanitizedFraction` for the fraction.

### `SongTabModel.swift` — derive + render
- `phaseLabel`: `label ?? (message.isEmpty ? nil : message) ?? phase-nonEmpty ?? "Working"`.
- `phaseOfNText`: `"Phase \(index) of \(count)"` **only** when `1 ≤ index ≤ count`
  and `count ≥ 1`; otherwise `nil` (old events / malformed metadata → no prefix,
  single-phase render).
- `isProgressDeterminate = fraction != nil` (drop the `phase == .transcribing` gate).
- **Monotonic clamp**, hardened per Codex:
  - Track the max `phaseIndex` seen. **Ignore** any event whose `phaseIndex` is lower
    (stale/regression guard).
  - **Reset** `maxFraction` when phase identity moves **forward** (index increases).
  - Clamp `maxFraction` upward within a phase (never moves backward).
- **Per-phase ETA** replaces the 0.5-split `etaText`:
  - Track elapsed-within-current-phase; reset it on phase change.
  - Show `"About N min left in this phase"` / `"Less than a minute left in this phase"`
    only when in-phase elapsed ≥ ~30s **and** fraction ≥ ~0.05.
  - No ETA for an indeterminate phase.

### `SongTabView.swift`
- Render the phase line from model computed properties: `phaseOfNText` (when present)
  · `phaseLabel` · percent (when determinate). Zero logic in the view.

## Backward / forward compatibility

- **Old-format events** (only `phase`/`message`/`fraction`, no index/count/label):
  decode fine, render as a single phase (no "Phase X of N" prefix), determinate iff
  `fraction` present.
- **Malformed metadata** (`index > count`, `count ≤ 0`, index without count): still
  render message + fraction; just suppress the "Phase X of N" prefix.
- **Unknown/renamed phase strings**: render normally (display is label/fraction-driven).
- **Mid-run `phase_count` change**: treated as display metadata; does not reset
  progress unless the phase **identity** changed.

## Testing

**Python (`tests/`, pytest):**
- `_PhaseEmitter`: first-callback-always, whole-percent throttle **within a phase**,
  monotonic within phase, emits index/count/label, `finish()` emits 100% only when the
  phase emitted, skipped phase → no fake 100%.
- Stage router: `("transcribe", f)` → phase-1 event, `("align", f)` → phase-2 event,
  correct index/count/label on each.
- `whisperx_backend`: stage-tagged callback receives each stage's own unscaled 0–1
  (replaces the "folded halves" regression test).
- `run_plan`: phase-3 finalize events carry index 3 / count 3 with changing messages.
- stdout purity: `plan` stdout parses as exactly one JSON object, no `QIE_EVENT`
  leakage (extend `test_plan_stdout.py`).

**Swift (Swift Testing, colocated; fixtures only, no subprocess/audio):**
- `EngineEventTests`: decode new fields; unknown phase renders (not dropped);
  `fraction: null` == indeterminate; malformed metadata still renders.
- `SongTabTests`: `phaseOfNText`, `phaseLabel` fallback chain, determinacy by
  fraction-present, per-phase clamp reset on forward phase change, **ignore** a
  lower-`phaseIndex` event, ETA thresholds/wording, old-event single-phase compat.
- Value comparisons via `expectNoDifference`.

## Out of scope
- The `render`/`cut` path (already emits `index/total` per slice).
- Streaming partial transcript text; model/accuracy settings.
- A localized/manifest phase protocol.

## Process
Brainstorm → Codex consult (done) → TDD, incremental commits, `make lint` + build +
both suites green → Codex review + challenge on the diff → final report.
