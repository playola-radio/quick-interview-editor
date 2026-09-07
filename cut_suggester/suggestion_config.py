"""Validate the shared suggestion-configuration wire format and route discovery.

The configurable set is deliberately open-ended.  Only the two exact historic
IDs use the tuned paragraph pass; all other IDs, including lookalike names, are
left for configured discovery.
"""

from __future__ import annotations

import unicodedata
from collections.abc import Mapping

from .models import DEFAULT_SPECS, ProductSpec, ProductType

TUNED_IDS = frozenset(("spotlight", "intro"))
IMAGING_IDS = frozenset(("image-id", "image-pre-commercial", "image-post-commercial", "image-promo"))
_GROUPS = frozenset(("spotlights", "songIntros", "audioImages"))


class ConfigurationError(ValueError):
    """The shared configuration cannot safely be sent to a model."""


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _blank(value: object) -> bool:
    return not isinstance(value, str) or not value.strip()


def normalize_configuration_name(value: str) -> str:
    """Swift-compatible display-name identity (case/diacritic/width/space)."""
    width_folded = "".join(
        "".join(chr(int(codepoint, 16)) for codepoint in decomposition.split()[1:])
        if decomposition.startswith(("<wide> ", "<narrow> ")) else char
        for char in value
        for decomposition in (unicodedata.decomposition(char),)
    )
    without_marks = "".join(
        char for char in unicodedata.normalize("NFD", width_folded)
        if not unicodedata.combining(char)
    )
    return " ".join(without_marks.split()).casefold()


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
                meaningful = meaningful or bool(value.strip())
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


def split_discovery_types(config: object) -> tuple[list[dict], list[dict]]:
    """Validate then return (tuned, configured) type definitions in config order."""
    validate_configuration(config)
    types = config["types"]  # validated list of dictionaries
    return ([item for item in types if item["id"] in TUNED_IDS],
            [item for item in types if item["id"] not in TUNED_IDS])


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
            hard_min_sec=default.hard_min_sec,
            hard_max_sec=default.hard_max_sec,
            description=item["guidelines"],
        )
    return specs
