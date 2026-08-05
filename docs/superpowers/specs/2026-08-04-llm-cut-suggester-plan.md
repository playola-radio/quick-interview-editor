# LLM Cut-Suggester: Design & Implementation Plan

**Date:** 2026-08-04
**Branch:** `briankeane/paragraph-transcription-research`
**Status:** Draft — pending user review. Architecture driven through Codex consult
session `019fcf6d-6f2c-7923-a323-8e19041d6174` (resume for follow-ups).
**Companion to:** `2026-08-04-paragraph-transcription-design.md` (paragraph &
speaker-aware transcription). This plan layers on top of that spec; it does not
replace it.

## What the spike settled

Goal: from a raw interview transcript, **suggest product-shaped cut-points** for
the two Playola radio deliverables, for a human editor to accept/edit:

- **Intro** (~15–45s): sets up ONE named song, ends on the handoff.
- **Artist Spotlight** (~40–120s): one self-contained story/anecdote.

Evidence (see `.context/paragraph-poc/`, gitignored scratch):

1. **Local sentence-embedding segmentation is not good enough.** quint /
   Model2Vec / all-MiniLM + z-score drift gave ~0.43 boundary F1 on real,
   thematically-coherent interviews and over-segments on back-channel. Killed.
2. **A hosted frontier LLM is the segmenter.** Privacy is a non-concern
   (confirmed), cost is negligible (~2s, pennies per interview).
3. **Best measured structure: two-stage, paragraph-first.** Stage 1 = windowed
   exhaustive topic-paragraph partition (guarantees coverage; one-shot decayed on
   long input — 5/11 recall, windowing fixed it). Stage 2 = per-paragraph
   classify → Spotlight / Intro(+song) / neither, trim to clean edges, minimal
   merge, enforce duration windows. Tuned two-stage: 8/11 recall vs 11 shipped
   Joe Miller spotlights, 14 clean clips, 0 fragments.
4. **Output is ranked candidate cuts for a human, not auto-cut.** "Extra" clips
   beyond what shipped are mostly legit; recall matters more than precision-vs-
   shipped.

**Codex's key correction:** "paragraph-first" is a *cutter implementation tactic*,
not an app-architecture principle. The app architecture stays: **evidence → Swift
state → user edits → render.** And 8/11 on one artist is enough to kill local
embeddings, NOT enough to lock prompts — validate on the 12-artist paired dataset,
measuring spotlights and intros **separately**, before productizing.

## Architecture

### Data flow (one line)

`audio → EngineClient/Python → edit-plan.json raw evidence + canonical AIFF →
Swift transcript/speaker models → user taps "Suggest cuts" → CutSuggestClient
sends transcript evidence + product spec (+ optional diarization) to hosted LLM →
Swift persists a ranked CutSuggestion sidecar → user accepts/edits → Slice →
EngineClient.renderSlices → AIFF exports`

**The LLM never touches `edit-plan.json`.** That file stays raw, regenerable
engine evidence.

### Where the LLM lives: a new Swift `CutSuggestClient`

Not in `logic_markers/`, not inside `EngineClient`. Reasons:
- It's a **network side effect** → the repo rule is every side effect is a
  `swift-dependencies` client with `liveValue`/`testValue`.
- `logic_markers/` is the boring, deterministic, offline engine (analyze → emit
  evidence → render). Editorial product judgment is not engine evidence.
- Prompt versions, model choice, API keys, cache invalidation, retry/cancel UX,
  and user-visible errors are app concerns.
- Keeps `EngineClient` from becoming "everything that does work."

View models stay logic-only: `CutSuggestClient` owns network/prompt mechanics;
pure Swift model code owns validation, span→word-ID mapping, duration enforcement,
dedupe/merge, ranking, acceptance, and slice conversion (all fixture-testable, no
network).

### Reconciliation with the paragraph/speaker spec — compose, don't replace

The heuristic paragraph builders (`PauseParagraphBuilder`, `SpeakerTurnBuilder`)
**stay** for the transcript UI and offline use. LLM suggestions are a **separate,
explicit action layered on top** — the transcript page must never become network-
dependent, and must degrade to a usable transcript when the LLM/network is absent.

Do **not** overload `TranscriptParagraph` (display grouping) with LLM output
(editorial scaffolding). Distinct types:

- `TranscriptUnit` — sentence/segment/word-span, the LLM input.
- `TopicPartition` — LLM stage-1 scaffold (internal to the cutter).
- `CutSuggestion` — a product candidate (persisted, user-facing).
- `TranscriptParagraph` — offline transcript rendering only (existing spec).

### Data model: Swift-owned suggestion sidecar

`CutSuggestion` is Swift-owned project/UI state, persisted **separately** from
`edit-plan.json` (same posture as the speaker-count override / names). Shape:

```
id, productType (.intro | .artistSpotlight), title, song?,
wordIDs / wordRange, startSample, endSample (derived from words, NOT from the
LLM's duration guess), rank, score (display-only), status (.pending/.accepted/.rejected),
model, promptVersion, productSpecVersion, transcriptHash, diarizationHash, sourceFingerprint
```

Persist via `@Shared(.fileStorage(...))` or a project sidecar. **An accepted
suggestion becomes an existing `Slice`** (`startSample`/`endSample`/`wordIDs` —
confirmed present in `Models/Slice.swift`), which flows through
`RenderRequest.slices` → `EngineClient.renderSlices`. Note: `edit-plan.json.segments`
is **not** the live slice model; `RenderRequest.slices` is the render source of
truth. Never mutate the analysis plan to represent an accepted cut.

### CutSuggestClient contract

