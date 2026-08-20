"""The `inject-markers` subcommand: byte-level MARK-chunk injection into AIFFs
the Swift app already rendered (markerless PCM).

Swift now renders slice AIFFs itself; Python's only job on this path is stamping
word markers into those files via the existing `aiff_markers` primitives. No
WhisperX, no models, no afconvert — synthetic AIFFs built the same way
`test_aiff_markers.py` does, and `run_inject`/`_cmd_inject`/`main` are called
directly rather than shelling out (there is nothing platform-specific here).
"""

import json
import struct

import pytest

from logic_markers import aiff_markers
from logic_markers.aiff_markers import parse_chunks
from logic_markers.cli import _cmd_inject, main, run_inject


def _float_to_extended80(value: float) -> bytes:
    """Minimal encoder for the 80-bit extended used by COMM (positive ints)."""
    if value == 0:
        return b"\x00" * 10
    exponent = 16383 + 63
    mantissa = value
    while mantissa < (1 << 63):
        mantissa *= 2
        exponent -= 1
    while mantissa >= (1 << 64):
        mantissa //= 2
        exponent += 1
    return struct.pack(">H", exponent) + struct.pack(">Q", int(mantissa))


def _synthetic_aiff(sample_rate: int = 44100, frames: int = 1000) -> bytes:
    comm = (
        struct.pack(">h", 2)                        # channels
        + struct.pack(">I", frames)                 # numSampleFrames
        + struct.pack(">h", 16)                     # sampleSize
        + _float_to_extended80(sample_rate)         # sampleRate (ext80)
    )
    audio = b"\x00" * (frames * 2 * 2)              # stereo 16-bit
    ssnd = struct.pack(">I", 0) + struct.pack(">I", 0) + audio
    body = b"AIFF"
    for ck_id, ck_data in ((b"COMM", comm), (b"SSND", ssnd)):
        body += ck_id + struct.pack(">I", len(ck_data)) + ck_data
        if len(ck_data) & 1:
            body += b"\x00"
    return b"FORM" + struct.pack(">I", len(body)) + body


def _write_aiff(path, **kwargs) -> None:
    path.write_bytes(_synthetic_aiff(**kwargs))


def _read_markers(aiff: bytes):
    _, chunks = parse_chunks(aiff)
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


def _write_request(path, files) -> None:
    path.write_text(json.dumps({"files": files}))


def test_markers_injected_and_parseable(tmp_path):
    aiff_path = tmp_path / "slice.aiff"
    _write_aiff(aiff_path, frames=1000)
    request = tmp_path / "request.json"
    markers = [
        {"position": 0, "name": "So"},
        {"position": 100, "name": "a"},
        {"position": 500, "name": "young"},
    ]
    _write_request(request, [{"path": str(aiff_path), "markers": markers}])

    result = run_inject(request)

    assert result == {"files": [{"path": str(aiff_path), "marker_count": 3}]}
    parsed = _read_markers(aiff_path.read_bytes())
    assert parsed == [(1, 0, "So"), (2, 100, "a"), (3, 500, "young")]


def test_audio_bytes_unchanged_by_injection(tmp_path):
    aiff_path = tmp_path / "slice.aiff"
    _write_aiff(aiff_path, frames=1000)
    before = aiff_path.read_bytes()
    _, before_chunks = parse_chunks(before)
    before_by_id = dict(before_chunks)

    request = tmp_path / "request.json"
    _write_request(
        request, [{"path": str(aiff_path), "markers": [{"position": 0, "name": "x"}]}]
    )
    run_inject(request)

    after = aiff_path.read_bytes()
    _, after_chunks = parse_chunks(after)
    after_by_id = dict(after_chunks)
    assert after_by_id[b"COMM"] == before_by_id[b"COMM"]
    assert after_by_id[b"SSND"] == before_by_id[b"SSND"]


def test_replacing_existing_mark_chunk_does_not_duplicate(tmp_path):
    aiff_path = tmp_path / "slice.aiff"
    _write_aiff(aiff_path, frames=1000)
    request = tmp_path / "request.json"
    _write_request(
        request, [{"path": str(aiff_path), "markers": [{"position": 0, "name": "first"}]}]
    )
    run_inject(request)

    request2 = tmp_path / "request2.json"
    _write_request(
        request2,
        [{"path": str(aiff_path), "markers": [{"position": 10, "name": "second"}]}],
    )
    run_inject(request2)

    _, chunks = parse_chunks(aiff_path.read_bytes())
    assert [ck_id for ck_id, _ in chunks].count(b"MARK") == 1
    assert _read_markers(aiff_path.read_bytes()) == [(1, 10, "second")]


