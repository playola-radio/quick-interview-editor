"""Sample-accurate AIFF slicing with markers re-based to each slice.

Reuses the original COMM chunk (only rewriting the frame count) so the slice
keeps the exact sample rate / channels / bit depth of the source, then rebuilds
SSND from the extracted audio bytes and a fresh MARK chunk.
"""

from __future__ import annotations

import struct

from . import aiff_markers
from .aiff_markers import Marker


def slice_aiff(
    aiff_bytes: bytes,
    start_sample: int,
    end_sample: int,
    markers: list[Marker],
) -> bytes:
    form_type, chunks = aiff_markers.parse_chunks(aiff_bytes)
    by_id = dict(chunks)
    comm = by_id[b"COMM"]
    ssnd = by_id[b"SSND"]

    channels = struct.unpack(">h", comm[0:2])[0]
    sample_size = struct.unpack(">h", comm[6:8])[0]
    bytes_per_frame = channels * (sample_size // 8)

    audio = ssnd[8:]  # skip SSND offset + blockSize
    total_frames = len(audio) // bytes_per_frame

    start = max(0, min(start_sample, total_frames))
    end = max(start, min(end_sample, total_frames))
    sliced = audio[start * bytes_per_frame : end * bytes_per_frame]
    num_frames = end - start

    new_comm = comm[:2] + struct.pack(">I", num_frames) + comm[6:]
    new_ssnd = struct.pack(">I", 0) + struct.pack(">I", 0) + sliced

    rebased = [
        Marker(id=0, position=m.position - start, name=m.name)
        for m in markers
        if start <= m.position < end
    ]
    rebased = [Marker(id=i + 1, position=m.position, name=m.name) for i, m in enumerate(rebased)]
    mark = aiff_markers.build_mark_chunk(rebased)

    return aiff_markers.build_form(
        form_type, [(b"COMM", new_comm), (b"SSND", new_ssnd), (b"MARK", mark)]
    )
