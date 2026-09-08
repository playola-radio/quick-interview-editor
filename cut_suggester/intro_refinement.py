"""Bounded sentence-level refinement of configured Song Intro proposals.

This opt-in pass leaves the tuned paragraph prompts and non-Intro records alone.
Its complete, validated responses use the same durable request seam as discovery.
"""

from __future__ import annotations

import json
from collections.abc import Callable

from .llm import LLMClient
from .models import Sentence
from .postprocess import validate_clip, verify_song


class IntroRefinementError(ValueError):
    """A refinement proposal or response cannot be used safely."""


def _prompt(sentences: list[Sentence], proposals: dict[str, dict], guidance: str) -> str:
    evidence = "\n".join(
        f"Proposal {reference} ({raw['start']} through {raw['end']}):\n"
        + "\n".join(f"[{s.index}] {s.text}" for s in sentences[raw['start']:raw['end'] + 1])
        for reference, raw in proposals.items()
    )
    return f"""Refine proposed Song Intro clips into complete, independently usable introductions or handoffs.
Configured Song Intro guidelines: {guidance}
Each proposal is a coarse selection, not an instruction to retain the whole paragraph.
Use the globally numbered sentences below. Return zero, one, or multiple complete takes strictly contained within each proposal.
Keep only the actual introduction/handoff. Exclude unrelated commercial-break transitions and trailing acknowledgments, isolated song-title fragments, false starts, and unfinished handoffs.
Retain the full contiguous relevant setup before the final handoff, including performer identification and background about the introduced recording. A complete introduction includes that setup; do not shorten it to only the title announcement or final handoff sentence.
A short complete handoff is valid. Do not impose a minimum word count or duration. Do not invent missing content to complete a fragment.
Consecutive independently complete introductions are separate takes even if the wording or song is identical.
Return exactly one result for every proposal ID, including an empty takes array if none is independently usable.
Within each proposal, returned takes must not overlap. Give each take a concise descriptive nonblank label and integer start/end global sentence indices.
Set song to the song introduced by that individual take, as supported by its sentences, or null when not established. Do not inherit a song from another take.
Proposals:
{evidence}
Reply with strict JSON: {{"results":[{{"proposal_id":"<exact proposal ID>","takes":[{{"start":<global index>,"end":<global index>,"label":"Complete song handoff","song":null}}]}}]}}"""


def _unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise IntroRefinementError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _parse(text: str, proposals: dict[str, dict], sentences: list[Sentence]) -> dict[str, list[dict]]:
    try:
        decoded = json.loads(text, object_pairs_hook=_unique_keys)
    except (TypeError, json.JSONDecodeError) as exc:
        raise IntroRefinementError("refinement response is not JSON") from exc
    if not isinstance(decoded, dict) or set(decoded) != {"results"} or not isinstance(decoded['results'], list):
        raise IntroRefinementError("refinement must contain only a results array")
    parsed = {}
    for result in decoded['results']:
        if not isinstance(result, dict) or set(result) != {"proposal_id", "takes"}:
            raise IntroRefinementError("refinement result must contain proposal_id and takes")
        reference, takes = result['proposal_id'], result['takes']
        if not isinstance(reference, str) or reference not in proposals or reference in parsed:
            raise IntroRefinementError("unknown or duplicate proposal_id")
        if not isinstance(takes, list):
            raise IntroRefinementError("takes must be an array")
        parent = proposals[reference]
        validated = []
        for take in takes:
            if not isinstance(take, dict) or set(take) != {"start", "end", "label", "song"}:
                raise IntroRefinementError("take must contain start, end, label, and song")
            clip = {"type": "intro", **take}
            if not validate_clip(clip)[0] or not parent['start'] <= take['start'] <= take['end'] <= parent['end']:
                raise IntroRefinementError("invalid take bounds or label")
            song = take['song']
            evidence = " ".join(s.text for s in sentences[take['start']:take['end'] + 1])
            if song is not None and (not isinstance(song, str) or not song.strip() or not verify_song(song, evidence)):
                raise IntroRefinementError("take song must be null or supported by that take")
            validated.append({**clip, 'label': take['label'].strip(), 'song': song.strip() if song else None})
        validated.sort(key=lambda clip: (clip['start'], clip['end']))
        if any(a['end'] >= b['start'] for a, b in zip(validated, validated[1:])):
            raise IntroRefinementError("takes overlap within a proposal")
        parsed[reference] = validated
    if set(parsed) != set(proposals):
        raise IntroRefinementError("refinement is missing an expected proposal")
    return parsed


def refine_intro_clips(
    sentences: list[Sentence], raw_clips: list[dict], llm: LLMClient, *, guidance: str,
    validated_request: Callable | None = None, max_proposals: int = 20,
    max_input_characters: int = 24000,
) -> list[dict]:
    if type(max_proposals) is not int or max_proposals < 1 or type(max_input_characters) is not int or max_input_characters < 1:
        raise IntroRefinementError("refinement limits must be positive integers")
    if not isinstance(guidance, str) or not guidance.strip():
        raise IntroRefinementError("Intro guidance must be nonblank")
    proposals = {}
    for index, raw in enumerate(raw_clips):
        if raw.get('type') != 'intro':
            continue
        if not validate_clip(raw)[0] or raw['end'] >= len(sentences):
            raise IntroRefinementError("Intro proposal has invalid source bounds or label")
        proposals[f'p{index}'] = raw

    # Plan all requests first: never pay for early batches before discovering an
    # oversized later proposal. Evidence cannot be truncated into a false take.
    batches = []
    current = {}
    for reference, raw in proposals.items():
        if len(_prompt(sentences, {reference: raw}, guidance)) > max_input_characters:
            raise IntroRefinementError(f"proposal {reference} exceeds the refinement input limit")
        prospective = {**current, reference: raw}
        if current and (len(prospective) > max_proposals or len(_prompt(sentences, prospective, guidance)) > max_input_characters):
            batches.append(current)
            current = {}
        current[reference] = raw
    if current:
        batches.append(current)
    refined = {}
    for batch in batches:
        prompt = _prompt(sentences, batch, guidance)
        stage = 'refine-intros:' + ','.join(batch)
        def validate(text):
            return _parse(text, batch, sentences)
        if validated_request is None:
            result = validate(llm.complete(prompt, purpose=stage).text)
        else:
            result = validated_request(stage, prompt, validate)
        refined.update(result)
    return [clip for index, raw in enumerate(raw_clips)
            for clip in refined.get(f'p{index}', [raw])]
