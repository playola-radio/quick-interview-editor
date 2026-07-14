"""The `render` subcommand: stateless slice rendering driven by a request file.

Swift writes a request.json (canonical-rate markers + slice sample ranges) and hands
the engine the canonical PCM AIFF it already analyzed. The engine slices that AIFF
directly (no reconversion), writes `<id>.aiff` into the work-dir, and emits a result
JSON keyed by slice id on stdout plus `QIE_EVENT` progress on stderr. No WhisperX, no
models — a tiny real AIFF and a hand-built request drive the whole path.

The canonical AIFF is produced here with afconvert (macOS-only), so this suite skips
on Linux like test_plan.py.
"""

import json
import shutil
import struct
import subprocess
import sys
import wave
from pathlib import Path

import pytest

from logic_markers import aiff_markers
from logic_markers.audio import convert_to_aiff

pytestmark = pytest.mark.skipif(
    shutil.which("afconvert") is None,
    reason="afconvert (macOS-only) is required for the render/convert pipeline",
)

SR = 44100


def _write_wav(path: Path, frames: int, sr: int = SR):
    """A mono 16-bit WAV of `frames` samples at `sr` (silence; content is irrelevant)."""
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"\x00\x00" * frames)


def _write_canonical_aiff(path: Path, frames: int, sr: int = SR) -> Path:
    """A canonical linear-PCM AIFF of `frames` samples at `sr` — what the app hands render."""
    wav = path.with_suffix(".wav")
    _write_wav(wav, frames, sr)
    convert_to_aiff(wav, path, sr)
    wav.unlink()
    return path


def _read_frame_count(aiff: bytes) -> int:
    _, chunks = aiff_markers.parse_chunks(aiff)
    comm = dict(chunks)[b"COMM"]
    return struct.unpack(">I", comm[2:6])[0]


def _read_markers(aiff: bytes):
    _, chunks = aiff_markers.parse_chunks(aiff)
    md = dict(chunks).get(b"MARK")
    if md is None:
        return []
    count = struct.unpack(">H", md[0:2])[0]
    out, pos = [], 2
    for _ in range(count):
        mid = struct.unpack(">h", md[pos : pos + 2])[0]
        p = struct.unpack(">I", md[pos + 2 : pos + 6])[0]
        nlen = md[pos + 6]
        name = md[pos + 7 : pos + 7 + nlen].decode()
        out.append((mid, p, name))
        adv = 6 + 1 + nlen
        adv += adv & 1
        pos += adv
    return out


