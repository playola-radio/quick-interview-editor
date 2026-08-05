"""Data models for the cut-suggester.

Distinct types keep display grouping, LLM scaffolding, and product candidates
separate (per the design):

- `Sentence`   — one transcript unit (a WhisperX segment), the LLM input.
- `TopicPartition` — stage-1 scaffold (internal to the cutter).
- `CutCandidate`   — a product candidate a human accepts/edits.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


class ProductType(str, Enum):
    INTRO = "intro"
    SPOTLIGHT = "spotlight"


@dataclass(frozen=True)
class ProductSpec:
    """A radio deliverable and its duration windows.

    `target_*` is the shipped shape (used for compliance metrics); `hard_*` is
    the acceptance range enforcement keeps (generous, so merged real stories are
    not discarded). Fragments (< hard_min) and absurd over-merges (> hard_max)
    are dropped.
    """

    product_type: ProductType
    target_min_sec: float
    target_max_sec: float
    hard_min_sec: float
    hard_max_sec: float
    description: str


@dataclass(frozen=True)
class Sentence:
    """One transcript unit: a WhisperX segment (~ a sentence)."""

    index: int  # position in the sentence list; stage indices reference this
    segment_id: int
    text: str
    word_ids: tuple[int, ...]
    start_sec: float
    end_sec: float
    start_sample: int
    end_sample: int


@dataclass(frozen=True)
class TopicPartition:
    """Stage-1 scaffold: a contiguous run of sentences on one topic."""

    start: int  # inclusive sentence index
    end: int  # inclusive sentence index
    label: str


@dataclass
class CutCandidate:
    """A ranked product candidate for a human editor."""

    product_type: ProductType
    start_index: int  # inclusive sentence index
    end_index: int  # inclusive sentence index
    label: str
    song: str | None
    song_verified: bool
    word_ids: list[int]
    start_sample: int
    end_sample: int
    start_sec: float
    end_sec: float
    duration_sec: float
    rank: int = 0
    score: float = 0.0
    warnings: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "product_type": self.product_type.value,
            "start_index": self.start_index,
            "end_index": self.end_index,
            "label": self.label,
            "song": self.song,
            "song_verified": self.song_verified,
            "word_ids": list(self.word_ids),
            "start_sample": self.start_sample,
            "end_sample": self.end_sample,
            "start_sec": self.start_sec,
            "end_sec": self.end_sec,
            "duration_sec": self.duration_sec,
            "rank": self.rank,
            "score": self.score,
            "warnings": list(self.warnings),
        }


# --- Product specs (version PRODUCT_SPEC_VERSION) ---------------------------
# Spotlight: ~40-120s target; accept 15-240s so merged multi-paragraph stories
# survive (the spike kept some 150-200s clips that matched shipped topics).
# Intro: ~15-45s target; accept 12-75s.
SPOTLIGHT_SPEC = ProductSpec(
    product_type=ProductType.SPOTLIGHT,
    target_min_sec=40,
    target_max_sec=120,
    hard_min_sec=15,
    hard_max_sec=240,
    description="one self-contained story or anecdote (~40-120s)",
)

INTRO_SPEC = ProductSpec(
    product_type=ProductType.INTRO,
    target_min_sec=15,
    target_max_sec=45,
    hard_min_sec=12,
    hard_max_sec=75,
    description="sets up ONE named song and ends on the handoff (~15-45s)",
)

DEFAULT_SPECS = {
    ProductType.SPOTLIGHT: SPOTLIGHT_SPEC,
    ProductType.INTRO: INTRO_SPEC,
}

# A clip shorter than this is a fragment (reported separately from recall).
FRAGMENT_SECONDS = 15.0
