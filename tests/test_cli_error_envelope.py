"""Both helper CLIs report a hard failure as exactly one `QIE_ERROR` stderr line."""

import json

import pytest

import cut_suggester.cli as suggester_cli
import logic_markers.cli as engine_cli
from cut_suggester.llm import LLMError


def _error_lines(stderr):
    return [line for line in stderr.splitlines() if line.startswith("QIE_ERROR ")]


def _only_error(capsys):
    stderr = capsys.readouterr().err
    lines = _error_lines(stderr)
    assert len(lines) == 1, stderr
    return json.loads(lines[0].removeprefix("QIE_ERROR ")), stderr


def _credits_error():
    return LLMError(
        "credits", "Your credit balance is too low.", status_code=400,
        request_id="req_1", error_type="BadRequestError",
    )


def _run_suggest_failing(monkeypatch, tmp_path, exc, *, phase=None):
    def failing(args):
        if phase is not None:
            suggester_cli._emit_event({"type": "progress", "phase": phase, "message": "working"})
        raise exc

    monkeypatch.setattr(suggester_cli, "_cmd_suggest", failing)
    return suggester_cli.main(["suggest", "--request", str(tmp_path / "r.json")])


def test_suggester_llm_failure_reports_provider_facts(monkeypatch, tmp_path, capsys):
    code = _run_suggest_failing(monkeypatch, tmp_path, _credits_error(), phase="discovering")
    report, _ = _only_error(capsys)
    assert code == 1
    assert report == {
        "schema_version": 1, "domain": "cut_suggester", "operation": "suggest",
        "phase": "discovering", "message": "Your credit balance is too low.",
        "error_type": "LLMError",
        "provider_error": {
            "category": "credits", "message": "Your credit balance is too low.",
            "status_code": 400, "request_id": "req_1", "retry_after": None,
            "retryable": False,
        },
    }


def test_suggester_chained_llm_failure_still_reports_provider_facts(
        monkeypatch, tmp_path, capsys):
    try:
        try:
            raise _credits_error()
        except LLMError as cause:
            raise RuntimeError("discovery stopped") from cause
    except RuntimeError as wrapped:
        exc = wrapped
    _run_suggest_failing(monkeypatch, tmp_path, exc)
    report, _ = _only_error(capsys)
    assert report["provider_error"]["category"] == "credits"
    assert report["message"] == "discovery stopped (caused by LLMError: Your credit balance is too low.)"


def test_suggester_non_provider_failure_has_no_provider_error(monkeypatch, tmp_path, capsys):
    code = _run_suggest_failing(monkeypatch, tmp_path, ValueError("bad request shape"))
    report, _ = _only_error(capsys)
    assert code == 1
    assert "provider_error" not in report
    assert report["phase"] is None
    assert (report["message"], report["error_type"]) == ("bad request shape", "ValueError")


def test_suggester_empty_message_falls_back_to_type_name(monkeypatch, tmp_path, capsys):
    _run_suggest_failing(monkeypatch, tmp_path, KeyError())
    report, _ = _only_error(capsys)
    assert report["message"] == "KeyError"


def test_suggester_failure_never_prints_a_traceback(monkeypatch, tmp_path, capsys):
    monkeypatch.delenv("QIE_DEBUG", raising=False)
    _run_suggest_failing(monkeypatch, tmp_path, RuntimeError("boom"))
    _, stderr = _only_error(capsys)
    assert "Traceback" not in stderr
    assert stderr.strip().splitlines() == [line for line in stderr.strip().splitlines()
                                            if line.startswith("QIE_")]


def test_debug_traceback_stays_out_of_the_error_json(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("QIE_DEBUG", "1")
    _run_suggest_failing(monkeypatch, tmp_path, RuntimeError("boom"))
    report, stderr = _only_error(capsys)
    assert "Traceback" in stderr
    assert "Traceback" not in json.dumps(report)


def test_suggester_missing_request_file_is_one_error_line(tmp_path, capsys):
    code = suggester_cli.main(["suggest", "--request", str(tmp_path / "nope.json")])
    report, stderr = _only_error(capsys)
    assert code == 2
    assert "no such request file" in report["message"]
    assert stderr.strip() == _error_lines(stderr)[0]


def test_name_clip_failure_names_its_operation(monkeypatch, tmp_path, capsys):
    def failing(args):
        raise _credits_error()

    monkeypatch.setattr(suggester_cli, "_cmd_name_clip", failing)
    suggester_cli.main(["name-clip", "--request", str(tmp_path / "r.json")])
    report, _ = _only_error(capsys)
    assert (report["operation"], report["provider_error"]["category"]) == ("name-clip", "credits")


def test_engine_failure_reports_operation_and_last_phase(monkeypatch, tmp_path, capsys):
    audio = tmp_path / "in.wav"
    audio.write_bytes(b"")

    def failing(args):
        engine_cli._progress("transcribing", "Preparing audio…")
        raise RuntimeError("afconvert failed (1): unsupported format")

    monkeypatch.setattr(engine_cli, "_cmd_plan", failing)
    code = engine_cli.main(["plan", str(audio), "--work-dir", str(tmp_path)])
    report, _ = _only_error(capsys)
    assert code == 1
    assert report == {
        "schema_version": 1, "domain": "logic_markers", "operation": "plan",
        "phase": "transcribing", "message": "afconvert failed (1): unsupported format",
        "error_type": "RuntimeError",
    }


def test_engine_missing_input_is_one_error_line(tmp_path, capsys):
    code = engine_cli.main(["plan", str(tmp_path / "nope.wav"), "--work-dir", str(tmp_path)])
    report, stderr = _only_error(capsys)
    assert code == 2
    assert "no such file" in report["message"]
    assert stderr.strip() == _error_lines(stderr)[0]


@pytest.mark.parametrize("cli", [suggester_cli, engine_cli])
def test_error_line_is_single_line_json_even_with_newlines(cli, capsys):
    cli._emit_error(RuntimeError("line one\nline two"), "op")
    report, stderr = _only_error(capsys)
    assert len(stderr.splitlines()) == 1
    assert report["message"] == "line one\nline two"


@pytest.mark.parametrize("cli, argv, operation", [
    (suggester_cli, ["suggest"], "suggest"),
    (suggester_cli, ["suggest", "--request", "r.json", "--cached", "--refresh"], "suggest"),
    (engine_cli, ["plan"], "plan"),
    (engine_cli, [], "logic-markers"),
])
def test_argument_errors_are_one_error_line(cli, argv, operation, capsys):
    with pytest.raises(SystemExit) as exit_info:
        cli.main(argv)
    report, stderr = _only_error(capsys)
    assert exit_info.value.code == 2
    assert (report["operation"], report["error_type"]) == (operation, "UsageError")
    assert stderr.strip() == _error_lines(stderr)[0]