def test_multiple_files_each_get_their_own_markers(tmp_path):
    a_path = tmp_path / "a.aiff"
    b_path = tmp_path / "b.aiff"
    _write_aiff(a_path, frames=1000)
    _write_aiff(b_path, frames=1000)
    request = tmp_path / "request.json"
    _write_request(
        request,
        [
            {"path": str(a_path), "markers": [{"position": 1, "name": "a1"}]},
            {
                "path": str(b_path),
                "markers": [
                    {"position": 2, "name": "b1"},
                    {"position": 3, "name": "b2"},
                ],
            },
        ],
    )

    result = run_inject(request)

    assert result == {
        "files": [
            {"path": str(a_path), "marker_count": 1},
            {"path": str(b_path), "marker_count": 2},
        ]
    }
    assert _read_markers(a_path.read_bytes()) == [(1, 1, "a1")]
    assert _read_markers(b_path.read_bytes()) == [(1, 2, "b1"), (2, 3, "b2")]


def test_empty_markers_list_writes_empty_mark_chunk(tmp_path):
    aiff_path = tmp_path / "slice.aiff"
    _write_aiff(aiff_path, frames=1000)
    request = tmp_path / "request.json"
    _write_request(request, [{"path": str(aiff_path), "markers": []}])

    result = run_inject(request)

    assert result == {"files": [{"path": str(aiff_path), "marker_count": 0}]}
    _, chunks = parse_chunks(aiff_path.read_bytes())
    md = dict(chunks)[b"MARK"]
    assert struct.unpack(">H", md[0:2])[0] == 0


def test_out_of_range_position_at_frame_count_raises(tmp_path):
    aiff_path = tmp_path / "slice.aiff"
    _write_aiff(aiff_path, frames=1000)
    request = tmp_path / "request.json"
    _write_request(
        request, [{"path": str(aiff_path), "markers": [{"position": 1000, "name": "x"}]}]
    )

    with pytest.raises(ValueError, match=str(aiff_path)):
        run_inject(request)


def test_negative_position_raises(tmp_path):
    aiff_path = tmp_path / "slice.aiff"
    _write_aiff(aiff_path, frames=1000)
    request = tmp_path / "request.json"
    _write_request(
        request, [{"path": str(aiff_path), "markers": [{"position": -1, "name": "x"}]}]
    )

    with pytest.raises(ValueError, match=str(aiff_path)):
        run_inject(request)


def test_truncated_ssnd_raises(tmp_path):
    aiff_path = tmp_path / "slice.aiff"
    good = _synthetic_aiff(frames=1000)
    form_type, chunks = aiff_markers.parse_chunks(good)
    truncated_chunks = [
        (cid, data[: 8 + (len(data) - 8) // 2] if cid == b"SSND" else data)
        for cid, data in chunks
    ]
    aiff_path.write_bytes(aiff_markers.build_form(form_type, truncated_chunks))

    request = tmp_path / "request.json"
    _write_request(
        request, [{"path": str(aiff_path), "markers": [{"position": 0, "name": "x"}]}]
    )

    with pytest.raises(ValueError, match="truncated"):
        run_inject(request)


def test_missing_audio_file_raises_with_path(tmp_path):
    missing = tmp_path / "nope.aiff"
    request = tmp_path / "request.json"
    _write_request(request, [{"path": str(missing), "markers": []}])

    with pytest.raises(ValueError, match=str(missing)):
        run_inject(request)


def test_missing_request_file_returns_2(tmp_path, capsys):
    missing_request = tmp_path / "nope.json"
    aiff_path = tmp_path / "slice.aiff"
    _write_aiff(aiff_path)

    code = main(["inject-markers", "--request", str(missing_request)])

    assert code == 2
    captured = capsys.readouterr()
    assert str(missing_request) in captured.err


def test_stdout_is_pure_json_and_matches_result_shape(tmp_path, capsys):
    aiff_path = tmp_path / "slice.aiff"
    _write_aiff(aiff_path, frames=1000)
    request = tmp_path / "request.json"
    _write_request(
        request, [{"path": str(aiff_path), "markers": [{"position": 0, "name": "x"}]}]
    )

    code = main(["inject-markers", "--request", str(request)])

    assert code == 0
    captured = capsys.readouterr()
    result = json.loads(captured.out)
    assert result == {"files": [{"path": str(aiff_path), "marker_count": 1}]}


def test_cmd_inject_returns_0_on_success(tmp_path):
    aiff_path = tmp_path / "slice.aiff"
    _write_aiff(aiff_path, frames=1000)
    request_path = tmp_path / "request.json"
    _write_request(request_path, [{"path": str(aiff_path), "markers": []}])

    class Args:
        request = request_path

    assert _cmd_inject(Args()) == 0
