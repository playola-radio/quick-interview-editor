# Paragraph & Speaker-Aware Transcription: Design

**Date:** 2026-08-04
**Branch:** `briankeane/paragraph-transcription-research`
**Status:** Draft — pending user review (driven through Codex consult session `019f720e-13af-76f0-a11f-d0bcfe070ee4`)
**Roadmap:** new capability; slots after Phase 5 (interactive cut editing).

## Goal

Replace the flat wall of tappable word chips on the Transcript page with a
**paragraph-structured** transcript, and — for multi-voice recordings — a
**speaker-labeled** one. Two content shapes, one UI:

1. **Solo interview responses** — only the interviewee is recorded; the
   interviewer is never in the audio. The unheard questions leave **long
   silences** that are the natural answer/paragraph boundaries.
2. **Multi-speaker shows** — 1, 2, or 3 speakers (3 is not rare). Speakers are
   distinguished, color-coded, and renameable ("Speaker 1" → "Host" / a guest's
   name), with names shown in the transcript and in export.

Success criteria:

- The transcript renders as paragraphs, not one continuous run.
- Speaker count is **auto-detected per file** with a bias toward `1`; a per-file
  **speaker-count override** re-groups the transcript **instantly, with no Python
  re-run**.
- All grouping logic is pure Swift model code, fully unit-tested against
  `edit-plan.json` fixtures — **no pyannote, no audio, no subprocess in tests**.

## Core architecture decision

