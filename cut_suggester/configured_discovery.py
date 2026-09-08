"""Discovery for broad Intros, configured imaging, and custom suggestion types.

Unlike the tuned cutter products, configured types are open strings.  This
module keeps their provider input and returned records deliberately plain so
the transport contract does not depend on the legacy ``ProductType`` enum.
"""

from __future__ import annotations

import json
import uuid
from collections.abc import Callable, Mapping, Sequence

from .llm import LLMClient
from .models import Sentence
from .suggestion_config import BROAD_INTRO_DISCOVERY_VERSIONS, CONFIGURED_DISCOVERY_VERSION, IMAGING_IDS


class DiscoveryError(ValueError):
    """A configured discovery request or provider response is malformed."""


_IMAGING_PRIORITY = {
    "image-pre-commercial": 2,
    "image-post-commercial": 2,
    "image-promo": 1,
    "image-id": 0,
}


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _span_length(candidate: Mapping) -> int:
    return candidate["end_index"] - candidate["start_index"] + 1


def _overlap(a: Mapping, b: Mapping) -> int:
    return max(0, min(a["end_index"], b["end_index"]) - max(a["start_index"], b["start_index"]) + 1)


def same_take(a: dict, b: dict) -> bool:
    """Whether same-type spans overlap by at least half of the shorter take."""
    overlap = _overlap(a, b)
    return overlap > 0 and overlap / min(_span_length(a), _span_length(b)) >= 0.5


def duplicate_imaging_classification(a: dict, b: dict) -> bool:
    """Whether two built-in image classifications substantially cover each other."""
    overlap = _overlap(a, b)
    return overlap > 0 and all(overlap / _span_length(item) >= 0.8 for item in (a, b))


def _validate_types(types: Sequence[Mapping]) -> dict[str, str]:
    declared: dict[str, str] = {}
    for item in types:
        if not isinstance(item, Mapping):
            raise DiscoveryError("configured type must be an object")
        type_id, guidance = item.get("id"), item.get("guidelines")
        if not isinstance(type_id, str) or not type_id.strip():
            raise DiscoveryError("configured type ID must be a nonblank string")
        if not isinstance(guidance, str) or not guidance.strip():
            raise DiscoveryError(f"configured type {type_id!r} must have nonblank guidelines")
        if type_id in declared:
            raise DiscoveryError(f"duplicate configured type ID {type_id!r}")
        declared[type_id] = guidance.strip()
    return declared


def _validated_run_id(run_id: object) -> uuid.UUID:
    if isinstance(run_id, uuid.UUID):
        return run_id
    if isinstance(run_id, str):
        try:
            return uuid.UUID(run_id)
        except ValueError as exc:
            raise DiscoveryError("run_id must be a UUID") from exc
    raise DiscoveryError("run_id must be a UUID")


