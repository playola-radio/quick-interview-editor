"""`plan` must keep stdout a pure-JSON channel even when the transcription
libraries (WhisperX/pyannote) spam stdout via `logging`. Regression for the
"given data was not valid JSON" decode failure the app hit on a fresh transcribe.

Runs the CLI in a real subprocess with `run_plan` stubbed to emit stdout noise —
no audio / afconvert, so it runs on every platform (unlike test_plan.py). A
subprocess is required because pytest's own stdout capture would otherwise
intercept the writes the fd-level fix is meant to redirect.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

# Stub run_plan to write WhisperX-style log noise to stdout — at the Python level
# (print) and the C/fd level (os.write to fd 1) — then return a plan. If the fix
# works, _cmd_plan keeps all of that off stdout and emits only the plan JSON.
_STUB = r'''
import os, sys
from logic_markers import cli

def _noisy_run_plan(source, work_dir, sample_rate, refresh=False):
    print("2026-01-01 12:00:00 - whisperx.asr - INFO - No language specified")
    os.write(1, b"2026-01-01 12:00:00 - pyannote - INFO - raw fd-1 noise\n")
    return {
        "schema_version": 1,
        "source": {"path": "x", "sample_rate": 44100, "channels": 1, "duration_samples": 10},
        "words": [], "silences": [], "segments": [],
    }

cli.run_plan = _noisy_run_plan
sys.exit(cli.main(["plan", sys.argv[1], "--work-dir", sys.argv[2]]))
'''


def test_plan_stdout_is_pure_json_when_analysis_writes_to_stdout(tmp_path):
    src = tmp_path / "clip.wav"
    src.write_bytes(b"")  # only needs to exist; stubbed run_plan ignores it
    work = tmp_path / "work"
    work.mkdir()
    stub = tmp_path / "stub.py"
    stub.write_text(_STUB)

    repo_root = Path(__file__).resolve().parent.parent
    proc = subprocess.run(
        [sys.executable, str(stub), str(src), str(work)],
        capture_output=True, text=True,
        env={**os.environ, "PYTHONPATH": str(repo_root)},  # so `import logic_markers` works
    )
    assert proc.returncode == 0, proc.stderr

    # stdout is exactly the plan JSON — no library log lines leaked in.
    plan = json.loads(proc.stdout)
    assert plan["schema_version"] == 1
    assert plan["words"] == []
    # ...and the noise was redirected to stderr instead.
    assert "whisperx.asr" in proc.stderr
    assert "raw fd-1 noise" in proc.stderr