**The engine emits raw evidence once; Swift derives all grouping.** (Codex
Approach 1, chosen over "engine emits final paragraphs" and "Python re-segments
on override".)

This preserves the app's existing clean boundary: `logic_markers/editplan.py`
produces the `edit-plan.json` contract, and the Swift model layer is a pure,
fixture-testable function over the decoded `EditPlan`. Re-calling Python when the
user flips the speaker-count control would be slow, fragile, and backwards — the
override needs no audio, so it stays entirely in Swift.

**Consequence — two state homes, kept strictly separate:**

- **Engine evidence** (`edit-plan.json`, immutable, regenerable): word timings,
  per-word confidence + speaker label, sentence segments, raw diarization turns,
  speaker stats, and the engine's auto speaker-count guess.
- **Project / UI state** (Swift-owned, persisted separately, survives engine
  re-runs): the per-file speaker-count **override**, speaker **display-name**
  overrides, selection/expansion state, and (future) cross-file identity.

Names and overrides must **never** be written back into `edit-plan.json`.

## Schema changes — `edit-plan.json` v2

Bump `SCHEMA_VERSION` 1 → 2. Additions (all raw evidence; nothing pre-grouped):

- **Per-word** (`words[]`): add `confidence` (float, optional) and `speaker`
  (string label, e.g. `"SPEAKER_00"`, optional). The per-word `speaker` is a
  convenience denormalization of the diarization join — **not** the sole source.
- **`transcript_segments[]`** (new top-level): the WhisperX sentence grouping we
  currently compute and throw away (`Transcript.segments` in `words.py`). Shape:
  `{ id, word_ids: [int], text }`. **Do not** name it `segments` — that key
  already means output slices.
- **`diarization`** (new top-level block):
  ```json
  {
    "min_speakers": 1,
    "max_speakers": 4,
    "auto_speaker_count": 1,
    "confidence": "low|medium|high",
    "decision_reasons": ["SPEAKER_01 rejected: 1.2s total, 1 turn, 3 words"],
    "turns": [
      { "id": 1, "speaker": "SPEAKER_00",
        "start": 1.20, "end": 6.80,
        "start_sample": 52920, "end_sample": 299880 }
    ],
    "speaker_stats": [
      { "speaker": "SPEAKER_00", "total_ms": 123000,
        "turn_count": 14, "word_count": 220, "credible": true }
    ]
  }
  ```
  `turns[]` is **mandatory** — without the raw turns, Swift cannot honestly
  re-group after an override. Turn times carry **samples** (the app models
  samples; don't force Swift to re-round seconds).

Backward compatibility: the Swift `EditPlan` decoder makes all new fields
optional so a v1 fixture still decodes; a plan with no `diarization` block is
treated as effective-count 1 (pause paragraphs).

## Engine changes (`logic_markers/`)

- **Diarization pass (inline).** Call pyannote via WhisperX's diarization
  pipeline in the same engine pass as transcription+alignment. Run with
  `min_speakers=1, max_speakers=4` (headroom above the real max of 3). Chosen
  inline (not a lazy second pass) because the user imports a pile and glances
  once — first render must already be correct. Trade-off accepted: solo files
  pay the diarization cost too (consistent with the confirmed "diarize every
  file" requirement and the established accuracy-over-cost preference).
- **Word→speaker join.** Assign each word the speaker of **maximum time-overlap**
  with the diarization turns. Boundary policy (deterministic, so it's testable):
  a word straddling a turn boundary takes the max-overlap speaker; a word with
  missing/zero duration uses the engine's existing filled-time fallback before
  joining; overlapping speech stores only the primary (max-overlap) speaker on
  the word while the raw `turns[]` retain the full picture. Implement the join
  explicitly (or wrap WhisperX's helper) so boundary cases have unit tests.
- **Stop discarding data.** `whisperx_backend.py` currently reads only
  `word/start/end`. Also capture per-word `score` (→ `confidence`) and preserve
  the sentence segments into `transcript_segments`.
- **Speaker-count auto-detect** (see next section) runs in Python over the
  diarization output and writes `auto_speaker_count` + `decision_reasons`.

### Speaker-count algorithm (boring, deterministic, fixture-testable)

Run pyannote (`min=1, max=4`), then in pure Python:

1. **Normalize turns:** drop turns `< 700 ms`; merge adjacent same-speaker turns
   separated by `< 500 ms`; ignore speaker labels with zero assigned words.
2. **Per-speaker stats:** total diarized ms, % of all diarized speech, turn
   count, assigned word count, longest turn.
3. **Credibility gate** (sorted by talk time):
   - Primary speaker: always credible if it has any words.
   - 2nd speaker credible iff `total ≥ 10s AND % ≥ 8 AND turns ≥ 2 AND words ≥ 8 AND longest_turn ≥ 2s`.
   - 3rd speaker credible iff `total ≥ 8s AND % ≥ 5 AND turns ≥ 2 AND words ≥ 6`.
   - 4th+ computed but not surfaced as a default UI count (we support up to 3).
4. `auto_speaker_count` = `min(3, credible_speaker_count)` — the UI supports up
   to 3, so a credible 4th speaker's stats are retained but the surfaced count is
   clamped to 3 (emit a `decision_reason` noting the clamp). **Bias toward 1 when
   uncertain.** Rationale: the worst failure is a false `2` on a solo file, which
   destroys the paragraph model; a missed 2nd speaker is one override click to
   recover. Emit `decision_reasons[]` so tests assert on the *why*, not just the
   number.

Thresholds are starting values, centralized as named constants for tuning.

## Swift model layer

### One paragraph abstraction, two builders

Do not fork the transcript renderer. Selection, word chips, run-together
coloring, playback sync, and export selection stay unified. Only the paragraph
*header* differs (solo needs no speaker label).

```swift
struct TranscriptParagraph: Identifiable, Equatable {
  var id: String
  var kind: Kind            // .pauseParagraph | .speakerTurn
  var speakerID: String?    // nil for solo
  var title: String?        // resolved display name for speaker turns
  var wordIDs: [Word.ID]
  enum Kind { case pauseParagraph, speakerTurn }
}
```

- **`PauseParagraphBuilder`** (effective count 1): boundaries from `silences`
  (long-gap threshold) snapped to sentence ends via `transcript_segments` /
  trailing punctuation, never cutting mid-sentence. Reuses the inter-word gap
  math already in `RunTogether.swift`.
- **`SpeakerTurnBuilder`** (effective count 2–3): one paragraph per diarization
  turn, titled with the resolved speaker name. The wire `turns[]` are **raw**
  (so an override can honestly re-group); the builder first applies the same
  normalization the analysis used — drop turns `< 700 ms`, merge adjacent
  same-speaker turns `< 500 ms` — to those raw turns before grouping, so the
  rendered paragraphs never expose dropped or unmerged turns.

`TranscriptPageModel` exposes `[TranscriptParagraph]` and the view renders it.

### Effective speaker count drives everything (no "mode" primitive)

There is no engine "solo vs show" classification. **Effective count** =
`override ?? auto_speaker_count`. Count `1` → `PauseParagraphBuilder`; count
`2…3` → `SpeakerTurnBuilder`. Flipping the override just re-runs the builder over
already-decoded evidence — instant, no Python.

### Project/UI state

A Swift-owned, per-file store (persisted, `@Shared`-backed) holding
`speakerCountOverride: Int?` and `speakerDisplayNames: [SpeakerID: String]`.
Display names resolve `SPEAKER_00` → "Host" at render and are injected into the
export/render request; they never touch `edit-plan.json`.

## Rendering & interaction (View)

- Transcript renders a vertical stack of paragraphs; each paragraph is a
  `FlowLayout` of the existing word chips (all current per-word coloring
  preserved). Speaker turns show a header with the speaker name + color.
- **Speaker-count control** (1 / 2 / 3) per file; changing it re-derives
  paragraphs synchronously.
- **Rename**: editing a speaker's name updates the project store and re-titles
  every turn for that speaker.
- All strings/derived values live on the model (per the app's zero-logic-in-views
  rule).

## Export

The render request carries resolved speaker display names so exported artifacts
reflect "Host"/guest names rather than `SPEAKER_00`. (Exact export surface for
names to be detailed in the export PR.)

## Packaging / perf

Handle the pyannote model **the same way the Whisper/wav2vec2 models are handled
today** (per the packaging spike): pre-download + bundle, load offline via the
`config.apply_offline_env()` / `model_cache_only` path, with the checked-in model
manifest + `ModelDownloadClient` first-run fetch. **One wrinkle** the Whisper
models don't have: pyannote's weights are **gated** (HuggingFace token + accepted
terms). The spec's plan is to resolve the gate at build/bundle time so the
shipped app needs no user token — the token is a build-time concern, not runtime
onboarding. Risks to retire in the packaging PR:

- Confirm redistribution terms allow bundling the pyannote weights; if not, fall
  back to a first-run token/download step.
- PyInstaller already lists `pyannote` in `collect_all`, but that does not prove
  the gated weights + native deps collect and run frozen.
- **Failure mode:** "diarization unavailable" must degrade to a usable
  effective-count-1 transcript — it must never corrupt JSON or erase the
  transcript.

## Testing strategy

- New `edit-plan.json` fixtures at schema v2: a solo file (no credible 2nd
  speaker) and a 2- and 3-speaker file, each with `diarization.turns`,
  `speaker_stats`, `decision_reasons`.
- Swift model tests (Swift Testing + `expectNoDifference`): both builders,
  effective-count derivation, override re-grouping, name resolution, boundary
  cases (word straddling a turn, sub-700ms turn dropped).
- Python tests (pytest): the speaker-count algorithm over synthetic diarization
  inputs (no pyannote, no audio); the word→speaker overlap join boundary cases;
  v2 plan builder shape.

## Suggested PR sequence (each its own fresh context)

1. **Schema v2 + engine evidence (no diarization yet):** emit `confidence` +
   `transcript_segments`; Swift decodes them; **pause-paragraph** builder ships
   for solo files. Immediately useful, zero new native deps.
2. **Diarization in the engine:** pyannote pass, word→speaker join, speaker-count
   algorithm, `diarization` block; Python tests. No UI yet.
3. **Speaker turns + override + rename UI:** `SpeakerTurnBuilder`, project store,
   speaker-count control, rename, colors; Swift tests.
4. **Packaging:** bundle/gate the pyannote model, offline load, failure-mode
   degradation, notarized end-to-end.
5. **Export names.**

## Explicitly out of scope (YAGNI / deferred)

- **Cross-file persistent speaker identity** (recognizing the same host across
  episodes) — deliberately deferred; the schema/store leave room for it.
- Engine-produced paragraph objects, complex confidence scoring, 4+ speaker UI,
  overlapping-speech multi-speaker word attribution.

## Open questions

- Exact long-silence threshold for pause paragraphs (tune against real solo
  files; start from the existing run-together gap logic).
- Whether the speaker-count override and names persist in app support storage vs.
  a project sidecar — settle in PR 3.
- Confirmation of pyannote redistribution terms (PR 4) — determines whether the
  HF token stays purely build-time.
