"""Silence detection for boundary snapping.

Spoken-word levels vary too much for a fixed dB gate, so the threshold is
derived from the file's own noise floor. Analysis runs on a mono signal at the
same sample rate the audio is cut at, so region samples map directly to cut
positions.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class Silence:
    start: int  # sample index (inclusive)
    end: int    # sample index (exclusive)

    @property
    def duration(self) -> int:
        return self.end - self.start


def _rms_db_envelope(samples, sr, window_ms, hop_ms, smooth_ms):
    w = max(1, int(sr * window_ms / 1000))
    h = max(1, int(sr * hop_ms / 1000))
    n = len(samples)
    starts = np.arange(0, max(1, n - w + 1), h)
    rms = np.empty(len(starts), dtype=np.float64)
    for k, i in enumerate(starts):
        frame = samples[i : i + w]
        rms[k] = np.sqrt(np.mean(frame.astype(np.float64) ** 2)) if len(frame) else 0.0
    db = 20.0 * np.log10(np.maximum(rms, 1e-10))

    smooth_frames = max(1, int(smooth_ms / hop_ms))
    if smooth_frames > 1 and len(db) >= smooth_frames:
        kernel = np.ones(smooth_frames) / smooth_frames
        db = np.convolve(db, kernel, mode="same")
    return db, h, w


def adaptive_threshold_db(
    samples,
    sr,
    *,
    window_ms: float = 25.0,
    hop_ms: float = 10.0,
    smooth_ms: float = 50.0,
    floor_percentile: float = 20.0,
    margin_db: float = 8.0,
    clamp_db: tuple[float, float] = (-60.0, -30.0),
) -> float:
    db, _, _ = _rms_db_envelope(samples, sr, window_ms, hop_ms, smooth_ms)
    noise_floor = float(np.percentile(db, floor_percentile))
    threshold = noise_floor + margin_db
    lo, hi = clamp_db
    return float(min(max(threshold, lo), hi))


def detect_silences(
    samples,
    sr,
    *,
    window_ms: float = 25.0,
    hop_ms: float = 10.0,
    smooth_ms: float = 50.0,
    min_silence_ms: float = 120.0,
    floor_percentile: float = 20.0,
    margin_db: float = 8.0,
    clamp_db: tuple[float, float] = (-60.0, -30.0),
) -> list[Silence]:
    samples = np.asarray(samples)
    if samples.size == 0:
        return []

    db, hop, win = _rms_db_envelope(samples, sr, window_ms, hop_ms, smooth_ms)
    threshold = adaptive_threshold_db(
        samples, sr, window_ms=window_ms, hop_ms=hop_ms, smooth_ms=smooth_ms,
        floor_percentile=floor_percentile, margin_db=margin_db, clamp_db=clamp_db,
    )
    silent = db < threshold

    min_samples = int(sr * min_silence_ms / 1000)
    regions: list[Silence] = []
    f = 0
    n = len(silent)
    while f < n:
        if not silent[f]:
            f += 1
            continue
        g = f
        while g < n and silent[g]:
            g += 1
        start = f * hop
        end = min(len(samples), (g - 1) * hop + win)
        if end - start >= min_samples:
            regions.append(Silence(start=start, end=end))
        f = g
    return regions
