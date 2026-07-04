"""Snap a content span outward to the nearest silence, never clipping a word.

Given a block's content span (seconds) and the file's silence regions (samples),
resolve the actual slice boundaries. Start snaps to the END of the nearest
leading silence (minimal dead air); end snaps to the START of the nearest
trailing silence. When no silence is near, pad outward instead of inventing one.
"""

from __future__ import annotations

from dataclasses import dataclass

from .silence import Silence


@dataclass(frozen=True)
class Boundaries:
    start_sample: int
    end_sample: int
    start_status: str  # 'snapped' | 'padded'
    end_status: str


def snap_boundaries(
    content_start_sec: float,
    content_end_sec: float,
    silences: list[Silence],
    sr: int,
    total_samples: int,
    *,
    search_radius_ms: float = 800.0,
    roll_ms: float = 20.0,
    pad_ms: float = 100.0,
    limit_start_sample: int | None = None,
    limit_end_sample: int | None = None,
) -> Boundaries:
    cs = round(content_start_sec * sr)
    ce = round(content_end_sec * sr)
    radius = int(sr * search_radius_ms / 1000)
    roll = int(sr * roll_ms / 1000)
    pad = int(sr * pad_ms / 1000)

    # Neighbors bound the search so adjacent kept chunks don't steal each
    # other's words: never reach before the previous chunk's content end, nor
    # past the next chunk's content start.
    lo = 0 if limit_start_sample is None else max(0, limit_start_sample)
    hi = total_samples if limit_end_sample is None else min(total_samples, limit_end_sample)
    # A neighbor whose timestamp overlaps the kept word must never push the
    # limit into the word itself (that would clip it).
    lo = min(lo, cs)
    hi = max(hi, ce)

    # ---- start: nearest silence that begins at/before the first word ----
    leading = [s for s in silences if s.start < cs and s.end > lo]
    start_status = "padded"
    start_sample = max(lo, cs - pad)
    if leading:
        s = max(leading, key=lambda r: r.end)  # latest-ending -> closest to word
        if cs - s.end <= radius:
            start_sample = min(max(s.end - roll, s.start, lo), cs)
            start_status = "snapped"

    # ---- end: nearest silence that extends past the last word ----
    trailing = [s for s in silences if s.end > ce and s.start < hi]
    end_status = "padded"
    end_sample = min(hi, ce + pad)
    if trailing:
        s = min(trailing, key=lambda r: r.start)  # earliest-starting -> closest
        if s.start - ce <= radius:
            end_sample = max(min(s.start + roll, s.end, hi), ce)
            end_status = "snapped"

    start_sample = max(lo, min(start_sample, cs))
    end_sample = min(hi, max(end_sample, ce))
    return Boundaries(
        start_sample=start_sample,
        end_sample=end_sample,
        start_status=start_status,
        end_status=end_status,
    )
