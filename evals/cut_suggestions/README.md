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