def _prompt(sentences: list[Sentence], types: dict[str, str], start: int, end: int,
            *, discovery_prompt_version: str = "configured-v1") -> str:
    type_lines = "\n".join(f"- {type_id}: {guidance}" for type_id, guidance in types.items())
    transcript = "\n".join(f"[{s.index}] {s.text}" for s in sentences[start : end + 1])
    example_type = next(iter(types))
    example_end = min(start + 1, end)
    imaging_rule = (
        "For built-in imaging types only, incidental self-identification, URLs, or story mentions are not standalone images.\n"
        if any(type_id in IMAGING_IDS for type_id in types) else ""
    )
    take_rule = ""
    broad_intro = discovery_prompt_version in BROAD_INTRO_DISCOVERY_VERSIONS and 'intro' in types
    repeated_takes = discovery_prompt_version in BROAD_INTRO_DISCOVERY_VERSIONS | {CONFIGURED_DISCOVERY_VERSION}
    nested_rule = "A complete usable ID nested in a longer promo may be returned alongside the promo."
    if repeated_takes and (imaging_rule or broad_intro):
        take_rule = (
            "Each independently complete performance gets its own clip, including consecutive identical takes. "
            "End the first take before the next complete performance begins; never combine repetitions merely "
            "because the words, speaker, station, or label match.\n"
        )
        if imaging_rule and end - start >= 3:
            take_rule += (
                f'For example, if [{start}] says "You are listening to Example FM", [{start + 1}] says '
                f'"Your music station", and [{start + 2}] and [{start + 3}] repeat those two lines as a second '
                f'performance, return two clips: {start}–{start + 1} and {start + 2}–{start + 3}, not {start}–{start + 3}.\n'
            )
    if repeated_takes and imaging_rule:
        nested_rule = (
            "Return BOTH every complete independently usable ID nested in a longer promo AND the FULL continuous promo, "
            "including its continuation after the ID. Do not omit the independent ID because another clip already covers "
            "its sentences. A nested ID does not end or split the surrounding promo. Separate repeated performances, "
            "not the individual sentences or nested liners inside one continuous longer take."
        )
    heading = "Find configured audio-image and custom deliverables in this transcript window."
    intro_rule = ""
    if broad_intro:
        heading = "Find configured Intro, audio-image, and custom deliverables in this transcript window."
        intro_rule = (
            "For Intro, find meaningful commentary about a song or artist: its history, influence, writing, "
            "performance, or reception. No immediate musical handoff, named recording, or exact song title is required. "
            "Preserve complete useful thoughts; reject isolated names, acknowledgments, and incidental mentions. "
            "The configured guidelines control which commentary is useful for the requested Intro type.\n"
        )
    return f"""{heading}

Configured types and guidelines:
{type_lines}

Return only complete, independently usable takes. Find exhaustive distinct repeats; there is no quota.
{intro_rule}{take_rule}Do not invent text. {imaging_rule}{nested_rule}
Use global sentence coordinates exactly as shown.

Transcript window ({start} through {end}):
{transcript}

Reply with strict JSON in this form:
{{"clips":[{{"type":"{example_type}","start":{start},"end":{example_end},"label":"Complete take label"}}]}}
"""


def _validate_clip(raw: object, declared: set[str], source_count: int, window_start: int, window_end: int) -> dict:
    if not isinstance(raw, Mapping):
        raise DiscoveryError("clip must be an object")
    type_id, start, end, label = raw.get("type"), raw.get("start"), raw.get("end"), raw.get("label")
    if not isinstance(type_id, str) or type_id not in declared:
        raise DiscoveryError(f"undeclared configured type {type_id!r}")
    if not _is_int(start) or not _is_int(end):
        raise DiscoveryError("clip start and end must be integers")
    if start < 0 or end < 0 or start > end:
        raise DiscoveryError("clip has invalid sentence bounds")
    if end >= source_count or start < window_start or end > window_end:
        raise DiscoveryError("clip bounds are outside the requested transcript window")
    if not isinstance(label, str) or not label.strip():
        raise DiscoveryError("clip label must be a nonblank string")
    return {"type": type_id, "start": start, "end": end, "label": label.strip()}


def _candidate(sentences: list[Sentence], raw: dict, sample_rate: int) -> dict:
    span = sentences[raw["start"] : raw["end"] + 1]
    word_ids = [word_id for sentence in span for word_id in sentence.word_ids]
    start_sample, end_sample = span[0].start_sample, span[-1].end_sample
    return {
        "product_type": raw["type"], "start_index": raw["start"], "end_index": raw["end"],
        "label": raw["label"], "song": None, "song_verified": False, "word_ids": word_ids,
        "start_sample": start_sample, "end_sample": end_sample,
        "start_sec": span[0].start_sec, "end_sec": span[-1].end_sec,
        "duration_sec": (end_sample - start_sample) / sample_rate,
        "rank": 0, "score": 0.0, "warnings": [],
    }


