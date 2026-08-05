# Cut-suggestion eval — baseline

Machine-readable numbers live in `baseline.json`. Updating this baseline is a
**reviewed action** (re-run live, inspect the diff, commit).

## Pinned run

| Pin | Value |
|-----|-------|
| dataset | `joe_miller` (42 min, 465 WhisperX segments, Joe Miller of Reckless Kelly) |
| model | `gpt-4o` (via `$OPENAI_KEY`) — the initial baseline; production default is `claude-sonnet-5` |
| prompt version | `v1` |
| product-spec version | `v1` |
| window params | window=130, step=110 (overlap 20) |

The production default model is `claude-sonnet-5`, but the first eval baseline is
run against whatever key is present. `gpt-4o` reproduces the spike; re-baseline on
`claude-sonnet-5` in PR 5.

## Spotlight results (vs 11 shipped Joe Miller spotlights)

| Metric | Value |
|--------|-------|
| **recall@K** (semantic label match) | **8 / 11 = 0.73** |
| missed | `No Depression`, `No Day Job`, `Buck Owens` |
| **fragment rate** (<15s) | **0.00** |
| candidates | 26 |
| duration-window compliance (40–120s) | 0.46 |
| overlap burden (pairs) | 0 |
| candidates / interview-hour | 36.9 |

Intros: 0 candidates (the Joe Miller interview ships no intros; the intros
dataset is a documented fast-follow — see the package README).

## Reproduce

```bash
# cached (deterministic, no network — this is what CI runs):
./.venv/bin/python -m evals.cut_suggestions.runner --mode cached --model gpt-4o

# live (needs $OPENAI_KEY; rewrites the cache and, with --write-baseline, this file's JSON):
./.venv/bin/python -m evals.cut_suggestions.runner --mode live --model gpt-4o \
    --write-baseline evals/cut_suggestions/baseline.json
```

## Notes / deviations from the spike

- **Recall and fragments reproduce the spike** (8/11, 0 fragments). The
  `two_stage.py` spike scored 8/11 with 14 clips; this run emits **26** candidates
  (higher editor burden, `candidates/hour = 36.9`).
- The candidate count is **not** locked to the spike's 14. Per the plan, 8/11 on
  one artist is enough to kill local embeddings but **not** to lock prompts —
  prompt tuning to reduce editor burden is validated on the multi-artist paired
  dataset in PR 5, not overfit to one artist here. The eval reports
  `candidates/hour`, `duration-window compliance`, and `overlap burden` precisely
  so that tuning is measured rather than guessed.
- `temperature:0` is not deterministic, so the committed `cache/` fixes the exact
  LLM responses; cached mode is bit-for-bit reproducible in CI.
