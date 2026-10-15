"""Classify one hand-marked clip and extract its naming fields in a single LLM call."""

from __future__ import annotations

import json
from collections.abc import Mapping, Sequence

from .configured_discovery import FOCUSED_INTRO_RULE
from .configured_run import validate_transcript_units
from .extraction import (ExtractionError, _instructions, _no_duplicate_object_keys,
                         interview_artist_context, required_field_ids)
from .llm import LLMClient
from .suggestion_config import _trim_foundation_whitespace, validate_configuration

MAX_PROMPT_CHARACTERS = 24000


class ClipNamingError(ValueError):
    """A clip-naming request or model reply cannot safely be used."""


def _is_sample(value: object) -> bool:
    return type(value) is int and value >= 0


def validate_clip_request(request: object) -> None:
    if not isinstance(request, dict):
        raise ClipNamingError("request must be an object")
    if type(request.get("schema_version")) is not int or request["schema_version"] != 1:
        raise ClipNamingError("unsupported schema_version; expected 1")
    model = request.get("model")
    if not isinstance(model, str) or not model.strip():
        raise ClipNamingError("model must be a nonblank string")
    validate_configuration(request.get("configuration"))
    clip = request.get("clip")
    if not isinstance(clip, dict):
        raise ClipNamingError("clip must be an object")
    text = clip.get("text")
    if not isinstance(text, str) or not _trim_foundation_whitespace(text):
        raise ClipNamingError("clip text must be a nonblank string")
    if not _is_sample(clip.get("start_sample")) or not _is_sample(clip.get("end_sample")):
        raise ClipNamingError("clip start_sample and end_sample must be nonnegative integers")
    if clip["end_sample"] < clip["start_sample"]:
        raise ClipNamingError("clip has reversed bounds")
    validate_transcript_units(request.get("transcript_units"))
    if "interview_artist" in request:
        artist = request["interview_artist"]
        if not isinstance(artist, str) or not _trim_foundation_whitespace(artist):
            raise ClipNamingError("interview_artist must be a nonblank string when supplied")


def _distance(unit: Mapping, start: int, end: int) -> int:
    return start - unit["end_sample"] if unit["end_sample"] <= start else unit["start_sample"] - end


def _context_lines(units: Sequence[Mapping], start: int, end: int) -> list[str]:
    outside = [u for u in units if u["end_sample"] <= start or u["start_sample"] >= end]
    outside.sort(key=lambda u: (_distance(u, start, end), u["start_sample"], u["id"]))
    lines = []
    for unit in outside:
        speaker = unit.get("speaker_id")
        suffix = f" [speaker_id: {speaker}]" if isinstance(speaker, str) and _trim_foundation_whitespace(speaker) else ""
        lines.append(f"[{unit['id']}] {unit['text'].strip()}{suffix}")
    return lines


def _render(request: Mapping, context: str) -> str:
    config = request["configuration"]
    type_blocks, field_ids = [], set()
    for item in config["types"]:
        required = required_field_ids(item)
        field_ids.update(required)
        type_blocks.append(
            f"- {item['id']} ({item['name']}): {item['guidelines']}\n"
            f"  If you choose this type, return these field_ids: {', '.join(required) or 'none'}"
        )
    type_ids = {item["id"] for item in config["types"]}
    rules = ""
    if "intro" in type_ids:
        rules += FOCUSED_INTRO_RULE
        if "spotlight" in type_ids:
            rules += "If the clip fails the Intro single-subject check but fits Spotlight, choose spotlight.\n"
    instructions = _instructions(field_ids, {f["id"]: f["instructions"] for f in config["fields"]}) + "\n\n" if field_ids else ""
    return f"""Classify one audio clip against the configured types, then extract the naming fields for the chosen type.

The clip text is the thing to classify. Surrounding transcript context is evidence only. Choose the single best-fitting configured type. If no configured type fits, return type_id null and an empty fields array. Use the field instructions exactly. Return null for a field when evidence is insufficient. A speaker_id identifies who is speaking, but never by itself establishes the performer; do not treat speaker identity as performer evidence. Do not ask for or return sequence numbers or filenames.

Configured types:
{chr(10).join(type_blocks)}

{rules}{interview_artist_context(request.get("interview_artist"))}
{instructions}Clip text:
{request['clip']['text'].strip()}

Optional transcript context (nearest first):
{context}

Reply with strict JSON only:
{{"type_id":"<type id>" or null,"fields":[{{"field_id":"...","value":"..." or null}}]}}
"""


def build_prompt(request: Mapping) -> str:
    mandatory = _render(request, "")
    if len(mandatory) > MAX_PROMPT_CHARACTERS:
        raise ClipNamingError(
            f"clip and configuration are too long for one request ({len(mandatory)} > {MAX_PROMPT_CHARACTERS} characters)"
        )
    clip = request["clip"]
    included: list[str] = []
    for line in _context_lines(request["transcript_units"], clip["start_sample"], clip["end_sample"]):
        if len(_render(request, "\n".join(included + [line]))) > MAX_PROMPT_CHARACTERS:
            break
        included.append(line)
    return _render(request, "\n".join(included))


def parse_response(text: str, types: Sequence[Mapping]) -> dict:
    try:
        decoded = json.loads(text, object_pairs_hook=_no_duplicate_object_keys)
    except (TypeError, ValueError, ExtractionError) as exc:
        raise ClipNamingError(f"clip naming response is not valid JSON: {exc}") from exc
    if not isinstance(decoded, Mapping) or set(decoded) != {"type_id", "fields"}:
        raise ClipNamingError("clip naming response must contain only type_id and fields")
    type_id, fields = decoded["type_id"], decoded["fields"]
    if not isinstance(fields, list):
        raise ClipNamingError("clip naming fields must be an array")
    if type_id is None:
        if fields:
            raise ClipNamingError("clip naming response with null type_id must have no fields")
        return {"type_id": None, "fields": {}}
    chosen = next((item for item in types if item["id"] == type_id), None) if isinstance(type_id, str) else None
    if chosen is None:
        raise ClipNamingError(f"clip naming response has an unconfigured type_id {type_id!r}")
    expected = required_field_ids(chosen)
    values: dict[str, str | None] = {}
    for field in fields:
        if not isinstance(field, Mapping) or set(field) != {"field_id", "value"}:
            raise ClipNamingError("clip naming field must contain field_id and value")
        field_id, value = field["field_id"], field["value"]
        if not isinstance(field_id, str) or field_id not in expected:
            raise ClipNamingError(f"clip naming response has an undeclared field_id {field_id!r}")
        if field_id in values:
            raise ClipNamingError(f"clip naming response has a duplicate field_id {field_id!r}")
        if value is not None and not isinstance(value, str):
            raise ClipNamingError("clip naming field value must be a string or null")
        values[field_id] = None if value is None else _trim_foundation_whitespace(value) or None
    if set(values) != set(expected):
        raise ClipNamingError("clip naming response is missing an expected field")
    return {"type_id": type_id, "fields": {field_id: values[field_id] for field_id in expected}}


def run_name_clip(request: dict, llm: LLMClient) -> dict:
    validate_clip_request(request)
    parsed = parse_response(llm.complete(build_prompt(request), purpose="name-clip").text, request["configuration"]["types"])
    fields = parsed["fields"]
    if parsed["type_id"] == "intro" and {"artist-name", "song-title"} <= fields.keys() \
            and fields["artist-name"] is None and fields["song-title"] is None:
        return {"type_id": None, "fields": {}}
    return parsed
