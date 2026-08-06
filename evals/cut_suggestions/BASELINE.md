# Cut-suggestion eval — baseline

Machine-readable numbers live in `baseline.json`, an aggregate keyed by dataset
(`{"datasets": {name: report}}`) covering all three committed datasets. Updating
this baseline is a **reviewed action** (re-run live, inspect the diff, commit).

## Pinned run

| Pin | Value |
|-----|-------|
| model | `gpt-4o` (via `$OPENAI_KEY`) — the initial baseline; production default is `claude-sonnet-5` |
| prompt version | `v1` |
| product-spec version | `v1` |
| window params | window=130, step=110 (overlap 20) |

The production default model is `claude-sonnet-5`, but the first eval baseline is
run against whatever key is present. `gpt-4o` reproduces the spike; re-baseline on
`claude-sonnet-5` in PR 5.

## Datasets

| Dataset | Audio | Segments | Product under test |
|---------|-------|----------|--------------------|
| `joe_miller` | 42 min | 465 | SPOTLIGHT (validated) |
| `willy_spotlights` | 45 min (**reel 1 of 6**) | 539 | SPOTLIGHT (2nd artist) |
| `joe_intros` | 30 min | 265 | INTRO (first test) |

Raw audio is not committed (licensing) — only the WhisperX transcript JSON and
shipped-product labels.

## `joe_miller` — SPOTLIGHT (vs 11 shipped Joe Miller spotlights)

| Metric | Value |
|--------|-------|
| **recall@K** (semantic label match) | **8 / 11 = 0.73** |
| missed | `No Depression`, `No Day Job`, `Buck Owens` |
| **fragment rate** (<15s) | **0.00** |
| candidates | 26 |
| duration-window compliance (40–120s) | 0.46 |
| overlap burden (pairs) | 0 |
| candidates / interview-hour | 36.9 |

## `willy_spotlights` — SPOTLIGHT (2nd artist, vs 14 shipped Willy Braun spotlights)

| Metric | Value |
|--------|-------|
| **recall@K** (raw) | **7 / 14 = 0.50** |
| **recall@K** (coverage-adjusted) | **7 / 12 = 0.58** |
| missed | `On Our Own Terms`, `Friendship Dynamics`, `A Day in the Life`, `Record Concepts`, `New Music`, `Producing the Records`, `Thoughts on Streaming` |
| **fragment rate** (<15s) | **0.00** |
| candidates | 9 |
| duration-window compliance (40–120s) | 0.78 |
| overlap burden (pairs) | 0 |
| candidates / interview-hour | 12.0 |

**Coverage note.** `Willy 1.m4a` is only reel 1 of a 6-part interview, so not all
14 shipped topics are in this file. A keyword coverage grep finds **12 of 14
topics present**; the two genuinely **absent** are `Friendship Dynamics` and
`Thoughts on Streaming` — so the coverage-adjusted recall (present topics only) is
**7/12 = 0.58**. Recall is scored on the candidate *label* via the semantic
aligner, and label wording diverges from the shipped topic name, so the metric
under-reports content that is captured under a different label (e.g. shipped
`A Day in the Life` is present as candidate "Life in Idaho"). True content recall
is higher than 0.50.

## `joe_intros` — INTRO (first test, vs 20 shipped Joe Miller song intros)

| Metric | Value |
|--------|-------|
| **song-recall@K** (semantic song match) | **12 / 20 = 0.60** |
| **song-recall** (coverage-adjusted) | **12 / 19 = 0.63** |
| **song-name correctness** | **12 / 12 = 1.00** (every named song `song_verified` in the clip text; zero hallucinations) |
| missed | `Crazy Arms`, `Drown`, `Even When I'm Blue`, `God Is Here Tonight`, `Little Drops of My Heart`, `Rattle Trap`, `She's Crying`, `Stranger Things` |
| **fragment rate** (<15s) | **0.00** |
| intro candidates | 12 (+6 spotlight-typed, 2 dropped for duration) |
| duration-window compliance (15–45s) | **0.25** |
| overlap burden (pairs) | 0 |
| candidates / interview-hour | 24.0 |

Intros are scored by the **named song** (`c.song`, falling back to the label when
nil), because shipped intro labels *are* song names while the cutter's free-text
label is a topic description ("Rockabilly Revival"). Scoring on the label instead
would spuriously report ~2/20. The session is **discrete** — Joe records song
intros back-to-back with chatter/false-starts between them.

**Coverage note.** A keyword grep finds 19 of 20 songs present; `Rattle Trap` is
absent from the audio. Of the 8 misses, one (`Drown`) *is* captured but emitted
as a SPOTLIGHT-typed clip rather than an intro (see failure modes).

## Known intro failure modes (documented follow-ups for PR 5)

1. **Durations run long.** Intro clips average ~52s (range 29.7–74.2s) against a
   15–45s target, with only 3 of 12 already inside the window (duration-window
   compliance 0.25). The cutter emits the whole lead-up paragraph instead of
   trimming to the final song handoff. Needs a trim-to-handoff step for the intro
   product.
2. **Intro → spotlight type leakage.** When the subject tells a longer backstory
   before naming the song, the paragraph is sometimes classified as a spotlight
   (e.g. `Drown`), which drops intro recall and mislabels the product. Needs
   intro/spotlight type disambiguation in stage 2.

## Reproduce

```bash
# cached (deterministic, no network — this is what CI runs), per dataset:
./.venv/bin/python -m evals.cut_suggestions.runner --mode cached --model gpt-4o \
    --dataset evals/cut_suggestions/datasets/joe_intros

# live (needs $OPENAI_KEY; rewrites the cache). The aggregate baseline.json is
# assembled from a live run over all three datasets (a reviewed action).
./.venv/bin/python -m evals.cut_suggestions.runner --mode live --model gpt-4o \
    --dataset evals/cut_suggestions/datasets/willy_spotlights
```

## Notes / deviations from the spike

- **Joe Miller recall and fragments reproduce the spike** (8/11, 0 fragments).
  The `two_stage.py` spike scored 8/11 with 14 clips; this run emits **26**
  candidates (higher editor burden, `candidates/hour = 36.9`).
- The candidate count is **not** locked to the spike's 14. Per the plan, 8/11 on
  one artist is enough to kill local embeddings but **not** to lock prompts —
  prompt tuning to reduce editor burden is validated on the multi-artist paired
  dataset in PR 5, not overfit to one artist here. The eval reports
  `candidates/hour`, `duration-window compliance`, and `overlap burden` precisely
  so that tuning is measured rather than guessed.
- **Spotlight generalizes to a 2nd artist** (Willy Braun): clean, in-duration,
  0-fragment story clips; recall ≥0.58 on present topics and genuinely higher once
  label-vs-topic wording is accounted for.
- **The intro product path works** as a first test: correct product type, 100%
  song-name correctness, ~0.60 song-recall — with the two failure modes above as
  PR 5 follow-ups.
- `temperature:0` is not deterministic, so the committed `cache/` fixes the exact
  LLM responses; cached mode is bit-for-bit reproducible in CI.
