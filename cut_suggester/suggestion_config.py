"""Validate the shared suggestion-configuration wire format and route discovery.

The configurable set is deliberately open-ended. Historic requests route the
two exact built-in IDs through the tuned paragraph pass. Broad Intro discovery
leaves only Spotlight on that path; lookalike custom names stay configured.
"""

from __future__ import annotations

import unicodedata
from collections.abc import Mapping

from .models import DEFAULT_SPECS, ProductSpec, ProductType

TUNED_IDS = frozenset(("spotlight", "intro"))
CONFIGURED_DISCOVERY_VERSION = "configured-v2"
BROAD_INTRO_DISCOVERY_VERSION = "configured-v3"
IMAGING_IDS = frozenset(("image-id", "image-pre-commercial", "image-post-commercial", "image-promo"))
_GROUPS = frozenset(("spotlights", "songIntros", "audioImages"))
_FOUNDATION_WHITESPACE = frozenset(
    "\u0009\u000a\u000b\u000c\u000d\u0020\u0085\u00a0\u1680\u2028\u2029\u202f\u205f\u3000"
).union(chr(value) for value in range(0x2000, 0x200C))


class ConfigurationError(ValueError):
    """The shared configuration cannot safely be sent to a model."""


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _blank(value: object) -> bool:
    return not isinstance(value, str) or not _trim_foundation_whitespace(value)


def _trim_foundation_whitespace(value: str) -> str:
    start, end = 0, len(value)
    while start < end and value[start] in _FOUNDATION_WHITESPACE:
        start += 1
    while end > start and value[end - 1] in _FOUNDATION_WHITESPACE:
        end -= 1
    return value[start:end]


def normalize_configuration_name(value: str) -> str:
    """Swift-compatible display-name identity (case/diacritic/width/space)."""
    width_folded = "".join(
        "".join(chr(int(codepoint, 16)) for codepoint in decomposition.split()[1:])
        if decomposition.startswith(("<wide> ", "<narrow> ")) else char
        for char in value
        for decomposition in (unicodedata.decomposition(char),)
    )
    # CoreFoundation's diacritic folding only removes following marks when the
    # decomposed base is below U+0510; preserving later-script marks matches
    # Foundation's `folding` behavior. See CFString.c L2258 and L2334:
    # https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/CoreFoundation/CFString.c
    without_latin_marks: list[str] = []
    base: str | None = None
    for char in unicodedata.normalize("NFD", width_folded):
        if unicodedata.combining(char):
            if base is not None and ord(base) < 0x0510:
                continue
        else:
            base = char
        without_latin_marks.append(char)
    folded = unicodedata.normalize("NFC", "".join(without_latin_marks)).casefold()
    tokens: list[str] = []
    current: list[str] = []
    for char in unicodedata.normalize("NFC", folded):
        if char in _FOUNDATION_WHITESPACE:
            if current:
                tokens.append("".join(current))
                current = []
        else:
            current.append(char)
    if current:
        tokens.append("".join(current))
    return " ".join(tokens)


