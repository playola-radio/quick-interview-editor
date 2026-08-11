"""Two-stage cutter orchestration, driven by a fake LLM (no network)."""

import pytest

from cut_suggester.cutter import (
    CutSuggesterOutputError,
    parse_clip_response,
    parse_partition_response,
    suggest_cuts,
)
from cut_suggester.llm import LLMResponse
from cut_suggester.models import ProductType, Sentence

SR = 1000


def _sents(n, sec_per=20.0):
    out = []
    wid = 1
    for i in range(n):
        start, end = i * sec_per, (i + 1) * sec_per
        out.append(
            Sentence(i, i + 1, f"sentence {i}", (wid, wid + 1), start, end,
                     round(start * SR), round(end * SR))
        )
        wid += 2
    return out


class _FakeLLM:
    def __init__(self, partitions_json, clips_json):
        self.partitions_json = partitions_json
        self.clips_json = clips_json
        self.purposes = []

    def complete(self, prompt, *, purpose=""):
        self.purposes.append(purpose)
        text = self.partitions_json if purpose.startswith("partition") else self.clips_json
        return LLMResponse(text=text)


# --- parsing ---------------------------------------------------------------
def test_parse_partition_response_clamps_to_window():
    text = '{"paragraphs": [{"start": -1, "end": 200, "label": "x"}]}'
    paras = parse_partition_response(text, a=0, b=5)
    assert (paras[0].start, paras[0].end) == (0, 4)  # clamped into [a, b)


def test_parse_clip_response_returns_raw_dicts():
    text = '{"clips": [{"type": "spotlight", "start": 0, "end": 2, "label": "A"}]}'
    clips = parse_clip_response(text)
    assert clips == [{"type": "spotlight", "start": 0, "end": 2, "label": "A"}]


def test_parse_partition_response_raises_on_malformed_json():
    # Truncated/garbled provider or cache output must fail loud; otherwise the app
    # reports a successful empty run and hides the real provider/cache problem.
    with pytest.raises(CutSuggesterOutputError, match="not valid JSON"):
        parse_partition_response("not json {", a=0, b=5)
    with pytest.raises(CutSuggesterOutputError, match="not valid JSON"):
        parse_partition_response('{"paragraphs": [ ', a=0, b=5)


def test_parse_clip_response_raises_on_malformed_json_or_empty_text():
    with pytest.raises(CutSuggesterOutputError, match="not valid JSON"):
        parse_clip_response("}{ broken")
    with pytest.raises(CutSuggesterOutputError, match="not valid JSON"):
        parse_clip_response('{"clips": [')
    with pytest.raises(CutSuggesterOutputError, match="classification response was empty"):
        parse_clip_response("")


# --- end-to-end ------------------------------------------------------------
def test_suggest_cuts_produces_ranked_candidates():
    sents = _sents(6, sec_per=20.0)  # 3-sentence clips = 60s (in the target window)
    partitions = '{"paragraphs": [{"start":0,"end":2,"label":"one"},{"start":3,"end":5,"label":"two"}]}'
    clips = (
        '{"clips": ['
        '{"type":"spotlight","start":0,"end":2,"label":"Story One"},'
        '{"type":"spotlight","start":3,"end":5,"label":"Story Two"}]}'
    )
    llm = _FakeLLM(partitions, clips)
    result = suggest_cuts(sents, llm, sample_rate=SR, window=130, step=110)

    assert len(result.candidates) == 2
    assert all(c.product_type is ProductType.SPOTLIGHT for c in result.candidates)
    assert {c.duration_sec for c in result.candidates} == {60.0}
    assert sorted(c.rank for c in result.candidates) == [1, 2]
    assert any(p.startswith("partition") for p in llm.purposes)
    assert "classify" in llm.purposes


def test_suggest_cuts_skips_invalid_clips_and_drops_fragments():
    sents = _sents(6, sec_per=10.0)  # 1 sentence = 10s < spotlight hard_min (15s)
    partitions = '{"paragraphs": [{"start":0,"end":5,"label":"all"}]}'
    clips = (
        '{"clips": ['
        '{"type":"bumper","start":0,"end":2,"label":"bad type"},'      # invalid -> skipped
        '{"type":"spotlight","start":0,"end":0,"label":"too short"},'   # 10s -> fragment, dropped
        '{"type":"spotlight","start":0,"end":3,"label":"good"}]}'       # 40s -> kept
    )
    result = suggest_cuts(sents, llm=_FakeLLM(partitions, clips), sample_rate=SR, window=130, step=110)
    labels = {c.label for c in result.candidates}
    dropped = {c.label for c in result.dropped}
    assert "bad type" not in labels          # invalid clip skipped before build
    assert "too short" not in labels and "too short" in dropped  # below hard_min -> dropped
    assert "good" in labels
