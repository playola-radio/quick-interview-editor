"""Tests for the byte-level AIFF marker writer.

Builds a synthetic linear-PCM AIFF in memory, adds markers, and re-parses to
assert the MARK chunk, positions, names, padding, and FORM size are correct.
"""

import struct

from logic_markers.aiff_markers import (
    Marker,
    add_markers,
    build_mark_chunk,
    parse_chunks,
    read_frame_count,
    read_sample_rate,
    read_ssnd_frame_count,
)


def _float_to_extended80(value: float) -> bytes:
    """Minimal encoder for the 80-bit extended used by COMM (positive ints)."""
    if value == 0:
        return b"\x00" * 10
    exponent = 16383 + 63  # bias + integer-bit position (MSB at bit 63)
    mantissa = value
    while mantissa < (1 << 63):
        mantissa *= 2
        exponent -= 1
    while mantissa >= (1 << 64):
        mantissa //= 2
        exponent += 1
    return struct.pack(">H", exponent) + struct.pack(">Q", int(mantissa))


def _synthetic_aiff(sample_rate: int = 44100, frames: int = 1000, offset: int = 0) -> bytes:
    comm = (
        struct.pack(">h", 2)                        # channels
        + struct.pack(">I", frames)                 # numSampleFrames
        + struct.pack(">h", 16)                     # sampleSize
        + _float_to_extended80(sample_rate)         # sampleRate (ext80)
    )
    audio = b"\x00" * (frames * 2 * 2)              # stereo 16-bit
    # offset, blockSize, then `offset` bytes of alignment padding before the audio.
    ssnd = struct.pack(">I", offset) + struct.pack(">I", 0) + b"\x00" * offset + audio
    body = b"AIFF"
    for ck_id, ck_data in ((b"COMM", comm), (b"SSND", ssnd)):
        body += ck_id + struct.pack(">I", len(ck_data)) + ck_data
        if len(ck_data) & 1:
            body += b"\x00"
    return b"FORM" + struct.pack(">I", len(body)) + body


def test_read_sample_rate():
    assert read_sample_rate(_synthetic_aiff(sample_rate=48000)) == 48000


def test_ssnd_frame_count_matches_comm_for_intact_file():
    assert read_ssnd_frame_count(_synthetic_aiff(frames=1000)) == 1000
    assert read_frame_count(_synthetic_aiff(frames=1000)) == 1000


def test_ssnd_frame_count_excludes_nonzero_offset_padding():
    # A valid AIFF may use a non-zero SSND offset (alignment padding before the
    # audio). That padding must NOT be counted as sample data, else an intact file
    # would look longer than its COMM and be wrongly rejected on render.
    aiff = _synthetic_aiff(frames=1000, offset=8)
    assert read_frame_count(aiff) == 1000
    assert read_ssnd_frame_count(aiff) == 1000


def test_ssnd_frame_count_detects_truncated_audio():
    # Drop the last 100 stereo-16-bit frames (400 bytes) from SSND while leaving COMM
    # untouched: the real audio is now shorter than COMM declares.
    form_type, chunks = parse_chunks(_synthetic_aiff(frames=1000))
    truncated = [
        (cid, data[:-400] if cid == b"SSND" else data) for cid, data in chunks
    ]
    body = form_type
    for cid, data in truncated:
        body += cid + struct.pack(">I", len(data)) + data
        if len(data) & 1:
            body += b"\x00"
    aiff = b"FORM" + struct.pack(">I", len(body)) + body
    assert read_frame_count(aiff) == 1000
    assert read_ssnd_frame_count(aiff) == 900


def test_form_size_is_rewritten_correctly():
    src = _synthetic_aiff()
    out = add_markers(src, [Marker(1, 100, "hello"), Marker(2, 200, "world")])
    declared = struct.unpack(">I", out[4:8])[0]
    assert declared == len(out) - 8  # FORM size covers everything after header


def test_mark_chunk_present_and_parseable():
    src = _synthetic_aiff()
    markers = [Marker(1, 4410, "I"), Marker(2, 8820, "been")]
    out = add_markers(src, markers)
    _, chunks = parse_chunks(out)
    ids = [ck_id for ck_id, _ in chunks]
    assert b"MARK" in ids
    assert ids == [b"COMM", b"SSND", b"MARK"]  # appended after existing chunks

    mark_data = dict(chunks)[b"MARK"]
    count = struct.unpack(">H", mark_data[0:2])[0]
    assert count == 2
    pos = 2
    parsed = []
    for _ in range(count):
        mid = struct.unpack(">h", mark_data[pos : pos + 2])[0]
        position = struct.unpack(">I", mark_data[pos + 2 : pos + 6])[0]
        nlen = mark_data[pos + 6]
        name = mark_data[pos + 7 : pos + 7 + nlen].decode("ascii")
        parsed.append((mid, position, name))
        advance = 6 + 1 + nlen
        advance += advance & 1  # pstring even padding (6 is even; count parity from 1+nlen)
        pos += advance
    assert parsed == [(1, 4410, "I"), (2, 8820, "been")]


def test_pstring_even_padding():
    # name length 2 -> pstring is 1+2=3 bytes -> needs 1 pad byte -> even total
    data = build_mark_chunk([Marker(1, 0, "hi")])
    # count(2) + id(2) + pos(4) + pstr(1+2=3 -> padded to 4) = 12, even
    assert len(data) == 12


def test_replacing_existing_markers_does_not_duplicate():
    src = _synthetic_aiff()
    once = add_markers(src, [Marker(1, 100, "a")])
    twice = add_markers(once, [Marker(1, 100, "a"), Marker(2, 200, "b")])
    _, chunks = parse_chunks(twice)
    assert [ck_id for ck_id, _ in chunks].count(b"MARK") == 1
    mark_data = dict(chunks)[b"MARK"]
    assert struct.unpack(">H", mark_data[0:2])[0] == 2


def test_too_many_markers_raises():
    import pytest

    with pytest.raises(ValueError):
        build_mark_chunk([Marker(i + 1, i, "x") for i in range(65536)])
