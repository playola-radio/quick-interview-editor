"""Stitch overlapping-window stage-1 partitions into one clean cover.

Each window independently partitions its slice into topic paragraphs. Because
windows overlap, an interior boundary in the overlap region is voted by more
than one window (reinforcing it), while a boundary forced at a window's own
start is a seam artifact — we ignore each window's first paragraph start, so
those never become cuts unless a genuine vote lands there too. The final cover
is contiguous with no gaps or overlaps; each paragraph takes the label of the
window paragraph that best covers it.
"""

from __future__ import annotations

from .models import TopicPartition


def _merge_votes(votes: list[int], tolerance: int, lo: int, hi: int) -> list[int]:
    """Cluster nearby boundary votes into single boundaries within [lo, hi].

    A run of votes each within `tolerance` of the previous vote is one cluster
    (transitively): [10, 11, 12] with tolerance 1 collapses to a single
    boundary, not [10, 12]. The cluster's first vote represents it.
    """
    picked = sorted(v for v in votes if lo <= v <= hi)
    out: list[int] = []
    prev: int | None = None
    for v in picked:
        if prev is not None and v - prev <= tolerance:
            prev = v  # extend the current cluster
            continue
        out.append(v)  # start a new cluster; its first vote is the boundary
        prev = v
    return out


def _best_label(window_partitions: list[list[TopicPartition]], start: int, end: int) -> str:
    best_label = ""
    best_overlap = -1
    for window in window_partitions:
        for p in window:
            overlap = max(0, min(end, p.end) - max(start, p.start) + 1)
            if overlap > best_overlap:
                best_overlap = overlap
                best_label = p.label
    return best_label


def stitch_partitions(
    window_partitions: list[list[TopicPartition]],
    n: int,
    boundary_tolerance: int = 1,
) -> list[TopicPartition]:
    votes: list[int] = []
    for window in window_partitions:
        ordered = sorted(window, key=lambda p: p.start)
        for p in ordered[1:]:  # skip each window's forced first-paragraph start
            votes.append(p.start)

    boundaries = _merge_votes(votes, boundary_tolerance, lo=1, hi=n - 1)
    cuts = [0, *boundaries, n]

    out: list[TopicPartition] = []
    for a, b in zip(cuts, cuts[1:]):
        if b <= a:
            continue
        out.append(TopicPartition(a, b - 1, _best_label(window_partitions, a, b - 1)))
    return out
