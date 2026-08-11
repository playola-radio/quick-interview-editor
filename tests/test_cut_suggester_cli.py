"""The `cut_suggester.cli suggest` entrypoint: request adapter, result shaping,
progress, and the subprocess contract — all driven by a fake LLM (no network)."""

import json
import subprocess
import sys

import pytest

from cut_suggester.cache import CachingLLMClient
from cut_suggester.cli import run_suggest, sentences_from_units, specs_from_request
from cut_suggester.llm import LLMResponse
from cut_suggester.models import ProductType

SR = 1000


def _units(n, sec_per=20.0):
    """`n` transcript units at `sec_per` seconds each (the app's wire shape)."""
    out = []
    wid = 1
    for i in range(n):
        start, end = i * sec_per, (i + 1) * sec_per
        out.append(
            {
                "id": i,
                "text": f"sentence {i}",
                "word_ids": [wid, wid + 1],
                "start_sec": start,
                "end_sec": end,
                "start_sample": round(start * SR),
                "end_sample": round(end * SR),
                "speaker_id": None,
            }
        )
        wid += 2
    return out


class _FakeLLM:
    def __init__(self, partitions_json, clips_json):
        self.partitions_json = partitions_json
        self.clips_json = clips_json

    def complete(self, prompt, *, purpose=""):
        text = self.partitions_json if purpose.startswith("partition") else self.clips_json
        return LLMResponse(text=text)


_PARTITIONS = '{"paragraphs": [{"start":0,"end":2,"label":"one"},{"start":3,"end":5,"label":"two"}]}'
_CLIPS = (
    '{"clips": ['
    '{"type":"spotlight","start":0,"end":2,"label":"Story One","song":null},'
    '{"type":"spotlight","start":3,"end":5,"label":"Story Two","song":null}]}'
)


def _request(units=None, options=None):
    return {
        "transcript_units": units if units is not None else _units(6),
        "product_specs": None,
        "options": {"model": "gpt-4o", "sample_rate": SR, **(options or {})},
        "diarization": None,
    }


# --- request adapter -------------------------------------------------------
def test_sentences_from_units_maps_samples_and_contiguous_indices():
    sents = sentences_from_units(_units(2))
    assert [s.index for s in sents] == [0, 1]
    assert sents[0].segment_id == 0
    assert sents[0].word_ids == (1, 2)
    assert sents[0].start_sample == 0 and sents[0].end_sample == 20000


def test_sentences_from_units_rejects_empty_text():
    bad = _units(1)
    bad[0]["text"] = "   "
    with pytest.raises(ValueError, match="empty text"):
        sentences_from_units(bad)


def test_sentences_from_units_rejects_missing_word_ids():
    bad = _units(1)
    bad[0]["word_ids"] = []
    with pytest.raises(ValueError, match="no word_ids"):
        sentences_from_units(bad)


def test_sentences_from_units_rejects_incoherent_samples():
    bad = _units(1)
    bad[0]["end_sample"] = bad[0]["start_sample"] - 1
    with pytest.raises(ValueError, match="end_sample < start_sample"):
        sentences_from_units(bad)


def test_sentences_from_units_rejects_malformed_unit():
    with pytest.raises(ValueError, match="malformed"):
        sentences_from_units([{"id": 0, "text": "x"}])  # missing fields


# --- product specs ---------------------------------------------------------
def test_specs_from_request_falls_back_to_defaults():
    specs = specs_from_request(None)
    assert set(specs) == {ProductType.SPOTLIGHT, ProductType.INTRO}


def test_specs_from_request_rejects_unknown_type():
    with pytest.raises(ValueError):
        specs_from_request([{"product_type": "bumper", "target_min_sec": 1,
                             "target_max_sec": 2, "hard_min_sec": 1, "hard_max_sec": 2}])


# --- run_suggest (fake LLM, no network) ------------------------------------
def test_run_suggest_shapes_ranked_suggestions():
    result = run_suggest(_request(), _FakeLLM(_PARTITIONS, _CLIPS), emit=lambda e: None)
    assert {s["label"] for s in result["suggestions"]} == {"Story One", "Story Two"}
    assert all(s["product_type"] == "spotlight" for s in result["suggestions"])
    assert sorted(s["rank"] for s in result["suggestions"]) == [1, 2]
    assert result["meta"]["n_sentences"] == 6


def test_run_suggest_rejects_missing_or_empty_transcript_units():
    # A missing/empty transcript is an encoding regression, not "zero clips" — it must
    # fail loud so the app never overwrites persisted suggestions with an empty result.
    for req in ({"options": {"model": "gpt-4o"}}, _request(units=[])):
        with pytest.raises(ValueError, match="no transcript_units"):
            run_suggest(req, _FakeLLM(_PARTITIONS, _CLIPS), emit=lambda e: None)


def test_run_suggest_emits_progress_phases():
    events = []
    run_suggest(_request(), _FakeLLM(_PARTITIONS, _CLIPS), emit=events.append)
    phases = [e["phase"] for e in events]
    assert phases[0] == "started"
    assert "partitioning" in phases
    assert "classifying" in phases
    assert phases[-1] == "completed"
    assert all(e["type"] == "progress" for e in events)


# --- subprocess contract ---------------------------------------------------
def _run_cli(tmp_path, request, extra_args):
    req = tmp_path / "request.json"
    req.write_text(json.dumps(request))
    return subprocess.run(
        [sys.executable, "-m", "cut_suggester.cli", "suggest", "--request", str(req), *extra_args],
        capture_output=True,
        text=True,
        check=False,
    )


def test_cli_missing_request_file_returns_2(tmp_path):
    proc = subprocess.run(
        [sys.executable, "-m", "cut_suggester.cli", "suggest",
         "--request", str(tmp_path / "nope.json")],
        capture_output=True, text=True, check=False,
    )
    assert proc.returncode == 2
    assert "no such request file" in proc.stderr


def test_cli_cached_only_miss_fails_cleanly(tmp_path):
    cache = tmp_path / "cache"
    proc = _run_cli(tmp_path, _request(), ["--cache-dir", str(cache), "--cached"])
    assert proc.returncode == 1
    assert "no cached response" in proc.stderr


def _prepopulate_cache(cache_dir, request):
    """Populate the disk cache in-process (fake LLM) so the subprocess can replay
    it in `--cached` mode with matching keys."""
    options = request["options"]
    client = CachingLLMClient(
        str(cache_dir),
        inner=_FakeLLM(_PARTITIONS, _CLIPS),
        model=options["model"],
        prompt_version="v1",
        product_spec_version="v1",
        window_params={"window": 130, "step": 110},
    )
    run_suggest(request, client, emit=lambda e: None)


def test_cli_cached_happy_path_emits_json_and_progress(tmp_path):
    cache = tmp_path / "cache"
    request = _request()
    _prepopulate_cache(cache, request)

    proc = _run_cli(tmp_path, request, ["--cache-dir", str(cache), "--cached"])
    assert proc.returncode == 0, proc.stderr

    # stdout is pure JSON (fd-redirect kept stray prints off the channel).
    result = json.loads(proc.stdout)
    assert {s["label"] for s in result["suggestions"]} == {"Story One", "Story Two"}

    # Progress flows over stderr as QIE_EVENT lines.
    events = [
        json.loads(line[len("QIE_EVENT "):])
        for line in proc.stderr.splitlines()
        if line.startswith("QIE_EVENT ")
    ]
    assert any(e["phase"] == "completed" for e in events)
