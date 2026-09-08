# `evals/cut_suggestions` — cut-suggestion eval harness

Repeatable eval of the reference two-stage cutter (`cut_suggester/`) over
transcript fixtures + shipped-product labels. Product-type-agnostic (spotlights
**and** intros), seeded with the validated **spotlight** dataset (Joe Miller).

## Layout

```
evals/cut_suggestions/
├── datasets/
│   ├── joe_miller/          # SPOTLIGHT (11 shipped topics)
│   ├── willy_spotlights/    # SPOTLIGHT, 2nd artist (14 topics; Willy 1.m4a is reel 1/6)
│   └── joe_intros/          # INTRO, first test (20 shipped song labels)
│       ├── transcript.json  # committed WhisperX transcript (raw audio is NOT committed)
│       └── labels.json      # shipped labels; spotlights: [...] and/or intros: [...]
├── cache/                   # committed raw LLM responses -> deterministic cached mode
├── metrics.py               # recall@K, duration compliance, fragment rate, overlap, cands/hr
├── aligner.py               # semantic label match: LLMAligner (cached) + rule_align fallback
├── runner.py                # cached / live run modes + CLI (intros scored by song)
├── baseline.json            # checked-in baseline (aggregate: {"datasets": {name: report}})
└── BASELINE.md              # checked-in baseline (human-readable) — updating it is reviewed
```

## Run modes

- **cached** (default): deterministic, no network — CI. A cache miss raises
  `CacheMiss` rather than reaching for the network.
- **live**: needs `$OPENAI_KEY`; writes responses through the cache.

```bash
./.venv/bin/python -m evals.cut_suggestions.runner --mode cached
./.venv/bin/python -m evals.cut_suggestions.runner --mode live --model gpt-4o
```

## Metrics (reported per product type)

`recall@K` vs shipped labels (semantic aligner), duration-window compliance,
fragment rate (<15s), duplicate/overlap burden, candidates per interview-hour.

## Follow-ups (not in this PR)

- **Intro trimming + type disambiguation.** The `joe_intros` baseline surfaces two
  intro failure modes (durations run long vs the 15–45s target; occasional
  intro→spotlight type leakage). See BASELINE.md; fix in PR 5.
- **Time-IoU metric.** Matching candidates to shipped clips by time overlap needs
  the shipped `.m4a` products transcribed and located back onto the raw
  transcript. Out of scope here; the next eval enhancement.

## Configured editorial evaluation

The separate `editorial_runner` executes the app's full V2 configured pipeline
against `datasets/suggestion_types`: tuned discovery, configured Intro boundary
refinement, imaging discovery, final candidate IDs, and naming-field extraction.
It preserves the legacy runner and its shared tuned prompts.

```bash
python3 -m evals.cut_suggestions.editorial_runner --mode cached
python3 -m evals.cut_suggestions.editorial_runner --mode live --model gpt-4o \
  --output-dir .context/editorial-live
```

`configured-v2` enables sentence-level Intro refinement and separate repeated
imaging takes. Captured `v2`, `configured-v1`, and older discovery versions retain
their previous path; direct legacy cutter/discovery calls keep their defaults.
The new pass preserves relevant setup before a handoff, splits independently
complete takes, and drops explicit unusable proposals. It is bounded by 20
proposals and 24,000 prompt characters. An oversized proposal fails without
paying for preceding refinement batches or truncating evidence. Responses are
validated and durably journaled before the next checkpoint. IDs and field
extraction follow final sentence bounds.

Raw genuine gpt-4o responses for the final synthetic pipeline are committed in
`editorial_cache/configured-v2/`. Cached mode constructs no live provider; a
missing response fails instead of using the network. By default it builds a
fresh temporary journal and replays the entire pipeline. `--output-dir` retains
the request, validated journal, result, and report for inspection or interrupted
run recovery. A directory belongs to one immutable request. Model, transcript,
configuration, and behavior versions determine a stable run identity.

Metrics use inclusive global sentence coordinates and the existing same-take
predicate (overlap covers at least half of the shorter span). Positive recall
uses deterministic maximum one-to-one matching, so a merged repeat earns at
most one match. The report also lists forbidden negative-span matches,
unmatched predictions, exact positive-span matches, and unexpected overlapping
predictions. Overlaps explicitly supported by matched labels, such as a full
promo plus its nested ID, are allowed. The CLI exits unsuccessfully unless every
positive has its exact span, no extra prediction exists, and both negative and
unexpected-overlap lists are empty.

Actual integrated validation on 2026-09-07 used gpt-4o and synthetic material
only. The first run matched 9/9 takes but failed the strict gate at 8/9 exact
spans: refinement shortened a valid 0–3 introduction to 2–3. Clarifying that a
complete introduction retains its relevant performer/background setup fixed
that boundary. The subsequent full pipeline returned 9/9 exact spans, zero
negative matches, and zero unexpected overlaps; fresh-journal cached replay
returned an identical result. The final pass reused the three unchanged genuine
discovery responses and obtained new refinement/extraction responses. The two
introductions retain 0–3 (8 seconds, River Vale / Paper Lanterns) and 24–25
(4 seconds, Nova Reed / Harbor Lights). Distinct IDs 4–5 and 6–7, full promo
8–22, nested ID 15–16, post-commercial 23, pre-commercial 28, and Spotlight
29–36 all remain intact. Post-commercial quality is **synthetic-only**; this is
not production Claude validation or evidence about unrelated recordings.

`tests/test_suggestion_editorial_eval.py` separates handcrafted metric tests from
replay of those actual responses. The existing cached regression also compares
Spotlight `(start_index, end_index, discovery label)` tuples against the pinned
baseline before any generated naming.

The independent scripted integration fixtures
`tests/fixtures/suggestion-integration-request-v2.json` and
`tests/fixtures/suggestion-integration-response-v2.json` are **transport fixtures,
not model-quality evidence**. They cover all six defaults plus `custom-story`,
ten final suggestions, two performer/title pairs, and one custom descriptive
field. `test_all_types_custom_fixture_failed_naming_reopen_and_final_transport`
reconstructs them through real discovery/refinement/extraction orchestration
with scripted provider responses and one-candidate extraction batches. A failed
middle naming batch is retried after reopening while every successful request
is reused. The checked-in result is compared in full, allowing Swift tests to
consume it without a Python runtime.
