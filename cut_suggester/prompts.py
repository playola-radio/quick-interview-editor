"""Prompt templates (version PROMPT_VERSION).

Two stages: (1) partition a transcript window into contiguous topic paragraphs
covering every sentence; (2) classify the full paragraph inventory into product
clips, trimming and minimally merging. Evolved from the tuned spike prompts.
"""

from __future__ import annotations

from .models import ProductSpec, ProductType, Sentence


def numbered_slice(sentences: list[Sentence], a: int, b: int) -> str:
    """Sentences a..b-1 as `<global-index>: <text>` lines."""
    return "\n".join(f"{a + i}: {s.text}" for i, s in enumerate(sentences[a:b]))


def partition_prompt(sentences: list[Sentence], a: int, b: int) -> str:
    body = numbered_slice(sentences, a, b)
    return (
        "Partition this slice of an interview transcript into CONTIGUOUS topical "
        "paragraphs that cover EVERY sentence (no gaps, no overlaps). A paragraph "
        "is a run of sentences on one subject. Return STRICT JSON: "
        '{"paragraphs": [{"start": <global idx>, "end": <global idx incl>, '
        '"label": "<short topic>"}]} spanning exactly '
        f"{a}..{b - 1}.\n\n{body}"
    )


def _spec_line(spec: ProductSpec) -> str:
    kind = "ARTIST SPOTLIGHT" if spec.product_type is ProductType.SPOTLIGHT else "INTRO"
    return (
        f"- {kind} ({spec.target_min_sec:.0f}-{spec.target_max_sec:.0f}s): {spec.description}"
    )


def stage2_prompt(
    sentences: list[Sentence],
    partitions,
    specs: dict[ProductType, ProductSpec],
) -> str:
    blocks = []
    for p in partitions:
        seg = " ".join(s.text for s in sentences[p.start : p.end + 1])
        blocks.append(f"[P{p.start}-{p.end} | {p.label}] {seg}")
    body = "\n\n".join(blocks)
    spec_lines = "\n".join(_spec_line(specs[t]) for t in (ProductType.SPOTLIGHT, ProductType.INTRO) if t in specs)
    return (
        "You are a radio editor. Below is an interview already partitioned into "
        "topic paragraphs (each tagged [P<start>-<end> | label]). Produce product "
        "clips of these kinds:\n"
        f"{spec_lines}\n\n"
        "PREFER one paragraph = one clip. Only merge two adjacent paragraphs if "
        "they are clearly the SAME single story; never exceed ~130s. Be EXHAUSTIVE "
        "— emit a clip for EVERY clip-worthy paragraph (most paragraphs that are "
        "the subject telling a story qualify). You MAY trim to a sub-range of "
        "sentence indices for clean edges. Skip only paragraphs that are "
        "interviewer chatter or clearly not clip-worthy. For an intro, set "
        '"song" to the named song; otherwise null. Return STRICT JSON: '
        '{"clips": [{"type": "spotlight"|"intro", "start": <sent idx>, "end": '
        '<sent idx incl>, "label": "<3-6 words>", "song": <song or null>}]}.\n\n'
        + body
    )
