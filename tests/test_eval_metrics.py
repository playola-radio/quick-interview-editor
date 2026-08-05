"""Eval metrics — pure, no network."""

from cut_suggester.models import CutCandidate, DEFAULT_SPECS, ProductType
from evals.cut_suggestions.aligner import rule_align
from evals.cut_suggestions.metrics import (
    candidates_per_hour,
    duration_window_compliance,
    fragment_rate,
    overlap_burden,
    semantic_recall,
)


def _cand(start_index, end_index, duration_sec, label="x", ptype=ProductType.SPOTLIGHT):
    return CutCandidate(
        product_type=ptype, start_index=start_index, end_index=end_index, label=label,
        song=None, song_verified=False, word_ids=[], start_sample=0, end_sample=0,
        start_sec=0.0, end_sec=0.0, duration_sec=duration_sec,
    )


def test_duration_window_compliance_counts_target_window():
    cands = [_cand(0, 1, 60), _cand(2, 3, 200), _cand(4, 5, 30)]  # 1 of 3 in 40-120
    assert duration_window_compliance(cands, DEFAULT_SPECS) == 1 / 3


def test_fragment_rate_counts_short_clips():
    cands = [_cand(0, 1, 10), _cand(2, 3, 60)]  # one < 15s
    assert fragment_rate(cands) == 0.5


def test_overlap_burden_counts_overlapping_pairs():
    cands = [_cand(0, 5, 60), _cand(4, 9, 60), _cand(20, 25, 60)]  # first two overlap
    assert overlap_burden(cands) == 1


def test_candidates_per_hour():
    cands = [_cand(0, 1, 60), _cand(2, 3, 60)]
    assert candidates_per_hour(cands, total_seconds=1800) == 4.0  # 2 in half an hour


def test_semantic_recall_with_a_fake_aligner():
    def fake_aligner(proposed, shipped):
        return {
            "matches": [{"shipped": "A", "proposed": "a-ish"}, {"shipped": "B", "proposed": None}],
            "missed": ["B"],
            "extra": ["c"],
        }

    res = semantic_recall(["a-ish", "c"], ["A", "B"], fake_aligner)
    assert res["recall"] == 0.5
    assert res["matched"] == 1
    assert res["missed"] == ["B"]


def test_rule_align_matches_on_token_overlap():
    res = rule_align(["Discovering No Depression magazine"], ["No Depression"])
    matched = [m for m in res["matches"] if m.get("proposed")]
    assert len(matched) == 1
    assert res["missed"] == []
