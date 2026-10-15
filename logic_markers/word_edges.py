"""Refine WhisperX word edges against the audio's own energy envelope.

CTC alignment edges are loose: next to pauses, ends run early and starts late;
in connected speech the true boundary is the nearby energy valley. The edit plan
cuts exactly `start..end`, so we move each edge to where the signal actually
goes quiet. Every refined boundary is clamped to lie between the two words'
midpoints, so words keep `start < end` and never cross, whatever the alignment.
"""

from __future__ import annotations

from dataclasses import replace

import numpy as np

from .silence import _rms_db_envelope, adaptive_threshold_db
from .words import Word

HOP_MS = 5
WINDOW_MS = 10
SMOOTH_MS = 15
MIN_QUIET_MS = 60
EDGE_LOOKBACK_MS = 30
PAD_MS = 10
VALLEY_RADIUS_MS = 80
PROMINENCE_DB = 3.0
OUTER_SEARCH_MS = 300


class _Envelope:
    def __init__(self, samples, sr: int):
        self.db, self.hop, self.win = _rms_db_envelope(
            samples, sr, WINDOW_MS, HOP_MS, SMOOTH_MS
        )
        self.quiet = self.db < adaptive_threshold_db(samples, sr)
        self.total = len(samples)
        self.min_quiet = self._ms(MIN_QUIET_MS, sr)
        self.lookback = self._ms(EDGE_LOOKBACK_MS, sr)
        self.pad = self._ms(PAD_MS, sr)
        self.valley_radius = self._ms(VALLEY_RADIUS_MS, sr)
        self.outer = self._ms(OUTER_SEARCH_MS, sr)

    @staticmethod
    def _ms(ms: float, sr: int) -> int:
        return int(sr * ms / 1000)

    def center(self, frame: int) -> int:
        return frame * self.hop + self.win // 2

    def quiet_runs(
        self, lo: int, hi: int, near_lo: int, near_hi: int
    ) -> list[tuple[int, int]]:
        """(start, end) samples of quiet runs lying fully inside [lo, hi] that reach into
        [near_lo, near_hi], so a run is measured whole even when it starts outside the
        search window."""
        first = max(0, -(-lo // self.hop))
        last = min(len(self.quiet) - 1, (hi - self.win) // self.hop)
        runs = []
        f = first
        while f <= last:
            if not self.quiet[f]:
                f += 1
                continue
            g = f
            while g <= last and self.quiet[g]:
                g += 1
            start, end = f * self.hop, (g - 1) * self.hop + self.win
            if end - start >= self.min_quiet and start <= near_hi and end >= near_lo:
                runs.append((start, end))
            f = g
        return runs

    def valley_boundary(self, lo: int, hi: int, fallback: int) -> int:
        first = max(0, -(-(lo - self.win // 2) // self.hop))
        last = min(len(self.db) - 1, (hi - self.win // 2) // self.hop)
        if first > last:
            return fallback
        window = self.db[first : last + 1]
        lowest = window.min()
        candidates = np.flatnonzero(window <= lowest + 1e-9) + first
        v = int(min(candidates, key=lambda f: abs(self.center(f) - fallback)))
        left = self.db[first : v + 1].max()
        right = self.db[v : last + 1].max()
        if min(left, right) - self.db[v] >= PROMINENCE_DB:
            return self.center(v)
        return fallback


def _clamp(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, value))


def _pair_edges(env: _Envelope, e_a: int, s_b: int, m_a: int, m_b: int) -> tuple[int, int]:
    runs = env.quiet_runs(m_a, m_b, e_a - env.lookback, s_b + env.lookback)
    if runs:
        end_a = runs[0][0] + env.pad
        start_b = runs[-1][1] - env.pad
    else:
        c = (e_a + s_b) // 2
        lo, hi = max(m_a, c - env.valley_radius), min(m_b, c + env.valley_radius)
        end_a = start_b = env.valley_boundary(lo, hi, c)

    end_a = _clamp(end_a, m_a + 1, m_b)
    start_b = _clamp(start_b, m_a + 1, m_b)
    if end_a > start_b:
        end_a = start_b = (end_a + start_b) // 2
    return end_a, start_b


def _first_start(env: _Envelope, s: int, m: int) -> int:
    runs = env.quiet_runs(max(0, s - env.outer), m, 0, s + env.lookback)
    if not runs:
        return s
    return _clamp(runs[-1][1] - env.pad, 0, m)


def _last_end(env: _Envelope, e: int, m: int) -> int:
    runs = env.quiet_runs(m, min(env.total, e + env.outer), e - env.lookback, env.total)
    if not runs:
        return e
    return _clamp(runs[0][0] + env.pad, m + 1, env.total)


def refine_word_edges(words: tuple[Word, ...], samples, sr: int) -> tuple[Word, ...]:
    if not words or len(samples) == 0:
        return words

    env = _Envelope(samples, sr)
    n = len(words)
    starts = [round(w.start * sr) for w in words]
    ends = [None if w.end is None else round(w.end * sr) for w in words]
    valid = [e is not None and e > s for s, e in zip(starts, ends)]
    mids = [(s + e) // 2 if ok else 0 for s, e, ok in zip(starts, ends, valid)]

    new_starts, new_ends = list(starts), list(ends)
    for i in range(n - 1):
        if valid[i] and valid[i + 1] and mids[i + 1] > mids[i]:
            new_ends[i], new_starts[i + 1] = _pair_edges(
                env, ends[i], starts[i + 1], mids[i], mids[i + 1]
            )
    if valid[0]:
        new_starts[0] = _first_start(env, starts[0], mids[0])
    if valid[-1]:
        new_ends[-1] = _last_end(env, ends[-1], mids[-1])

    refined = []
    for i, w in enumerate(words):
        if valid[i]:
            start = w.start if new_starts[i] == starts[i] else new_starts[i] / sr
            end = w.end if new_ends[i] == ends[i] else new_ends[i] / sr
            w = replace(w, start=start, end=end)
        refined.append(w)
    return tuple(refined)
