"""Eval runner: cached (no-network) and injected-fake end-to-end."""

import json

import pytest

from cut_suggester.cache import CacheMiss
from cut_suggester.llm import LLMResponse
from evals.cut_suggestions.aligner import rule_align
from evals.cut_suggestions.runner import run_eval


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


def test_cached_mode_with_empty_cache_raises_no_network(tmp_path):
    _write_dataset(tmp_path)
    empty_cache = tmp_path / "cache"
    empty_cache.mkdir()
    with pytest.raises(CacheMiss):
        run_eval(str(tmp_path), mode="cached", cache_dir=str(empty_cache), aligner=rule_align)
