import copy
import json
import os
from pathlib import Path

import pytest

from cut_suggester import cli
from cut_suggester.clip_naming import (
    MAX_PROMPT_CHARACTERS,
    build_prompt,
    parse_response,
    run_name_clip,
    validate_clip_request,
)
from cut_suggester.configured_discovery import FOCUSED_INTRO_RULE
from cut_suggester.llm import LLMResponse

_FIXTURE = json.loads((Path(__file__).parent / "fixtures" / "suggestion-contract-v2.json").read_text())


def _unit(unit_id, start, end, text=None, **extra):
    return {
        "id": unit_id, "text": text or f"context sentence {unit_id}", "word_ids": [unit_id],
        "start_sample": start, "end_sample": end, "start_sec": start / 1000, "end_sec": end / 1000, **extra,
    }


def _request(**overrides):
    request = {
        "schema_version": 1,
        "model": "claude-sonnet-5",
        "configuration": copy.deepcopy(_FIXTURE["configuration"]),
        "clip": {"text": "Nova Reed wrote Glass Harbor in a week.", "start_sample": 10_000, "end_sample": 20_000},
        "transcript_units": [],
    }
    request.update(overrides)
    return request


def _types():
    return _request()["configuration"]["types"]


def _reply(type_id, fields):
    return json.dumps({"type_id": type_id, "fields": [{"field_id": k, "value": v} for k, v in fields.items()]})


class _Fake:
    def __init__(self, text):
        self.text = text
        self.prompts = []

    def complete(self, prompt, *, purpose=""):
        self.prompts.append(prompt)
        return LLMResponse(text=self.text)


def _without(key):
    return lambda r: r.pop(key)


@pytest.mark.parametrize("mutate", [
    lambda r: r.update(schema_version=2),
    lambda r: r.update(schema_version=True),
    lambda r: r.update(model="  "),
    _without("model"),
    lambda r: r["configuration"].update(types=[]),
    lambda r: r["clip"].update(text=" ​ "),
    lambda r: r["clip"].update(start_sample=-1),
    lambda r: r["clip"].update(start_sample=True),
    lambda r: r["clip"].update(end_sample=5_000),
    _without("transcript_units"),
    lambda r: r.update(transcript_units=[{"id": 1}]),
    lambda r: r.update(interview_artist=" "),
])
def test_validation_rejects_malformed_requests(mutate):
    request = _request()
    mutate(request)
    with pytest.raises(ValueError):
        validate_clip_request(request)


def test_validation_accepts_optional_artist_and_empty_context():
    validate_clip_request(_request(interview_artist="Nova Reed"))


def test_prompt_lists_every_type_with_its_fields_and_the_clip_text():
    request = _request()
    prompt = build_prompt(request)

    for item in request["configuration"]["types"]:
        assert item["id"] in prompt and item["name"] in prompt and item["guidelines"] in prompt
    assert request["clip"]["text"] in prompt
    assert "artist-name, song-title" in prompt
    assert "none" in prompt
    assert "Descriptive Title" not in prompt
    assert "- artist-name:" in prompt


def test_prompt_includes_focused_intro_rule_only_when_intro_is_configured():
    request = _request()
    assert FOCUSED_INTRO_RULE in build_prompt(request)

    request["configuration"]["types"] = [t for t in request["configuration"]["types"] if t["id"] != "intro"]
    assert FOCUSED_INTRO_RULE not in build_prompt(request)


def test_prompt_carries_interview_artist_when_supplied():
    assert "Nova Reed" in build_prompt(_request(interview_artist="Nova Reed"))
    assert "User-provided interview artist" not in build_prompt(_request())


def test_context_includes_boundary_crossing_units_and_orders_nearest_first():
    units = [
        _unit(1, 0, 1_000, "far before"),
        _unit(2, 8_000, 12_000, "overlaps the start"),
        _unit(3, 5_000, 9_000, "near before"),
        _unit(4, 19_000, 25_000, "overlaps the end"),
        _unit(5, 21_000, 22_000, "near after"),
        _unit(6, 90_000, 91_000, "far after"),
    ]
    prompt = build_prompt(_request(transcript_units=units))

    assert "overlaps the start [overlaps clip boundary]" in prompt
    assert "overlaps the end [overlaps clip boundary]" in prompt
    positions = [prompt.index(text) for text in (
        "overlaps the start", "overlaps the end", "near before", "near after", "far before", "far after",
    )]
    assert positions == sorted(positions)


def test_context_is_added_only_while_prompt_fits():
    units = [_unit(i, 30_000 + i * 1_000, 30_500 + i * 1_000, f"filler {i} " + "x" * 2_000) for i in range(30)]
    prompt = build_prompt(_request(transcript_units=units))

    assert len(prompt) <= MAX_PROMPT_CHARACTERS
    assert "[0] filler 0" in prompt
    assert "[29] filler 29" not in prompt


