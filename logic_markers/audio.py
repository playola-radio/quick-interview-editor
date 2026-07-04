"""Audio conversion via the built-in macOS `afconvert` tool.

Always produces linear PCM AIFF (never compressed AIFC), which is the most
reliable container for Logic-readable marker chunks.
"""

from __future__ import annotations

import struct
import subprocess
from pathlib import Path

from . import aiff_markers


def convert_to_aiff(source: Path, dest: Path, sample_rate: int = 44100) -> Path:
    """Convert any afconvert-readable audio file to linear PCM AIFF.

    `BEI16@<rate>` forces big-endian signed 16-bit PCM at the given rate, which
    is standard AIFF and avoids afconvert emitting a compressed AIFC file.
    """
    cmd = [
        "afconvert",
        "-f", "AIFF",
        "-d", f"BEI16@{sample_rate}",
        str(source),
        str(dest),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"afconvert failed ({result.returncode}): {result.stderr.strip()}"
        )
    if not dest.exists():
        raise RuntimeError("afconvert reported success but produced no output file")
    return dest


def read_aiff_mono(aiff_bytes: bytes):
    """Decode a 16-bit AIFF's PCM to a mono float32 array (for silence analysis).

    Analysis happens at the AIFF's own sample rate so silence positions map
    directly to cut positions. Returns (samples, sample_rate).
    """
    import numpy as np

    _, chunks = aiff_markers.parse_chunks(aiff_bytes)
    by_id = dict(chunks)
    comm = by_id[b"COMM"]
    channels = struct.unpack(">h", comm[0:2])[0]
    sample_size = struct.unpack(">h", comm[6:8])[0]
    if sample_size != 16:
        raise ValueError(f"expected 16-bit AIFF, got {sample_size}-bit")
    sr = aiff_markers.read_sample_rate(aiff_bytes)

    audio = by_id[b"SSND"][8:]  # skip offset + blockSize
    data = np.frombuffer(audio, dtype=">i2").astype(np.float32) / 32768.0
    if channels > 1:
        data = data.reshape(-1, channels).mean(axis=1)
    return data, sr
