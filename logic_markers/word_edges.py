"""Refine WhisperX word edges against the audio's own energy envelope.

CTC alignment edges are loose: next to pauses, ends run early and starts late;
in connected speech we choose the nearest local energy minimum with enough
prominence, rather than a deeper valley inside the neighbouring word. The edit plan
cuts exactly `start..end`, so we move each edge to where the signal actually
goes quiet. At a pause an edge only ever grows outward, across its word's sound
until it goes quiet or dips into a different sound: cutting extra silence is
harmless, cutting a quiet consonant or a neighbouring sound is the bug. Every refined
boundary is clamped to lie between the two words' midpoints, so words keep
`start < end` and never cross, whatever the alignment.
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
PAD_MS = 10
VALLEY_RADIUS_MS = 80
PROMINENCE_DB = 3.0
DIP_DB = 6.0
OUTER_SEARCH_MS = 300


class _Envelope:
    def __init__(self, samples, sr: int):
        self.db, self.hop, self.win = _rms_db_envelope(
            samples, sr, WINDOW_MS, HOP_MS, SMOOTH_MS
        )
        self.quiet = self.db < adaptive_threshold_db(samples, sr)
        self.total = len(samples)
        self.min_quiet = self._ms(MIN_QUIET_MS, sr)
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
        [near_lo, near_hi]."""
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

    def grow_end(self, e: int, limit: int, anchor: int) -> int:
        """Grow an end forward across its word's sound: stop at the first quiet frame (plus pad),
        or sooner at a dip that marks the start of a different sound. Never before `e`."""
        f0 = -(-e // self.hop)
        stop = f0
        while stop * self.hop < limit and stop < len(self.quiet) and not self.quiet[stop]:
            stop += 1
        dip = self._first_dip(range(f0, stop), self.db[anchor // self.hop : f0])
        edge = self.center(dip) if dip is not None else min(stop * self.hop, limit) + self.pad
        return max(e, edge)

    def grow_start(self, s: int, limit: int, anchor: int) -> int:
        """Mirror of `grow_end`: grow a start backward. Never after `s`."""
        g0 = min(len(self.quiet) - 1, (s - self.win) // self.hop)
        stop = g0
        while stop >= 0 and stop * self.hop + self.win > limit and not self.quiet[stop]:
            stop -= 1
        dip = self._first_dip(range(g0, stop, -1), self.db[g0 + 1 : anchor // self.hop + 1])
        if dip is not None:
            edge = self.center(dip)
        else:
            edge = max(stop * self.hop + self.win, limit) - self.pad
        return min(s, edge)

    def _first_dip(self, frames: range, behind) -> int | None:
        """First frame along `frames` lying DIP_DB below both the louder sound behind it
        (`behind`, then the frames already walked) and the sound still ahead; slid to the
        dip's floor."""
        near = behind.max() if len(behind) else -np.inf
        walked = list(frames)
        ahead_max = np.maximum.accumulate(self.db[walked][::-1])[::-1]
        for k, v in enumerate(walked):
            if (k + 1 < len(walked) and near - self.db[v] >= DIP_DB
                    and ahead_max[k + 1] - self.db[v] >= DIP_DB):
                while k + 1 < len(walked) and self.db[walked[k + 1]] <= self.db[walked[k]]:
                    k += 1
                return walked[k]
            near = max(near, self.db[v])
        return None

    def valley_boundary(self, lo: int, hi: int, fallback: int) -> int:
        first = max(0, -(-(lo - self.win // 2) // self.hop))
        last = min(len(self.db) - 1, (hi - self.win // 2) // self.hop)
        if first > last:
            return fallback
        window = self.db[first : last + 1]
        left = np.maximum.accumulate(window)
        right = np.maximum.accumulate(window[::-1])[::-1]
        local_min = np.zeros(len(window), dtype=bool)
        local_min[1:-1] = (window[1:-1] <= window[:-2]) & (window[1:-1] <= window[2:])
        candidates = np.flatnonzero(
            local_min & (np.minimum(left, right) - window >= PROMINENCE_DB)
        ) + first
        if not len(candidates):
            return fallback
        v = int(min(candidates, key=lambda f: abs(self.center(f) - fallback)))
        return self.center(v)


def _clamp(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, value))


def _pair_edges(env: _Envelope, e_a: int, s_b: int, m_a: int, m_b: int) -> tuple[int, int]:
    runs = env.quiet_runs(m_a, m_b, min(e_a, s_b), max(e_a, s_b))
    if runs:
        end_a = env.grow_end(e_a, runs[0][0], m_a)
        start_b = env.grow_start(s_b, runs[-1][1], m_b)
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
    runs = env.quiet_runs(max(0, s - env.outer), m, 0, s)
    if not runs:
        return s
    return _clamp(env.grow_start(s, runs[-1][1], m), 0, m)


def _last_end(env: _Envelope, e: int, m: int) -> int:
    runs = env.quiet_runs(m, min(env.total, e + env.outer), e, env.total)
    if not runs:
        return e
    return _clamp(env.grow_end(e, runs[0][0], m), m + 1, env.total)


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