def test_oversized_mandatory_prompt_fails_clearly():
    request = _request()
    request["clip"]["text"] = "word " * (MAX_PROMPT_CHARACTERS // 5)
    with pytest.raises(ValueError, match="too long"):
        build_prompt(request)


@pytest.mark.parametrize("text", [
    "not json",
    '{"type_id":"nonsense","fields":[]}',
    '{"type_id":"intro","fields":[{"field_id":"artist-name","value":"A"}]}',
    '{"type_id":"intro","fields":[{"field_id":"artist-name","value":"A"},{"field_id":"song-title","value":null},{"field_id":"descriptive-title","value":"x"}]}',
    '{"type_id":"intro","fields":[{"field_id":"artist-name","value":"A"},{"field_id":"artist-name","value":"B"},{"field_id":"song-title","value":null}]}',
    '{"type_id":"intro","type_id":"spotlight","fields":[]}',
    '{"type_id":"intro","fields":[{"field_id":"artist-name","value":4},{"field_id":"song-title","value":null}]}',
    '{"type_id":"intro","fields":[{"field_id":"artist-name","value":"A","extra":1},{"field_id":"song-title","value":null}]}',
    '{"type_id":"spotlight","fields":[{"field_id":"artist-name","value":"A"}]}',
    '{"type_id":null,"fields":[{"field_id":"artist-name","value":"A"}]}',
    '{"type_id":"spotlight"}',
    "[]",
])
def test_parse_rejects_invalid_replies(text):
    with pytest.raises(ValueError):
        parse_response(text, _types())


def test_parse_trims_values_and_turns_blank_into_none():
    parsed = parse_response(_reply("intro", {"artist-name": "​ Nova Reed ​", "song-title": " "}), _types())

    assert parsed == {"type_id": "intro", "fields": {"artist-name": "Nova Reed", "song-title": None}}


def test_parse_accepts_no_match_and_fieldless_type():
    assert parse_response(_reply(None, {}), _types()) == {"type_id": None, "fields": {}}
    assert parse_response(_reply("spotlight", {}), _types()) == {"type_id": "spotlight", "fields": {}}


def test_run_makes_one_call_and_returns_the_parsed_result():
    llm = _Fake(_reply("intro", {"artist-name": "Nova Reed", "song-title": "Glass Harbor"}))

    result = run_name_clip(_request(), llm)

    assert len(llm.prompts) == 1
    assert result == {"type_id": "intro", "fields": {"artist-name": "Nova Reed", "song-title": "Glass Harbor"}}


def test_run_downgrades_intro_with_no_identity_to_no_match():
    llm = _Fake(_reply("intro", {"artist-name": None, "song-title": " "}))

    assert run_name_clip(_request(), llm) == {"type_id": None, "fields": {}}


def test_run_keeps_intro_with_one_identity_field():
    llm = _Fake(_reply("intro", {"artist-name": "Nova Reed", "song-title": None}))

    assert run_name_clip(_request(), llm)["type_id"] == "intro"


def test_run_reports_invalid_requests_before_calling_the_model():
    llm = _Fake(_reply(None, {}))
    with pytest.raises(ValueError):
        run_name_clip(_request(schema_version=9), llm)
    assert llm.prompts == []


def _write(tmp_path, request):
    path = tmp_path / "request.json"
    path.write_text(json.dumps(request), encoding="utf-8")
    return str(path)


def test_cli_name_clip_prints_only_the_result_json(tmp_path, monkeypatch, capfd):
    class Noisy(_Fake):
        def complete(self, prompt, *, purpose=""):
            os.write(1, b"sdk warning on stdout\n")
            return super().complete(prompt, purpose=purpose)

    seen = []
    monkeypatch.setattr(cli, "live_client_for", lambda model: seen.append(model) or Noisy(_reply("spotlight", {})))

    code = cli.main(["name-clip", "--request", _write(tmp_path, _request())])

    out, err = capfd.readouterr()
    assert code == 0
    assert json.loads(out) == {"type_id": "spotlight", "fields": {}}
    assert "sdk warning" in err
    assert seen == ["claude-sonnet-5"]


def test_cli_name_clip_fails_on_bad_request_and_missing_file(tmp_path, monkeypatch, capfd):
    monkeypatch.setattr(cli, "live_client_for", lambda model: pytest.fail("no client for a bad request"))

    assert cli.main(["name-clip", "--request", _write(tmp_path, _request(schema_version=2))]) != 0
    assert "error:" in capfd.readouterr().err
    assert cli.main(["name-clip", "--request", str(tmp_path / "missing.json")]) != 0
