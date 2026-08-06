"""Cached-mode eval over the committed transcript fixtures.

This is the CI-determinism guarantee: the eval runs against committed LLM
responses with no network and reproduces the checked-in baseline numbers. If the
committed cache is ever incomplete, this raises CacheMiss instead of silently
reaching for the network.

`baseline.json` is an aggregate keyed by dataset (`{"datasets": {name: report}}`)
covering all three committed datasets: joe_miller (spotlights), willy_spotlights
(a 2nd spotlight artist), and joe_intros (the intro product).
"""

import json
import os

from evals.cut_suggestions.aligner import rule_align
from evals.cut_suggestions.runner import DEFAULT_CACHE_DIR, DEFAULT_DATASET, run_eval

_EVAL_DIR = os.path.dirname(DEFAULT_CACHE_DIR)
_BASELINE = os.path.join(_EVAL_DIR, "baseline.json")
_DATASETS = {
    "joe_miller": os.path.join(_EVAL_DIR, "datasets", "joe_miller"),
    "willy_spotlights": os.path.join(_EVAL_DIR, "datasets", "willy_spotlights"),
    "joe_intros": os.path.join(_EVAL_DIR, "datasets", "joe_intros"),
}


def test_cached_joe_miller_reproduces_baseline():
    # Everything (cutter + semantic aligner) is served from the committed cache,
    # so this reproduces the baseline deterministically with no network.
    report = run_eval(DEFAULT_DATASET, mode="cached", model="gpt-4o")
    spot = report.per_product["spotlight"]

    assert spot["fragment_rate"] == 0.0  # acceptance: no fragments
    assert spot["recall"]["matched"] == 8  # ~8/11 shipped spotlights recalled
    assert spot["n_candidates"] >= 12


def test_cached_joe_intros_scores_song_recall():
    # Intros are scored by named song (not the free-text topic label): the cutter
    # proposes ~12/20 shipped songs, every named song verified in the clip text.
    report = run_eval(_DATASETS["joe_intros"], mode="cached", model="gpt-4o")
    intro = report.per_product["intro"]
    assert intro["recall"]["matched"] == 12  # 12/20 shipped songs
    assert intro["fragment_rate"] == 0.0


def test_rule_aligner_is_offline_fallback():
    # The deterministic token-overlap aligner needs no cached align response.
    report = run_eval(DEFAULT_DATASET, mode="cached", model="gpt-4o", aligner=rule_align)
    assert report.per_product["spotlight"]["recall"]["matched"] >= 4


def test_committed_baseline_matches_cached_runs_for_all_datasets():
    with open(_BASELINE) as f:
        baseline = json.load(f)
    for name, dataset_dir in _DATASETS.items():
        entry = baseline["datasets"][name]
        report = run_eval(dataset_dir, mode="cached", model="gpt-4o")
        for ptype in ("spotlight", "intro"):
            assert report.per_product[ptype]["n_candidates"] == (
                entry["per_product"][ptype]["n_candidates"]
            ), f"{name}/{ptype} n_candidates drifted"
        assert report.meta["n_raw_clips"] == entry["meta"]["n_raw_clips"], name
