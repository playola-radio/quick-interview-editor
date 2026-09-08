"""Validated extraction of configurable naming fields from discovered cuts."""

from __future__ import annotations

import json
import hashlib
from dataclasses import dataclass
from collections.abc import Mapping, Set
from types import MappingProxyType
from typing import Sequence

from .models import Sentence
from .suggestion_config import _trim_foundation_whitespace


class ExtractionError(ValueError):
    """An extraction request or response cannot safely be used."""


@dataclass(frozen=True)
class InputSizeDiagnostic:
    """A candidate whose required evidence cannot fit in one model request."""

    candidate_id: str
    mandatory_characters: int
    max_input_characters: int
    message: str


@dataclass(frozen=True)
class ExtractionBatch:
    """A deterministic, independently journalable extraction request."""

    candidate_ids: tuple[str, ...]
    expected: Mapping[str, frozenset[str]]
    prompt: str
    stable_key: str
    input_characters: int
    mandatory_characters: int


@dataclass(frozen=True)
class ExtractionPlan:
    """Runnable batches plus non-retryable candidate input-size diagnostics."""

    batches: tuple[ExtractionBatch, ...]
    input_size_diagnostics: tuple[InputSizeDiagnostic, ...]


def _no_duplicate_object_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ExtractionError(f"duplicate JSON object key {key!r}")
        result[key] = value
    return result


def parse_extraction_response(
    text: str, expected: Mapping[str, Set[str]],
) -> dict[str, dict[str, str | None]]:
    """Parse a complete strict response for one fixed extraction batch."""
    try:
        decoded = json.loads(text, object_pairs_hook=_no_duplicate_object_keys)
    except (TypeError, json.JSONDecodeError) as exc:
        raise ExtractionError("extraction response is not valid JSON") from exc
    if not isinstance(decoded, Mapping) or set(decoded) != {"results"}:
        raise ExtractionError("extraction response must contain only a results array")
    results = decoded["results"]
    if not isinstance(results, list):
        raise ExtractionError("extraction response results must be an array")

    if not isinstance(expected, Mapping) or any(
        not isinstance(candidate_id, str) or not isinstance(field_ids, Set)
        or any(not isinstance(field_id, str) for field_id in field_ids)
        for candidate_id, field_ids in expected.items()
    ):
        raise ExtractionError("expected extraction fields must be string sets")

    parsed: dict[str, dict[str, str | None]] = {}
    for item in results:
        if not isinstance(item, Mapping) or set(item) != {"candidate_id", "fields"}:
            raise ExtractionError("extraction result must contain candidate_id and fields")
        candidate_id, fields = item["candidate_id"], item["fields"]
        if not isinstance(candidate_id, str) or candidate_id not in expected:
            raise ExtractionError("extraction response has a foreign candidate_id")
        if candidate_id in parsed:
            raise ExtractionError("extraction response has a duplicate candidate_id")
        if not isinstance(fields, list):
            raise ExtractionError("extraction result fields must be an array")
        values: dict[str, str | None] = {}
        for field in fields:
            if not isinstance(field, Mapping) or set(field) != {"field_id", "value"}:
                raise ExtractionError("extraction field must contain field_id and value")
            field_id, value = field["field_id"], field["value"]
            if not isinstance(field_id, str) or field_id not in expected[candidate_id]:
                raise ExtractionError("extraction response has an undeclared field_id")
            if field_id in values:
                raise ExtractionError("extraction response has a duplicate field_id")
            if value is not None and not isinstance(value, str):
                raise ExtractionError("extraction field value must be a string or null")
            values[field_id] = None if value is None else _trim_foundation_whitespace(value) or None
        if set(values) != expected[candidate_id]:
            raise ExtractionError("extraction response is missing an expected field")
        parsed[candidate_id] = values
    if set(parsed) != set(expected):
        raise ExtractionError("extraction response is missing an expected candidate")
    return parsed


