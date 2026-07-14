import struct

from logic_markers import aiff_markers
from logic_markers.aiff_markers import Marker
from logic_markers.slicer import slice_aiff


def _ext80(value: int) -> bytes:
    if value == 0:
        return b"\x00" * 10
    exponent = 16383 + 63
    mantissa = value
    while mantissa < (1 << 63):
        mantissa <<= 1
        exponent -= 1
    return struct.pack(">H", exponent) + struct.pack(">Q", mantissa)


def _ramp_aiff(frames: int, sr: int = 44100, offset: int = 0) -> bytes:
    """Stereo 16-bit AIFF where frame i holds sample value i in both channels.

    `offset` sets the SSND `offset` field and prepends that many padding bytes
    before the audio (a valid, if rare, AIFF layout).
    """
    comm = struct.pack(">h", 2) + struct.pack(">I", frames) + struct.pack(">h", 16) + _ext80(sr)
    audio = b"".join(struct.pack(">hh", i, i) for i in range(frames))
    ssnd = struct.pack(">I", offset) + struct.pack(">I", 0) + b"\x00" * offset + audio
    body = b"AIFF"
    for cid, cdata in ((b"COMM", comm), (b"SSND", ssnd)):
        body += cid + struct.pack(">I", len(cdata)) + cdata
        if len(cdata) & 1:
            body += b"\x00"
    return b"FORM" + struct.pack(">I", len(body)) + body


def _read_frames(aiff: bytes):
    _, chunks = aiff_markers.parse_chunks(aiff)
    d = dict(chunks)
    audio = d[b"SSND"][8:]
    return [struct.unpack(">hh", audio[i : i + 4]) for i in range(0, len(audio), 4)]


def test_slice_extracts_the_right_frame_range():
    src = _ramp_aiff(1000)
    out = slice_aiff(src, 100, 200, [])
    frames = _read_frames(out)
    assert len(frames) == 100
    assert frames[0] == (100, 100)
    assert frames[-1] == (199, 199)


def test_comm_frame_count_is_updated():
    out = slice_aiff(_ramp_aiff(1000), 100, 250, [])
    _, chunks = aiff_markers.parse_chunks(out)
    comm = dict(chunks)[b"COMM"]
    assert struct.unpack(">I", comm[2:6])[0] == 150


def test_markers_are_filtered_to_the_slice_and_rebased():
    src = _ramp_aiff(1000)
    markers = [Marker(1, 50, "a"), Marker(2, 150, "b"), Marker(3, 250, "c")]
    out = slice_aiff(src, 100, 300, markers)
    _, chunks = aiff_markers.parse_chunks(out)
    md = dict(chunks)[b"MARK"]
    count = struct.unpack(">H", md[0:2])[0]
    assert count == 2  # only b (150) and c (250) fall in [100,300)
    pos = 2
    got = []
    for _ in range(count):
        mid = struct.unpack(">h", md[pos : pos + 2])[0]
        p = struct.unpack(">I", md[pos + 2 : pos + 6])[0]
        nlen = md[pos + 6]
        name = md[pos + 7 : pos + 7 + nlen].decode()
        got.append((mid, p, name))
        adv = 6 + 1 + nlen
        adv += adv & 1
        pos += adv
    assert got == [(1, 50, "b"), (2, 150, "c")]  # rebased by -100, ids renumbered


def test_slice_clamps_out_of_range_bounds():
    out = slice_aiff(_ramp_aiff(100), 50, 5000, [])
    assert len(_read_frames(out)) == 50  # clamped to available frames


def test_slice_honors_nonzero_ssnd_offset():
    # With a non-zero SSND offset, the audio starts after the padding. The slicer
    # must skip it so frame 100 is still sample value 100, not padding.
    src = _ramp_aiff(1000, offset=8)
    out = slice_aiff(src, 100, 200, [])
    frames = _read_frames(out)
    assert len(frames) == 100
    assert frames[0] == (100, 100)
    assert frames[-1] == (199, 199)


def test_cut_markers_stay_distinct_through_the_slicer():
    # colliding timestamps must not stack in a slice (regression via build_markers)
    from logic_markers.cli import build_markers
    from logic_markers.transcribe import Word as W

    words = [W("a", 0.001), W("b", 0.001), W("c", 0.001)]
    markers = build_markers(words, 44100)
    out = slice_aiff(_ramp_aiff(1000), 0, 1000, markers)
    _, chunks = aiff_markers.parse_chunks(out)
    md = dict(chunks)[b"MARK"]
    count = struct.unpack(">H", md[0:2])[0]
    positions, pos = [], 2
    for _ in range(count):
        positions.append(struct.unpack(">I", md[pos + 2 : pos + 6])[0])
        nlen = md[pos + 6]
        adv = 6 + 1 + nlen
        adv += adv & 1
        pos += adv
    assert positions == sorted(positions)
    assert len(set(positions)) == len(positions)  # all distinct


def test_read_aiff_mono_downmixes_and_reports_rate():
    from logic_markers.audio import read_aiff_mono

    samples, sr = read_aiff_mono(_ramp_aiff(300, sr=44100))
    assert sr == 44100
    assert len(samples) == 300
    # frame i held (i, i) -> mono i -> float i/32768
    assert abs(samples[100] - 100 / 32768.0) < 1e-6