def validate_configuration(config: object) -> None:
    """Raise ``ConfigurationError`` unless *config* is the V1 shared shape."""
    if not isinstance(config, Mapping):
        raise ConfigurationError("configuration must be an object")
    schema = config.get("schemaVersion")
    revision = config.get("revision")
    if not _is_int(schema) or schema != 1:
        raise ConfigurationError("unsupported or missing schemaVersion")
    if not _is_int(revision) or revision < 0:
        raise ConfigurationError("missing or invalid revision")
    types, fields = config.get("types"), config.get("fields")
    if not isinstance(types, list) or not types:
        raise ConfigurationError("configuration must contain at least one type")
    if not isinstance(fields, list):
        raise ConfigurationError("fields must be an array")

    field_ids: set[str] = set()
    field_names: set[str] = set()
    for item in fields:
        if not isinstance(item, Mapping):
            raise ConfigurationError("field must be an object")
        field_id, name, instructions = item.get("id"), item.get("name"), item.get("instructions")
        if _blank(field_id) or _blank(name) or _blank(instructions):
            raise ConfigurationError("field ID, name, and instructions must be nonblank")
        if field_id in field_ids:
            raise ConfigurationError(f"duplicate field ID {field_id!r}")
        normalized = normalize_configuration_name(name)
        if normalized in field_names:
            raise ConfigurationError(f"duplicate field name {name!r}")
        field_ids.add(field_id)
        field_names.add(normalized)

    type_ids: set[str] = set()
    names_by_group: set[tuple[str, str]] = set()
    for item in types:
        if not isinstance(item, Mapping):
            raise ConfigurationError("type must be an object")
        type_id, name, group, guidance = item.get("id"), item.get("name"), item.get("group"), item.get("guidelines")
        if _blank(type_id) or _blank(name) or _blank(guidance):
            raise ConfigurationError("type ID, name, and guidelines must be nonblank")
        if not isinstance(group, str) or group not in _GROUPS:
            raise ConfigurationError(f"invalid type group {group!r}")
        if type_id in type_ids:
            raise ConfigurationError(f"duplicate type ID {type_id!r}")
        name_key = (group, normalize_configuration_name(name))
        if name_key in names_by_group:
            raise ConfigurationError(f"duplicate type name {name!r} in {group}")
        type_ids.add(type_id)
        names_by_group.add(name_key)

        template = item.get("template")
        sequence_fields = item.get("sequenceFieldIDs")
        if not isinstance(template, list) or not isinstance(sequence_fields, list):
            raise ConfigurationError(f"type {type_id!r} has invalid template or sequenceFieldIDs")
        meaningful = False
        for component in template:
            if not isinstance(component, Mapping):
                raise ConfigurationError(f"type {type_id!r} has non-object template component")
            kind = component.get("kind")
            value = component.get("value")
            if kind == "literal":
                if not isinstance(value, str) or value == "":
                    raise ConfigurationError(f"type {type_id!r} has empty literal")
                meaningful = meaningful or not _blank(value)
            elif kind == "field":
                if _blank(value) or value not in field_ids:
                    raise ConfigurationError(f"type {type_id!r} references unknown field {value!r}")
                meaningful = True
            elif kind == "sequence":
                if value is not None:
                    raise ConfigurationError(f"type {type_id!r} sequence component must have nil value")
                meaningful = True
            else:
                raise ConfigurationError(f"type {type_id!r} has invalid component kind {kind!r}")
        if not meaningful:
            raise ConfigurationError(f"type {type_id!r} has no meaningful naming component")
        seen_sequence: set[str] = set()
        for field_id in sequence_fields:
            if _blank(field_id) or field_id not in field_ids:
                raise ConfigurationError(f"type {type_id!r} references unknown sequence field {field_id!r}")
            if field_id in seen_sequence:
                raise ConfigurationError(f"type {type_id!r} has duplicate sequence field {field_id!r}")
            seen_sequence.add(field_id)


def split_discovery_types(config: object, *, discovery_prompt_version: str = "configured-v1") -> tuple[list[dict], list[dict]]:
    """Validate then return (tuned, configured) type definitions in config order."""
    validate_configuration(config)
    types = config["types"]  # validated list of dictionaries
    tuned_ids = TUNED_IDS - {"intro"} if discovery_prompt_version == BROAD_INTRO_DISCOVERY_VERSION else TUNED_IDS
    return ([item for item in types if item["id"] in tuned_ids],
            [item for item in types if item["id"] not in tuned_ids])


def configured_tuned_specs(config: object) -> dict[ProductType, ProductSpec]:
    """Pinned tuned bounds with the current configuration's tuned guidance."""
    tuned, _ = split_discovery_types(config)
    specs: dict[ProductType, ProductSpec] = {}
    for item in tuned:
        product_type = ProductType(item["id"])
        default = DEFAULT_SPECS[product_type]
        specs[product_type] = ProductSpec(
            product_type=product_type,
            target_min_sec=default.target_min_sec,
            target_max_sec=default.target_max_sec,
            # Configured searches preserve the legacy target and maximum, but a
            # complete short handoff is useful editorially.  The legacy
            # INTRO_SPEC remains pinned at twelve seconds for its cached eval.
            hard_min_sec=1 if product_type is ProductType.INTRO else default.hard_min_sec,
            hard_max_sec=default.hard_max_sec,
            description=item["guidelines"],
        )
    return specs
