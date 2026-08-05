"""Cached-mode eval over the committed Joe Miller fixture.

This is the CI-determinism guarantee: the eval runs against committed LLM
responses with no network and reproduces the checked-in baseline numbers. If the
committed cache is ever incomplete, this raises CacheMiss instead of silently
reaching for the network.
"""

import json
import os

from evals.cut_suggestions.aligner import rule_align
from evals.cut_suggestions.runner import DEFAULT_CACHE_DIR, DEFAULT_DATASET, run_eval

_BASELINE = os.path.join(os.path.dirname(DEFAULT_CACHE_DIR), "baseline.json")


def test_cached_joe_miller_reproduces_baseline():
    # Everything (cutter + semantic aligner) is served from the committed cache,
    # so this reproduces the baseline deterministically with no network.
    report = run_eval(DEFAULT_DATASET, mode="cached", model="gpt-4o")
    spot = report.per_product["spotlight"]

    assert spot["fragment_rate"] == 0.0  # acceptance: no fragments
    assert spot["recall"]["matched"] == 8  # ~8/11 shipped spotlights recalled
    assert spot["n_candidates"] >= 12


def test_rule_aligner_is_offline_fallback():
    # The deterministic token-overlap aligner needs no cached align response.
    report = run_eval(DEFAULT_DATASET, mode="cached", model="gpt-4o", aligner=rule_align)
    assert report.per_product["spotlight"]["recall"]["matched"] >= 4


def test_committed_baseline_matches_a_cached_run():
    with open(_BASELINE) as f:
        baseline = json.load(f)
    report = run_eval(DEFAULT_DATASET, mode="cached", model="gpt-4o")
    assert report.per_product["spotlight"]["n_candidates"] == (
        baseline["per_product"]["spotlight"]["n_candidates"]
    )
    assert report.meta["n_raw_clips"] == baseline["meta"]["n_raw_clips"]
