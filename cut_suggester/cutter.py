"""Two-stage, paragraph-first cutter.

Stage 1: overlapping windowed partition of the transcript into topic paragraphs,
stitched into one contiguous cover. Stage 2: classify the paragraph inventory
into product clips (trim/merge). Then pure post-processing turns clips into
ranked, validated candidates. The LLM client is injected.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import dataclass, field

from .config import DEFAULT_SAMPLE_RATE, STAGE1_STEP, STAGE1_WINDOW
from .llm import LLMClient
from .models import CutCandidate, DEFAULT_SPECS, ProductSpec, ProductType, Sentence, TopicPartition
from .postprocess import (
    build_candidate,
    dedupe_overlapping,
    enforce_duration_window,
    merge_adjacent_same_label,
    rank_candidates,
    validate_clip,
)
from .prompts import partition_prompt, stage2_prompt
from .stitch import stitch_partitions


@dataclass
class CutSuggestResult:
    candidates: list[CutCandidate]
    partitions: list[TopicPartition]
    dropped: list[CutCandidate]
    meta: dict = field(default_factory=dict)


# A progress sink: `progress(phase="partitioning", message="…", index=1, total=5)`.
# Keyword-only so callers can add fields without breaking older sinks. Optional
# everywhere (default no-op), so the eval and unit tests stay unchanged.
ProgressFn = Callable[..., None]


def _noop_progress(**_kwargs) -> None:
    pass


def parse_partition_response(text: str, a: int, b: int) -> list[TopicPartition]:
    """Parse a window's paragraph JSON, clamping spans into [a, b)."""
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return []  # malformed provider/cache output -> no partitions
    paras = data.get("paragraphs") if isinstance(data, dict) else None
    if not isinstance(paras, list):
        return []
    out: list[TopicPartition] = []
    for p in paras:
        if not isinstance(p, dict):
            continue
        try:
            start = int(p["start"])
            end = int(p["end"])
        except (KeyError, TypeError, ValueError):
            continue
        start = max(a, min(start, b - 1))
        end = max(start, min(end, b - 1))
        out.append(TopicPartition(start, end, str(p.get("label", "")).strip()))
    return out


def parse_clip_response(text: str) -> list[dict]:
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return []  # malformed provider/cache output -> no clips
    clips = data.get("clips") if isinstance(data, dict) else None
    if not isinstance(clips, list):
        return []
    return [c for c in clips if isinstance(c, dict)]


def stage1_partition(
    sentences: list[Sentence],
    llm: LLMClient,
    *,
    window: int = STAGE1_WINDOW,
    step: int = STAGE1_STEP,
    progress: ProgressFn = _noop_progress,
) -> list[TopicPartition]:
    n = len(sentences)
    starts = list(range(0, n, step))
    total = len(starts)
    window_partitions: list[list[TopicPartition]] = []
    for i, a in enumerate(starts):
        b = min(a + window, n)
        progress(
            phase="partitioning",
            message=f"Reading section {i + 1} of {total}",
            index=i + 1,
            total=total,
        )
        resp = llm.complete(partition_prompt(sentences, a, b), purpose=f"partition:{a}")
        window_partitions.append(parse_partition_response(resp.text, a, b))
        if b >= n:
            break
    return stitch_partitions(window_partitions, n)


def stage2_classify(
    sentences: list[Sentence],
    partitions: list[TopicPartition],
    llm: LLMClient,
    specs: dict[ProductType, ProductSpec],
) -> list[dict]:
    resp = llm.complete(stage2_prompt(sentences, partitions, specs), purpose="classify")
    return parse_clip_response(resp.text)


def suggest_cuts(
    sentences: list[Sentence],
    llm: LLMClient,
    *,
    specs: dict[ProductType, ProductSpec] | None = None,
    sample_rate: int = DEFAULT_SAMPLE_RATE,
    window: int = STAGE1_WINDOW,
    step: int = STAGE1_STEP,
    progress: ProgressFn = _noop_progress,
) -> CutSuggestResult:
    specs = specs or DEFAULT_SPECS

    if not sentences:
        return CutSuggestResult(candidates=[], partitions=[], dropped=[], meta={
            "n_sentences": 0, "n_partitions": 0, "n_raw_clips": 0,
            "n_invalid_clips": 0, "n_dropped_duration": 0,
        })

    progress(phase="started", message="Analyzing transcript")
    partitions = stage1_partition(sentences, llm, window=window, step=step, progress=progress)
    progress(phase="classifying", message="Selecting product clips")
    raw_clips = stage2_classify(sentences, partitions, llm, specs)

    progress(phase="postprocessing", message="Building candidates")
    candidates: list[CutCandidate] = []
    invalid = 0
    for raw in raw_clips:
        ok, _reason = validate_clip(raw)
        if not ok:
            invalid += 1
            continue
        candidates.append(build_candidate(sentences, raw, specs, sample_rate))

    candidates = merge_adjacent_same_label(candidates, sentences, specs, sample_rate)
    candidates, dropped = enforce_duration_window(candidates, specs)
    candidates = dedupe_overlapping(candidates)
    candidates = rank_candidates(candidates, specs)

    progress(
        phase="completed",
        message=f"{len(candidates)} candidate(s)",
        n_candidates=len(candidates),
    )
    meta = {
        "n_sentences": len(sentences),
        "n_partitions": len(partitions),
        "n_raw_clips": len(raw_clips),
        "n_invalid_clips": invalid,
        "n_dropped_duration": len(dropped),
    }
    return CutSuggestResult(candidates=candidates, partitions=partitions, dropped=dropped, meta=meta)