```swift
struct CutSuggestClient: Sendable {
  var suggestCuts: @Sendable (CutSuggestRequest) -> AsyncThrowingStream<CutSuggestEvent, Error>
}
struct CutSuggestRequest: Equatable, Sendable {
  var transcriptUnits: [TranscriptUnit]   // stable IDs, text, wordIDs, samples, speakerID?
  var diarization: DiarizationEvidence?
  var productSpecs: [ProductSpec]
  var options: CutSuggestOptions          // model, promptVersion, windowing params
}
enum CutSuggestEvent: Equatable, Sendable { case progress(String); case completed(CutSuggestResult) }
```

Request uses stable IDs, not raw offsets. `testValue` returns fixtures — no
network, no subprocess, no sleeps.

## Two-stage cutter mechanics + failure modes to handle

- **Windowing** with **overlap + stitching** (not just non-overlapping windows) —
  seams can split a story.
- Stage 2 must be free to **trim, split, and merge** across stage-1 boundaries.
- **Intros need word-level trim** (song-handoff endpoint), not just sentence-level.
- **Compute duration from samples**, never trust the LLM's duration estimate.
- **`temperature:0` is not deterministic** → cache raw responses + normalized
  results. Cache key must include transcript hash, diarization hash,
  productSpecVersion, promptVersion, model, window params.
- **Pin `model` / `promptVersion` / `productSpecVersion`** — model upgrades change
  behavior silently.
- **Validate song labels** against transcript text; mark unverified otherwise.
- **Overlap is sometimes valid** (an intro can live inside a broader story) — do
  not globally forbid overlapping candidates.
- Track **editor burden** (candidates/hour, accepted-rate) separately from recall.

## Speaker-awareness

The cutter consumes the spec's **diarization** evidence to prefer subject speech
and down-rank/exclude interviewer-only spans. Do **not** assume `SPEAKER_00` is the
subject — require a user "this is the artist/guest" mark or a heuristic default with
visible correction. Solo files work with no speaker evidence.

## Eval harness (build FIRST)

Location: `evals/cut_suggestions/`. In-repo: prompt templates, product specs, label
schema, transcript JSON fixtures, expected shipped-label metadata. Raw audio stays
out of the repo / in private storage (licensing). Normal CI must not depend on huge
audio or live transcription.

Metrics (spotlights and intros **separately**):
- `recall@K` vs shipped products, per product type
- span match by time IoU (candidate matches shipped if IoU ≥ threshold / boundary
  deltas within tolerance)
- intro **song correctness**
- duration-window compliance, fragment rate, duplicate/overlap burden,
  candidates per interview-hour
- accepted-rate (later, once humans use it)

Run modes: cached deterministic eval for CI; live-LLM eval (needs API key) for
prompt/model changes; a baseline report checked in, updates gated by review.

## PR sequence (separate track; deps on the paragraph/speaker spec noted)

1. **Eval harness first.** Repeatable cut-suggestion eval over transcript fixtures
   + shipped labels. No app UI; no live prompt change without a report.
2. **Suggestion domain + sidecar store.** `CutSuggestion`, `ProductType`,
   `ProductSpec`, sidecar persistence, fixture decoding. No network, no UI risk.
3. **Accept suggestion → Slice.** Pure conversion from suggestion span to `Slice`
   (warnings/snippet/wordIDs derived like existing slice code). Shippable with
   fixture suggestions.
4. **CutSuggestClient interface + mocked integration.** Dependency client, test
   fixtures, progress/error states in the model. Live impl feature-flagged/stubbed.
5. **Live LLM two-stage impl.** Windowed partition, classify/trim/merge, strict
   JSON validation, caching, refresh. *Depends on paragraph-spec PR 1 (schema v2 /
   `transcript_segments`).*
6. **Speaker-aware suggestions.** Consume diarization turns / per-word speaker +
   subject-speaker selection. *Depends on paragraph-spec PR 2 (diarization) / PR 3
   (speaker UI).*
7. **Suggestion UI polish.** Ranked candidates, accept/reject, preview, refresh,
   stale-cache indicator, product filters.

**Cross-spec dependencies:** paragraph-spec PR 1 (schema v2 evidence) should land
before serious LLM work (PR 5). Diarization (PR 2) is required before claiming
speaker-aware quality (PR 6). Speaker rename/override UI (PR 3) is needed before
multi-speaker UX is honest, not for first suggestions.

## Resolved decisions (user, 2026-08-04)

1. **Eval-first: YES.** PR 1 is the eval harness; no UI is built on an unproven
   prompt.
2. **Product priority:** user was lukewarm on leading with intros. So the eval
   harness is **product-type-agnostic** and is **seeded with the already-validated
   spotlight data** (Joe Miller, and expand to more artists' spotlights). Intros
   are a **fast-follow dataset**, not the lead. **Open risk (tracked):** intros are
   still unvalidated end-to-end; add a Cody song-intros dataset before shipping the
   intro path (PR 5/6), not necessarily in PR 1.
3. **Model default: `claude-sonnet-5`** (Claude Sonnet 5) — easy task, latest
   Claude tier is plenty; provider + model id stay a config knob (`CutSuggestOptions`)
   so gpt-4o-class or Opus can be swapped without code change. Confirm on the eval
   in PR 5.
4. **Persistence:** unify ALL Swift-owned per-file project state — speaker-count
   override, speaker display names (paragraph spec), and `CutSuggestion`s — into
   **one project sidecar keyed by source fingerprint**, surviving engine re-runs,
   never written into `edit-plan.json`. Concrete shape settled in cutter PR 2 /
   paragraph-spec PR 3 (shared decision).

## Out of scope (deferred)

- Auto-cut without human review.
- Cross-file / cross-episode product templates.
- Fine-tuning a model (revisit only if prompt+few-shot plateaus on the eval).
- Writing suggestions back into `edit-plan.json`.