def _preferred_same_type(candidates: list[dict]) -> list[dict]:
    """Resolve window-seam duplicates while retaining nonoverlapping repeats."""
    selected: list[dict] = []
    for candidate in sorted(candidates, key=lambda c: (-_span_length(c), c["start_index"], c["end_index"])):
        if not any(same_take(candidate, kept) for kept in selected):
            selected.append(candidate)
    return selected


def _resolve_overlaps(candidates: list[dict]) -> list[dict]:
    by_type: dict[str, list[dict]] = {}
    for candidate in candidates:
        by_type.setdefault(candidate["product_type"], []).append(candidate)
    selected = [candidate for items in by_type.values() for candidate in _preferred_same_type(items)]

    builtins = [candidate for candidate in selected if candidate["product_type"] in IMAGING_IDS]
    custom = [candidate for candidate in selected if candidate["product_type"] not in IMAGING_IDS]
    winners: list[dict] = []
    for candidate in sorted(builtins, key=lambda c: (-_IMAGING_PRIORITY[c["product_type"]], -_span_length(c), c["product_type"], c["start_index"], c["end_index"])):
        duplicate = next((winner for winner in winners if duplicate_imaging_classification(candidate, winner)), None)
        if duplicate is None:
            winners.append(candidate)
        elif {candidate["product_type"], duplicate["product_type"]} == {"image-pre-commercial", "image-post-commercial"}:
            duplicate["warnings"].append("ambiguous pre/post-commercial imaging classification")
    return sorted(custom + winners, key=lambda c: (c["start_index"], c["end_index"], c["product_type"]))


def _candidate_id(run_id: uuid.UUID, candidate: Mapping) -> str:
    # JSON array serialization makes field boundaries explicit (unlike string concatenation).
    name = json.dumps([candidate["product_type"], candidate["start_index"], candidate["end_index"]], separators=(",", ":"))
    return str(uuid.uuid5(run_id, name))


def discover_configured(
    sentences: list[Sentence], types: Sequence[Mapping], llm: LLMClient, *, run_id: uuid.UUID | str,
    sample_rate: int, window: int = 130, step: int = 110,
    validated_request: Callable | None = None,
    discovery_prompt_version: str = "configured-v1",
) -> list[dict]:
    """Discover configured types over globally-indexed overlapping windows."""
    if not _is_int(sample_rate) or sample_rate <= 0:
        raise DiscoveryError("sample_rate must be a positive integer")
    if not _is_int(window) or window <= 0:
        raise DiscoveryError("window must be a positive integer")
    if not _is_int(step) or step <= 0:
        raise DiscoveryError("step must be a positive integer")
    if step > window:
        raise DiscoveryError("step must not exceed window")
    run_uuid = _validated_run_id(run_id)
    declared = _validate_types(types)
    if not declared or not sentences:
        return []

    candidates: list[dict] = []
    for start in range(0, len(sentences), step):
        end = min(len(sentences) - 1, start + window - 1)
        prompt = _prompt(sentences, declared, start, end, discovery_prompt_version=discovery_prompt_version)
        def validate(text):
            try:
                decoded = json.loads(text)
            except (TypeError, json.JSONDecodeError) as exc:
                raise DiscoveryError("configured discovery response is not JSON") from exc
            clips = decoded.get("clips") if isinstance(decoded, Mapping) else None
            if not isinstance(clips, list):
                raise DiscoveryError("configured discovery response must contain a clips array")
            return [_validate_clip(raw, set(declared), len(sentences), start, end) for raw in clips]
        if validated_request is None:
            clips = validate(llm.complete(prompt, purpose="configured-discovery").text)
        else:
            clips = validated_request("configured-discovery", prompt, validate)
        for raw in clips:
            candidate = _candidate(sentences, raw, sample_rate)
            if not 1 <= candidate["duration_sec"] <= 240:
                continue
            candidates.append(candidate)
        if end == len(sentences) - 1:
            break

    resolved = _resolve_overlaps(candidates)
    for candidate in resolved:
        candidate["candidate_id"] = _candidate_id(run_uuid, candidate)
    return resolved
