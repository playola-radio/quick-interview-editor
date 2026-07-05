import json
import subprocess
import sys
import wave
from pathlib import Path

from logic_markers.words import Segment, Transcript, Word


def _write_wav(path: Path, seconds=0.5, sr=16000):
    n = int(seconds * sr)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"\x00\x00" * n)  # silence is fine; alignment is pre-seeded


def _seed_transcript(cache: Path):
    t = Transcript(
        words=(
            Word(id=1, text="hello", start=0.05, end=0.15),
            Word(id=2, text="world", start=0.20, end=0.35),
        ),
        segments=(Segment(id=1, word_ids=(1, 2), text="hello world"),),
    )
    cache.write_text(json.dumps(t.to_dict()))


def _run_plan(tmp_path: Path):
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    src = src_dir / "clip.wav"
    _write_wav(src)
    work = tmp_path / "work"
    work.mkdir()
    _seed_transcript(work / "clip.wav.transcript.json")
    proc = subprocess.run(
        [sys.executable, "-m", "logic_markers.cli", "plan",
         str(src), "--work-dir", str(work)],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stderr
    return src, work, proc


def test_plan_emits_editplan_json_with_empty_segments(tmp_path):
    src, _work, proc = _run_plan(tmp_path)
    plan = json.loads(proc.stdout)
    assert plan["schema_version"] == 1
    assert plan["segments"] == []
    assert [w["text"] for w in plan["words"]] == ["hello", "world"]
    assert all(w["start_sample"] is not None and w["end_sample"] is not None
               for w in plan["words"])
    assert plan["source"]["sample_rate"] > 0
    assert plan["source"]["duration_samples"] > 0


def test_plan_writes_nothing_beside_source(tmp_path):
    src, _work, _proc = _run_plan(tmp_path)
    siblings = sorted(p.name for p in src.parent.iterdir())
    assert siblings == ["clip.wav"]  # no .transcript.json / .aiff / .edit-plan.json


def test_plan_emits_progress_events_on_stderr(tmp_path):
    _src, _work, proc = _run_plan(tmp_path)
    phases = []
    for line in proc.stderr.splitlines():
        if line.startswith("QIE_EVENT "):
            evt = json.loads(line[len("QIE_EVENT "):])
            if evt.get("type") == "progress":
                phases.append(evt["phase"])
    assert "transcribing" in phases
    assert "writing_plan" in phases
    assert phases == sorted(phases, key=["transcribing", "converting",
            "analyzing_silence", "writing_plan"].index)  # in canonical order


def _run_plan_seeded(tmp_path: Path, words):
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    src = src_dir / "clip.wav"
    _write_wav(src)
    work = tmp_path / "work"
    work.mkdir()
    transcript = Transcript(
        words=tuple(words),
        segments=(Segment(id=1, word_ids=tuple(w.id for w in words),
                          text=" ".join(w.text for w in words)),),
    )
    (work / "clip.wav.transcript.json").write_text(json.dumps(transcript.to_dict()))
    proc = subprocess.run(
        [sys.executable, "-m", "logic_markers.cli", "plan",
         str(src), "--work-dir", str(work)],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stderr
    return json.loads(proc.stdout)


def test_plan_clamps_trailing_word_end_to_duration(tmp_path):
    # Final word has no end and starts near EOF; the 0.4s fallback would run past
    # the 0.5s clip. The emitted end_sample must not exceed duration_samples.
    plan = _run_plan_seeded(tmp_path, [
        Word(id=1, text="hello", start=0.05, end=0.15),
        Word(id=2, text="world", start=0.35, end=None),
    ])
    duration = plan["source"]["duration_samples"]
    last = plan["words"][-1]
    assert last["end_sample"] is not None
    assert last["end_sample"] <= duration
    assert last["start_sample"] <= last["end_sample"]
