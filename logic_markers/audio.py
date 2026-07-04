"""Audio conversion via the built-in macOS `afconvert` tool.

Always produces linear PCM AIFF (never compressed AIFC), which is the most
reliable container for Logic-readable marker chunks.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


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