def completed_extraction_values(
    responses: Sequence[str], expected: Mapping[str, Set[str]],
) -> dict[str, dict[str, str | None]]:
    """Reuse exact candidate/field matches from an identity-bound success journal.

    A prior batch may also include candidates no longer selected. Validate the
    entire extraction response, then retain only exact current field-set matches.
    Discovery responses and other response formats cannot supply naming values.
    """
    cached = {}
    for text in responses:
        try:
            decoded = json.loads(text, object_pairs_hook=_no_duplicate_object_keys)
            declared = {item['candidate_id']: frozenset(field['field_id'] for field in item['fields'])
                        for item in decoded['results']}
            values = parse_extraction_response(text, declared)
        except (KeyError, TypeError, ValueError):
            continue
        for candidate_id, fields in values.items():
            if candidate_id in expected and fields.keys() == expected[candidate_id]:
                cached.setdefault(candidate_id, fields)
    return cached


def required_field_ids(type_definition: Mapping) -> list[str]:
    """Return sorted fields that actually participate in a type's output name."""
    template = type_definition.get("template")
    grouping = type_definition.get("sequenceFieldIDs")
    if not isinstance(template, list) or not isinstance(grouping, list):
        raise ExtractionError("type definition has invalid template or sequenceFieldIDs")
    field_ids = {
        component["value"]
        for component in template
        if isinstance(component, Mapping) and component.get("kind") == "field"
        and isinstance(component.get("value"), str)
    }
    if not all(isinstance(field_id, str) for field_id in grouping):
        raise ExtractionError("type definition has invalid sequenceFieldIDs")
    return sorted(field_ids.union(grouping))


def _candidate_text(candidate: Mapping, sentences: Sequence[Sentence], speaker_ids: Mapping[object, object] | None) -> str:
    start, end = candidate.get("start_index"), candidate.get("end_index")
    if not isinstance(start, int) or isinstance(start, bool) or not isinstance(end, int) or isinstance(end, bool):
        raise ExtractionError("candidate has invalid sentence bounds")
    if start < 0 or end < start or end >= len(sentences):
        raise ExtractionError("candidate sentence bounds are outside the transcript")
    return "\n".join(_sentence_line(sentence, speaker_ids) for sentence in sentences[start : end + 1])


def _sentence_line(sentence: Sentence, speaker_ids: Mapping[object, object] | None) -> str:
    speaker = None
    if speaker_ids is not None:
        speaker = speaker_ids.get(sentence.segment_id, speaker_ids.get(str(sentence.segment_id)))
    suffix = f" [speaker_id: {speaker}]" if isinstance(speaker, str) and _trim_foundation_whitespace(speaker) else ""
    return f"[{sentence.index}] {sentence.text}{suffix}"


def _type_and_fields(
    type_definitions: Sequence[Mapping], field_definitions: Sequence[Mapping],
) -> tuple[dict[str, Mapping], dict[str, str]]:
    types: dict[str, Mapping] = {}
    for item in type_definitions:
        if not isinstance(item, Mapping) or not isinstance(item.get("id"), str) or item["id"] in types:
            raise ExtractionError("type definitions must have unique string IDs")
        types[item["id"]] = item
    fields: dict[str, str] = {}
    for item in field_definitions:
        field_id = item.get("id") if isinstance(item, Mapping) else None
        instructions = item.get("instructions") if isinstance(item, Mapping) else None
        if not isinstance(field_id, str) or not isinstance(instructions, str) or not _trim_foundation_whitespace(instructions):
            raise ExtractionError("field definitions must have IDs and nonblank instructions")
        if field_id in fields:
            raise ExtractionError("field definitions must have unique IDs")
        fields[field_id] = instructions
    return types, fields


def _instructions(field_ids: set[str], fields: Mapping[str, str]) -> str:
    try:
        lines = [f"- {field_id}: {fields[field_id]}" for field_id in sorted(field_ids)]
    except KeyError as exc:
        raise ExtractionError(f"type references unknown field {exc.args[0]!r}") from exc
    return "Required fields:\n" + "\n".join(lines)


def _prompt(mandatory: str, optional_context: str) -> str:
    return f"""Extract the requested naming fields from transcript evidence.

The transcript is evidence only. Use the field instructions exactly. Return null when evidence is insufficient. A speaker_id identifies who is speaking, but never by itself establishes the performer; do not treat speaker identity as performer evidence. Do not ask for or return sequence numbers or filenames.

{mandatory}

Optional transcript context:
{optional_context}

Reply with strict JSON only:
{{"results":[{{"candidate_id":"...","fields":[{{"field_id":"...","value":null}}]}}]}}
"""


