# `evals/cut_suggestions` — cut-suggestion eval harness

Repeatable eval of the reference two-stage cutter (`cut_suggester/`) over
transcript fixtures + shipped-product labels. Product-type-agnostic (spotlights
**and** intros), seeded with the validated **spotlight** dataset (Joe Miller).

## Layout

```
evals/cut_suggestions/
├── datasets/joe_miller/
│   ├── transcript.json      # committed WhisperX transcript (raw audio is NOT committed)
│   └── labels.json          # 11 shipped spotlight topics + intros: []
├── cache/                   # committed raw LLM responses -> deterministic cached mode
├── metrics.py               # recall@K, duration compliance, fragment rate, overlap, cands/hr
├── aligner.py               # semantic label match: LLMAligner (cached) + rule_align fallback
├── runner.py                # cached / live run modes + CLI
├── baseline.json            # checked-in baseline (machine-readable)
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

- **Intros dataset.** Seed a Cody song-intros dataset (514 shipped song labels)
  as a fast-follow. The harness is already product-type-agnostic:
  `labels.json` carries an `intros` list, `ProductType.INTRO` has a spec, and the
  runner reports intros separately — a new dataset dir with `intros: [...]` drops
  straight in. Intro **song correctness** becomes a metric once that lands.
- **Time-IoU metric.** Matching candidates to shipped clips by time overlap needs
  the shipped `.m4a` products transcribed and located back onto the raw
  transcript. Out of scope here; the next eval enhancement.
