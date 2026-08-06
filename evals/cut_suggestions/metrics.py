"""Cut-suggestion eval metrics (reported per product type).

Semantic recall@K vs shipped labels (via an aligner), duration-window
compliance, fragment rate, duplicate/overlap burden, candidates per hour. All
pure given an aligner; the aligner may or may not hit the network.
"""

from __future__ import annotations

from collections.abc import Callable

from cut_suggester.models import (
    CutCandidate,
    FRAGMENT_SECONDS,
    ProductSpec,
    ProductType,
)

Aligner = Callable[[list, list], dict]


def duration_window_compliance(
    candidates: list[CutCandidate], specs: dict[ProductType, ProductSpec]
) -> float:
    if not candidates:
        return 0.0
    ok = 0
    for c in candidates:
        spec = specs[c.product_type]
        if spec.target_min_sec <= c.duration_sec <= spec.target_max_sec:
            ok += 1
    return ok / len(candidates)


def fragment_rate(candidates: list[CutCandidate], threshold: float = FRAGMENT_SECONDS) -> float:
    if not candidates:
        return 0.0
    frags = sum(1 for c in candidates if c.duration_sec < threshold)
    return frags / len(candidates)


def overlap_burden(candidates: list[CutCandidate]) -> int:
    """Number of candidate pairs whose sentence spans overlap."""
    count = 0
    ordered = sorted(candidates, key=lambda c: (c.start_index, c.end_index))
    for i in range(len(ordered)):
        for j in range(i + 1, len(ordered)):
            if ordered[j].start_index > ordered[i].end_index:
                break  # sorted by start; no later candidate can overlap i
            count += 1
    return count


def candidates_per_hour(candidates: list[CutCandidate], total_seconds: float) -> float:
    if total_seconds <= 0:
        return 0.0
    return len(candidates) / (total_seconds / 3600.0)


def semantic_recall(proposed_labels: list[str], shipped_labels: list[str], aligner: Aligner) -> dict:
    """recall@K vs shipped labels via a semantic aligner."""
    if not shipped_labels:
        return {"recall": 0.0, "matched": 0, "shipped": 0, "matches": [], "missed": [], "extra": []}
    res = aligner(proposed_labels, shipped_labels)
    matched = [m for m in res.get("matches", []) if m.get("proposed")]
    return {
        "recall": len(matched) / len(shipped_labels),
        "matched": len(matched),
        "shipped": len(shipped_labels),
        "matches": res.get("matches", []),
        "missed": res.get("missed", []),
        "extra": res.get("extra", []),
    }