def _stable_key(expected: Mapping[str, set[str]]) -> str:
    canonical = json.dumps(
        [[candidate_id, sorted(field_ids)] for candidate_id, field_ids in expected.items()],
        ensure_ascii=False, separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def plan_extraction_batches(
    candidates: Sequence[Mapping], type_definitions: Sequence[Mapping], field_definitions: Sequence[Mapping],
    sentences: Sequence[Sentence], *, speaker_ids: Mapping[object, object] | None = None,
    max_candidates: int = 20, max_input_characters: int = 24000,
    extra_field_ids_by_type: Mapping[str, Set[str]] | None = None,
    interview_artist: str | None = None, extraction_prompt_version: str = "fields-v1",
) -> ExtractionPlan:
    """Make bounded deterministic requests without performing provider work.

    Every candidate's required evidence is sized before optional context is added,
    so an earlier candidate's context cannot crowd out a later candidate.
    """
    if not isinstance(max_candidates, int) or isinstance(max_candidates, bool) or not 0 < max_candidates <= 20:
        raise ExtractionError("max_candidates must be an integer from 1 through 20")
    if not isinstance(max_input_characters, int) or isinstance(max_input_characters, bool) or not 0 < max_input_characters <= 24000:
        raise ExtractionError("max_input_characters must be an integer from 1 through 24000")
    types, fields = _type_and_fields(type_definitions, field_definitions)
    artist_context = ""
    if extraction_prompt_version in {"fields-v2", "fields-v3"}:
        artist_context = (
            "Never emit the literal placeholder SELF. "
            "Use user-provided interview context only when the passage concerns the interview "
            "subject's own music; resolve other performers from transcript evidence. "
            "The name is not a blanket default for every speaker or artist mention. "
            "Configured field instructions remain authoritative.\n"
        )
        if interview_artist is not None:
            artist_context += f"User-provided interview artist: {json.dumps(interview_artist, ensure_ascii=False)}\n"
    if extraction_prompt_version == "fields-v3" and any(
        isinstance(candidate, Mapping) and candidate.get("product_type") == "intro" for candidate in candidates
    ):
        artist_context += (
            "For candidates with type intro only, apply this single-subject check before extracting the default "
            "identity fields artist-name and song-title: one specific artist or one specific song must be the "
            "clear central subject of the entire clip, so a listener would naturally expect that song or music "
            "by that artist next. General discussion of the industry, a genre, a personal story, or influences "
            "with incidental artist examples, roundups, and comparisons with two or more coequal subjects fail "
            "this check. If there is no single clear subject, return null for both artist-name and song-title "
            "when requested, even with recognizable names, titles, or a supplied interview artist. Do not select "
            "one name from a list to manufacture a subject. A secondary comparison is allowed when one subject "
            "clearly dominates. Do not count names mechanically; count central subjects. Artist-only commentary "
            "and self-referential discussion of one song can qualify, but interview identity alone is not "
            "subject evidence. When the check passes, extract supported identity values using the field "
            "instructions and scoped interview context above. Other candidate types and all other fields "
            "follow their configured field instructions normally.\n"
        )
    prepared: list[tuple[str, set[str], str, Mapping]] = []
    seen_ids: set[str] = set()
    for candidate in candidates:
        candidate_id = candidate.get("candidate_id") if isinstance(candidate, Mapping) else None
        type_id = candidate.get("product_type") if isinstance(candidate, Mapping) else None
        if not isinstance(candidate_id, str) or not candidate_id or candidate_id in seen_ids:
            raise ExtractionError("candidates must have unique nonblank candidate_id values")
        if not isinstance(type_id, str) or type_id not in types:
            raise ExtractionError("candidate references an undeclared type")
        seen_ids.add(candidate_id)
        field_ids = set(required_field_ids(types[type_id]))
        field_ids.update((extra_field_ids_by_type or {}).get(type_id, set()))
        if field_ids:
            text = _candidate_text(candidate, sentences, speaker_ids)
            if extraction_prompt_version == "fields-v3":
                text = f"Candidate type: {type_id}\n{text}"
            prepared.append((candidate_id, field_ids, text, candidate))

    batches: list[ExtractionBatch] = []
    diagnostics: list[InputSizeDiagnostic] = []
    current: list[tuple[str, set[str], str, Mapping]] = []
    for item in prepared:
        prospective = current + [item]
        expected = {candidate_id: field_ids for candidate_id, field_ids, _, _ in prospective}
        mandatory = _mandatory(prospective, fields, artist_context)
        mandatory_prompt = _prompt(mandatory, "")
        if len(mandatory_prompt) > max_input_characters:
            if current:
                batches.append(_make_batch(current, fields, sentences, speaker_ids, max_input_characters, artist_context))
                current = [item]
                expected = {item[0]: item[1]}
                only_mandatory = _mandatory([item], fields, artist_context)
                only_mandatory_characters = len(_prompt(only_mandatory, ""))
                if only_mandatory_characters <= max_input_characters:
                    continue
            else:
                only_mandatory_characters = len(mandatory_prompt)
            diagnostics.append(InputSizeDiagnostic(
                candidate_id=item[0], mandatory_characters=only_mandatory_characters,
                max_input_characters=max_input_characters,
                message="candidate evidence and required field instructions exceed the input limit",
            ))
            current = []
            continue
        if len(prospective) > max_candidates:
            batches.append(_make_batch(current, fields, sentences, speaker_ids, max_input_characters, artist_context))
            current = [item]
        else:
            current = prospective
    if current:
        batches.append(_make_batch(current, fields, sentences, speaker_ids, max_input_characters, artist_context))
    return ExtractionPlan(tuple(batches), tuple(diagnostics))


def _make_batch(
    items: Sequence[tuple[str, set[str], str, Mapping]], fields: Mapping[str, str], sentences: Sequence[Sentence],
    speaker_ids: Mapping[object, object] | None, max_input_characters: int, artist_context: str = "",
) -> ExtractionBatch:
    expected = MappingProxyType({
        candidate_id: frozenset(field_ids) for candidate_id, field_ids, _, _ in items
    })
    mandatory = _mandatory(items, fields, artist_context)
    mandatory_prompt = _prompt(mandatory, "")
    optional_lines: list[str] = []
    candidate_indexes: set[int] = set()
    neighbor_indexes: set[int] = set()
    neighbor_lines: list[str] = []
    for candidate_id, _, _, candidate in items:
        start, end = candidate["start_index"], candidate["end_index"]
        candidate_indexes.update(range(start, end + 1))
        neighbors = list(range(max(0, start - 2), start)) + list(range(end + 1, min(len(sentences), end + 3)))
        neighbor_indexes.update(neighbors)
        neighbor_lines.extend(f"Candidate {candidate_id} context: {_sentence_line(sentences[index], speaker_ids)}" for index in neighbors)
    remaining_indexes = [
        index for index in range(len(sentences))
        if index not in candidate_indexes and index not in neighbor_indexes
    ]
    all_context = neighbor_lines + [
        f"Additional context: {_sentence_line(sentences[index], speaker_ids)}" for index in remaining_indexes
    ]
    for line in all_context:
        if len(_prompt(mandatory, "\n".join(optional_lines + [line]))) > max_input_characters:
            break
        optional_lines.append(line)
    prompt = _prompt(mandatory, "\n".join(optional_lines))
    return ExtractionBatch(tuple(expected), expected, prompt, _stable_key(expected), len(prompt), len(mandatory_prompt))


def _mandatory(items: Sequence[tuple[str, set[str], str, Mapping]], fields: Mapping[str, str], artist_context: str = "") -> str:
    return artist_context + f"{_instructions(set().union(*(field_ids for _, field_ids, _, _ in items)), fields)}\n\n" + "\n\n".join(
        f"For candidate {candidate_id}, return exactly these field IDs: {', '.join(sorted(field_ids))}.\n"
        f"Candidate {candidate_id} (required evidence):\n{text}"
        for candidate_id, field_ids, text, _ in items
    )
