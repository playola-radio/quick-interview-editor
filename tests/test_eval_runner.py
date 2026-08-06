"""Eval runner: cached (no-network) and injected-fake end-to-end."""

import json

import pytest

from cut_suggester.cache import CacheMiss
from cut_suggester.llm import LLMResponse
from evals.cut_suggestions.aligner import LLMAligner, rule_align
from evals.cut_suggestions.runner import format_report, run_eval


def _write_dataset(tmp_path):
    words, segments = [], []
    wid = 1
    for i in range(6):  # 6 sentences, 20s each
        words += [
            {"id": wid, "text": f"w{wid}", "start": i * 20.0, "end": i * 20 + 10.0},
            {"id": wid + 1, "text": f"w{wid+1}", "start": i * 20 + 10.0, "end": (i + 1) * 20.0},
        ]
        segments.append({"id": i + 1, "word_ids": [wid, wid + 1], "text": f"sentence {i} story"})
        wid += 2
    (tmp_path / "transcript.json").write_text(json.dumps({"words": words, "segments": segments}))
    (tmp_path / "labels.json").write_text(json.dumps({
        "artist": "Test", "transcript": "transcript.json",
        "spotlights": ["sentence 0 story", "sentence 3 story"], "intros": [],
    }))


class _FakeLLM:
    def complete(self, prompt, *, purpose=""):
        if purpose.startswith("partition"):
            text = '{"paragraphs": [{"start":0,"end":2,"label":"a"},{"start":3,"end":5,"label":"b"}]}'
        else:  # classify
            text = ('{"clips": ['
                    '{"type":"spotlight","start":0,"end":2,"label":"sentence 0 story"},'
                    '{"type":"spotlight","start":3,"end":5,"label":"sentence 3 story"}]}')
        return LLMResponse(text=text)


def test_run_eval_reports_per_product_metrics(tmp_path):
    _write_dataset(tmp_path)
    report = run_eval(
        str(tmp_path), llm=_FakeLLM(), aligner=rule_align, sample_rate=1000, window=130, step=110,
    )
    spot = report.per_product["spotlight"]
    assert spot["n_candidates"] == 2
    assert spot["recall"]["recall"] == 1.0
    assert spot["fragment_rate"] == 0.0
    assert "intro" in report.per_product


def test_format_report_handles_missing_recall(tmp_path):
    # Intros produce recall: None in real runs; format_report must render the
    # None-recall product without raising, and still emit recall@K for spotlight.
    _write_dataset(tmp_path)
    report = run_eval(
        str(tmp_path), llm=_FakeLLM(), aligner=rule_align, sample_rate=1000, window=130, step=110,
    )
    assert report.per_product["intro"]["recall"] is None
    text = format_report(report)
    assert "[intro]" in text
    assert "recall@K" in text  # emitted for spotlight only


def test_cached_mode_with_empty_cache_raises_no_network(tmp_path):
    _write_dataset(tmp_path)
    empty_cache = tmp_path / "cache"
    empty_cache.mkdir()
    with pytest.raises(CacheMiss):
        run_eval(str(tmp_path), mode="cached", cache_dir=str(empty_cache), aligner=rule_align)


class _AlignLLM:
    def __init__(self, text):
        self.text = text

    def complete(self, prompt, *, purpose=""):
        return LLMResponse(text=self.text)


def test_llm_aligner_validates_one_to_one_and_derives_missed_extra():
    # The LLM reuses a proposed label, invents one not in the input, and reports
    # bogus missed/extra. The aligner must trust only a validated one-to-one map.
    proposed = ["Song A", "Song B"]
    shipped = ["Ship A", "Ship B", "Ship C"]
    raw = json.dumps({
        "matches": [
            {"shipped": "Ship A", "proposed": "Song A"},   # valid
            {"shipped": "Ship B", "proposed": "Song A"},   # reused -> rejected
            {"shipped": "Ship C", "proposed": "Ghost"},    # not in proposed -> rejected
        ],
        "missed": [],            # LLM's own fields are not trusted
        "extra": ["everything"],
    })
    res = LLMAligner(_AlignLLM(raw)).align(proposed, shipped)

    matched = [m for m in res["matches"] if m["proposed"]]
    assert matched == [{"shipped": "Ship A", "proposed": "Song A"}]
    assert res["missed"] == ["Ship B", "Ship C"]
    assert res["extra"] == ["Song B"]  # never validly claimed


def test_llm_aligner_falls_back_to_rules_on_malformed_json():
    # A damaged cached response or garbled provider output must degrade to the
    # deterministic token-overlap aligner, not raise and abort the eval.
    res = LLMAligner(_AlignLLM("not json {")).align(["No Depression story"], ["No Depression"])
    matched = [m for m in res["matches"] if m["proposed"]]
    assert len(matched) == 1  # token overlap on "depression" still matches
    assert res["missed"] == []