def _run_render(tmp_path: Path, frames: int, markers, slices):
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    src = _write_canonical_aiff(src_dir / "clip.plan.aiff", frames)
    work = tmp_path / "work"
    work.mkdir()
    request = {"sample_rate": SR, "markers": markers, "slices": slices}
    req_path = work / "request.json"
    req_path.write_text(json.dumps(request))
    proc = subprocess.run(
        [sys.executable, "-m", "logic_markers.cli", "render", str(src),
         "--request", str(req_path), "--work-dir", str(work)],
        capture_output=True, text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    return src, work, proc


MARKERS = [
    {"position": 0, "name": "So"},
    {"position": 10000, "name": "a"},
    {"position": 20000, "name": "young"},
    {"position": 30000, "name": "Hayes"},
    {"position": 40000, "name": "Carl"},
]
SLICES = [
    {"id": "AAAAAAAA-1111-2222-3333-444444444444", "start_sample": 5000, "end_sample": 25000},
    {"id": "BBBBBBBB-5555-6666-7777-888888888888", "start_sample": 30000, "end_sample": 44100},
]


def test_render_writes_one_aiff_per_slice_with_matching_frame_counts(tmp_path):
    _src, work, proc = _run_render(tmp_path, 44100, MARKERS, SLICES)
    result = json.loads(proc.stdout)
    by_id = {s["id"]: s for s in result["slices"]}
    assert set(by_id) == {s["id"] for s in SLICES}
    for spec in SLICES:
        out = Path(by_id[spec["id"]]["path"])
        assert out.parent == work
        assert out.exists()
        aiff = out.read_bytes()
        assert _read_frame_count(aiff) == spec["end_sample"] - spec["start_sample"]


def test_render_result_is_keyed_by_id_not_order(tmp_path):
    # Reverse the slice order in the request; the result must still resolve by id.
    _src, _work, proc = _run_render(tmp_path, 44100, MARKERS, list(reversed(SLICES)))
    result = json.loads(proc.stdout)
    by_id = {s["id"]: s for s in result["slices"]}
    for spec in SLICES:
        assert by_id[spec["id"]]["start_sample"] == spec["start_sample"]
        assert by_id[spec["id"]]["end_sample"] == spec["end_sample"]


def test_render_markers_are_rebased_and_renumbered_within_each_slice(tmp_path):
    _src, _work, proc = _run_render(tmp_path, 44100, MARKERS, SLICES)
    result = json.loads(proc.stdout)
    by_id = {s["id"]: s for s in result["slices"]}

    a = _read_markers(Path(by_id[SLICES[0]["id"]]["path"]).read_bytes())
    # slice A [5000,25000): markers 10000 and 20000 → rebased to 5000, 15000; ids 1,2
    assert a == [(1, 5000, "a"), (2, 15000, "young")]

    b = _read_markers(Path(by_id[SLICES[1]["id"]]["path"]).read_bytes())
    # slice B [30000,44100): markers 30000 and 40000 → rebased to 0, 10000; ids 1,2
    assert b == [(1, 0, "Hayes"), (2, 10000, "Carl")]


def test_render_writes_nothing_beside_source(tmp_path):
    src, _work, _proc = _run_render(tmp_path, 44100, MARKERS, SLICES)
    siblings = sorted(p.name for p in src.parent.iterdir())
    assert siblings == ["clip.plan.aiff"]  # no per-slice outputs beside the input


def test_render_slices_canonical_aiff_without_reconversion(tmp_path):
    # The input is already a canonical AIFF; render slices it directly. A
    # frame-exact result (no resample) is the observable proof of no reconversion.
    _src, work, _proc = _run_render(tmp_path, 44100, MARKERS, SLICES)
    # No intermediate `render.aiff` is left behind — render never wrote one.
    assert not (work / "render.aiff").exists()


def test_render_rejects_rate_mismatch(tmp_path):
    # The canonical AIFF's COMM rate must equal the request's sample_rate; otherwise
    # cuts would land on the wrong samples. Fail loud rather than drift.
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    src = _write_canonical_aiff(src_dir / "clip.plan.aiff", 44100, SR)
    work = tmp_path / "work"
    work.mkdir()
    slice_id = "DDDDDDDD-1111-2222-3333-444444444444"
    request = {
        "sample_rate": 48000,  # != the AIFF's 44100
        "markers": MARKERS,
        "slices": [{"id": slice_id, "start_sample": 0, "end_sample": 100}],
    }
    req_path = work / "request.json"
    req_path.write_text(json.dumps(request))
    proc = subprocess.run(
        [sys.executable, "-m", "logic_markers.cli", "render", str(src),
         "--request", str(req_path), "--work-dir", str(work)],
        capture_output=True, text=True, check=False,
    )
    assert proc.returncode != 0
    assert "sample rate" in proc.stderr
    assert not (work / f"{slice_id}.aiff").exists()


def test_render_rejects_frame_count_mismatch(tmp_path):
    # `duration_samples` in the request is the plan's frame count. A canonical AIFF
    # whose actual frame count differs (stale/truncated/swapped file) must fail loud
    # rather than render silently from the wrong audio.
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    src = _write_canonical_aiff(src_dir / "clip.plan.aiff", 44100)  # 44100 frames
    work = tmp_path / "work"
    work.mkdir()
    slice_id = "EEEEEEEE-1111-2222-3333-444444444444"
    request = {
        "sample_rate": SR,
        "duration_samples": 40000,  # != the AIFF's 44100 frames
        "markers": MARKERS,
        "slices": [{"id": slice_id, "start_sample": 0, "end_sample": 100}],
    }
    req_path = work / "request.json"
    req_path.write_text(json.dumps(request))
    proc = subprocess.run(
        [sys.executable, "-m", "logic_markers.cli", "render", str(src),
         "--request", str(req_path), "--work-dir", str(work)],
        capture_output=True, text=True, check=False,
    )
    assert proc.returncode != 0
    assert "frame count" in proc.stderr
    assert not (work / f"{slice_id}.aiff").exists()


def test_render_accepts_matching_frame_count(tmp_path):
    # The happy path: request carries the correct duration_samples, render succeeds.
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    src = _write_canonical_aiff(src_dir / "clip.plan.aiff", 44100)
    work = tmp_path / "work"
    work.mkdir()
    slice_id = "FFFFFFFF-1111-2222-3333-444444444444"
    request = {
        "sample_rate": SR,
        "duration_samples": 44100,
        "markers": MARKERS,
        "slices": [{"id": slice_id, "start_sample": 0, "end_sample": 100}],
    }
    req_path = work / "request.json"
    req_path.write_text(json.dumps(request))
    proc = subprocess.run(
        [sys.executable, "-m", "logic_markers.cli", "render", str(src),
         "--request", str(req_path), "--work-dir", str(work)],
        capture_output=True, text=True, check=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert (work / f"{slice_id}.aiff").exists()


def test_render_rejects_non_aiff_input(tmp_path):
    # Passing a raw (non-AIFF) source must fail loud — render only ever slices the
    # canonical AIFF; it no longer reconverts arbitrary audio.
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    src = src_dir / "clip.wav"
    _write_wav(src, 44100)
    work = tmp_path / "work"
    work.mkdir()
    request = {"sample_rate": SR, "markers": MARKERS, "slices": SLICES}
    req_path = work / "request.json"
    req_path.write_text(json.dumps(request))
    proc = subprocess.run(
        [sys.executable, "-m", "logic_markers.cli", "render", str(src),
         "--request", str(req_path), "--work-dir", str(work)],
        capture_output=True, text=True, check=False,
    )
    assert proc.returncode != 0
    assert "AIFF" in proc.stderr


def test_render_emits_progress_events_on_stderr(tmp_path):
    _src, _work, proc = _run_render(tmp_path, 44100, MARKERS, SLICES)
    events = []
    for line in proc.stderr.splitlines():
        if line.startswith("QIE_EVENT "):
            evt = json.loads(line[len("QIE_EVENT "):])
            if evt.get("type") == "progress":
                events.append(evt)
    assert events, "expected at least one rendering progress event"
    assert all(e["phase"] == "rendering" for e in events)
    # One event per slice, carrying index/total, in order.
    slice_events = [e for e in events if e.get("index", 0) >= 1]
    assert [e["index"] for e in slice_events] == [1, 2]
    assert all(e["total"] == 2 for e in slice_events)


def test_render_stdout_is_pure_json(tmp_path):
    _src, _work, proc = _run_render(tmp_path, 44100, MARKERS, SLICES)
    # Whole stdout parses as JSON — no stray prints leaked onto the channel.
    result = json.loads(proc.stdout)
    assert "slices" in result


def test_render_rejects_non_uuid_slice_id_and_writes_nothing_outside(tmp_path):
    # A slice id with a path fragment must be rejected before any file is written,
    # so a malformed request can't escape the work-dir.
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    src = _write_canonical_aiff(src_dir / "clip.plan.aiff", 44100)
    work = tmp_path / "work"
    work.mkdir()
    outside = tmp_path / "outside.aiff"
    request = {
        "sample_rate": SR,
        "markers": MARKERS,
        "slices": [{"id": f"../{outside.stem}", "start_sample": 0, "end_sample": 100}],
    }
    req_path = work / "request.json"
    req_path.write_text(json.dumps(request))
    proc = subprocess.run(
        [sys.executable, "-m", "logic_markers.cli", "render", str(src),
         "--request", str(req_path), "--work-dir", str(work)],
        capture_output=True, text=True,
        check=False,
    )
    assert proc.returncode != 0
    assert "invalid slice id" in proc.stderr
    assert not outside.exists()  # nothing written outside the work-dir


def test_render_rejects_out_of_range_slice(tmp_path):
    # An end past the converted audio must fail explicitly rather than be silently
    # clamped to a shorter AIFF while the result reports the requested range.
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    src = _write_canonical_aiff(src_dir / "clip.plan.aiff", 44100)
    work = tmp_path / "work"
    work.mkdir()
    slice_id = "CCCCCCCC-1111-2222-3333-444444444444"
    request = {
        "sample_rate": SR,
        "markers": MARKERS,
        "slices": [{"id": slice_id, "start_sample": 0, "end_sample": 99999}],
    }
    req_path = work / "request.json"
    req_path.write_text(json.dumps(request))
    proc = subprocess.run(
        [sys.executable, "-m", "logic_markers.cli", "render", str(src),
         "--request", str(req_path), "--work-dir", str(work)],
        capture_output=True, text=True,
        check=False,
    )
    assert proc.returncode != 0
    assert "outside the render audio" in proc.stderr
    assert not (work / f"{slice_id}.aiff").exists()
