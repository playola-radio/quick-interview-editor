"""Pinned constants for the cut-suggester.

Model / prompt / product-spec versions are pinned so behavior is reproducible
and cache keys are stable. Model upgrades change behavior silently, so the
default is a fixed id; the eval can override it per run.
"""

from __future__ import annotations

# Default production model. The initial eval baseline overrides this to whatever
# key is present (OPENAI_KEY -> gpt-4o); provider+model stay a config knob.
DEFAULT_MODEL = "claude-sonnet-5"

PROMPT_VERSION = "v1"
PRODUCT_SPEC_VERSION = "v1"

# Model everything in samples so Swift and the engine agree on coordinates. The
# transcript fixtures carry only seconds, so a nominal rate turns seconds into
# samples; duration is always derived from these, never from the LLM's estimate.
DEFAULT_SAMPLE_RATE = 44_100

# Stage-1 windowing (overlapping partition + stitch). Sentences per window and
# the stride between window starts; overlap = WINDOW - STEP.
STAGE1_WINDOW = 130
STAGE1_STEP = 110


def window_params() -> dict:
    """Window parameters that participate in the cache key."""
    return {"window": STAGE1_WINDOW, "step": STAGE1_STEP}
