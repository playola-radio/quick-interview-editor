"""Byte-level AIFF marker writer.

This is the crux module: it reads an AIFF file, adds a `MARK` chunk carrying
word markers, and rewrites the outer `FORM` size so Logic Pro will ingest them
via Navigate > Other > Import Markers from Audio File.

Pure bytes-in / bytes-out. No audio libraries, no network. The exact chunk
layout proven here is what carries over to the eventual Swift app.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass


@dataclass(frozen=True)
class Marker:
    id: int          # positive, unique
    position: int    # sample frames from start of audio
    name: str        # label shown in Logic


def parse_chunks(data: bytes) -> tuple[bytes, list[tuple[bytes, bytes]]]:
    """Split an AIFF/AIFC FORM container into (formType, [(ckID, ckData), ...]).

    Chunk data excludes the pad byte that follows an odd-length chunk.
    """
    if data[0:4] != b"FORM":
        raise ValueError("not an AIFF file: missing FORM header")
    form_size = struct.unpack(">I", data[4:8])[0]
    form_type = data[8:12]
    if form_type not in (b"AIFF", b"AIFC"):
        raise ValueError(f"unexpected form type: {form_type!r}")

    chunks: list[tuple[bytes, bytes]] = []
    pos = 12
    end = min(len(data), 8 + form_size)
    while pos + 8 <= end:
        ck_id = data[pos : pos + 4]
        ck_size = struct.unpack(">I", data[pos + 4 : pos + 8])[0]
        ck_data = data[pos + 8 : pos + 8 + ck_size]
        chunks.append((ck_id, ck_data))
        pos += 8 + ck_size + (ck_size & 1)  # skip pad byte on odd size
    return form_type, chunks


def build_form(form_type: bytes, chunks: list[tuple[bytes, bytes]]) -> bytes:
    """Reassemble a FORM container, padding odd chunks and fixing FORM size."""
    body = bytearray(form_type)
    for ck_id, ck_data in chunks:
        body += ck_id
        body += struct.pack(">I", len(ck_data))
        body += ck_data
        if len(ck_data) & 1:
            body += b"\x00"
    return b"FORM" + struct.pack(">I", len(body)) + bytes(body)


def _sanitize(name: str) -> bytes:
    """ASCII-sanitize and clamp to a 255-byte Pascal string payload."""
    ascii_bytes = name.encode("ascii", "replace")
    return ascii_bytes[:255]


def build_mark_chunk(markers: list[Marker]) -> bytes:
    """Build the raw `MARK` chunk data (not including the 8-byte chunk header).

    Layout: uint16 count, then per marker: int16 id, uint32 position,
    even-padded Pascal string name.
    """
    if len(markers) > 0xFFFF:
        raise ValueError(f"too many markers for a MARK chunk: {len(markers)} > 65535")
    out = bytearray(struct.pack(">H", len(markers)))
    for m in markers:
        name = _sanitize(m.name)
        pstr = bytes([len(name)]) + name
        if len(pstr) & 1:
            pstr += b"\x00"  # pad Pascal string to even length
        out += struct.pack(">h", m.id)
        out += struct.pack(">I", m.position)
        out += pstr
    return bytes(out)


def read_frame_count(data: bytes) -> int:
    """Return numSampleFrames from the AIFF COMM chunk."""
    _, chunks = parse_chunks(data)
    for ck_id, ck_data in chunks:
        if ck_id == b"COMM":
            return struct.unpack(">I", ck_data[2:6])[0]
    raise ValueError("no COMM chunk found; not a valid AIFF")


def read_sample_rate(data: bytes) -> int:
    """Read the sample rate (Hz) from the COMM chunk's 80-bit extended float."""
    _, chunks = parse_chunks(data)
    for ck_id, ck_data in chunks:
        if ck_id == b"COMM":
            # channels(2) numSampleFrames(4) sampleSize(2) sampleRate(10-byte ext80)
            ext80 = ck_data[8:18]
            return round(_extended80_to_float(ext80))
    raise ValueError("no COMM chunk found; not a valid AIFF")


def _extended80_to_float(b: bytes) -> float:
    sign = -1.0 if (b[0] & 0x80) else 1.0
    exponent = ((b[0] & 0x7F) << 8) | b[1]
    mantissa = int.from_bytes(b[2:10], "big")
    if exponent == 0 and mantissa == 0:
        return 0.0
    exponent -= 16383
    return sign * mantissa * (2.0 ** (exponent - 63))


def add_markers(aiff_bytes: bytes, markers: list[Marker]) -> bytes:
    """Return a new AIFF with a MARK chunk appended and FORM size rewritten."""
    form_type, chunks = parse_chunks(aiff_bytes)
    chunks = [c for c in chunks if c[0] != b"MARK"]  # replace any existing
    chunks.append((b"MARK", build_mark_chunk(markers)))
    return build_form(form_type, chunks)
