import copy
import json
from pathlib import Path

import pytest

from cut_suggester.models import DEFAULT_SPECS, ProductType, Sentence
from cut_suggester.postprocess import build_candidate, enforce_duration_window
from cut_suggester.suggestion_config import (
    ConfigurationError,
    configured_tuned_specs,
    split_discovery_types,
    normalize_configuration_name,
    validate_configuration,
)


def _config():
    return json.loads((Path(__file__).parent / "fixtures" / "suggestion-contract-v2.json").read_text())["configuration"]


def test_custom_spotlight_name_does_not_route_to_tuned_pass():
    config = _config()
    custom = copy.deepcopy(next(t for t in config["types"] if t["id"] == "spotlight"))
    custom["id"] = "custom-story"
    config["types"] = [t for t in config["types"] if t["id"] != "spotlight"] + [custom]

    tuned, generic = split_discovery_types(config)

    assert [t["id"] for t in tuned] == ["intro"]
    assert "custom-story" in [t["id"] for t in generic]


def test_fixture_configuration_is_valid_and_images_are_generic():
    tuned, generic = split_discovery_types(_config())

    assert [item["id"] for item in tuned] == ["intro", "spotlight"]
    assert {item["id"] for item in generic} == {
        "image-id", "image-pre-commercial", "image-post-commercial", "image-promo"
    }


def test_restoring_exact_builtin_id_returns_type_to_tuned_route():
    config = _config()
    spotlight = next(item for item in config["types"] if item["id"] == "spotlight")
    spotlight["id"] = "custom-story"
    tuned, _ = split_discovery_types(config)
    assert [item["id"] for item in tuned] == ["intro"]

    spotlight["id"] = "spotlight"
    tuned, _ = split_discovery_types(config)
    assert [item["id"] for item in tuned] == ["intro", "spotlight"]


def test_configured_tuned_specs_use_only_present_exact_ids_and_edited_guidance():
    config = _config()
    config["types"] = [item for item in config["types"] if item["id"] != "intro"]
    config["types"][0]["guidelines"] = "Edited spotlight guidance"

    specs = configured_tuned_specs(config)

    assert set(specs) == {ProductType.SPOTLIGHT}
    assert specs[ProductType.SPOTLIGHT].description == "Edited spotlight guidance"


def test_configured_intro_allows_complete_eight_second_take_without_changing_legacy_spec():
    specs = configured_tuned_specs(_config())
    sentences = [
        Sentence(0, 1, "Complete handoff", (1,), 0, 8, 0, 8000),
    ]
    candidate = build_candidate(
        sentences, {"type": "intro", "start": 0, "end": 0, "label": "Complete handoff"},
        DEFAULT_SPECS, 1000,
    )

    assert specs[ProductType.INTRO].hard_min_sec == 1
    assert specs[ProductType.INTRO].target_min_sec == 15
    assert ProductType.INTRO.value == "intro"
    assert enforce_duration_window([candidate], specs)[0] == [candidate]
    assert enforce_duration_window([candidate], DEFAULT_SPECS)[1] == [candidate]


def test_configuration_name_normalization_matches_foundation_width_and_folding_rules():
    assert normalize_configuration_name("  Café  Ｆ  ﬁ  ß ") == "cafe f fi ss"
    assert normalize_configuration_name("①") == "①"
    assert normalize_configuration_name("㎒") == "㎒"
    assert normalize_configuration_name("ǅ") == "ǆ"
    assert normalize_configuration_name("A\u200bB") == "a b"
    assert normalize_configuration_name("A B") == "a b"
    assert normalize_configuration_name("A\u001cB") == "a\u001cb"


@pytest.mark.parametrize("base, marked", [("क", "क़"), ("ก", "ก้")])
def test_configuration_accepts_distinct_non_latin_marked_names(base, marked):
    config = _config()
    config["types"][0]["name"] = base
    duplicate_type = copy.deepcopy(config["types"][0])
    duplicate_type["id"] = "other-type"
    duplicate_type["name"] = marked
    config["types"].append(duplicate_type)
    config["fields"][0]["name"] = base
    duplicate_field = copy.deepcopy(config["fields"][0])
    duplicate_field["id"] = "other-field"
    duplicate_field["name"] = marked
    config["fields"].append(duplicate_field)

    validate_configuration(config)


def test_foundation_zero_width_space_is_blank_in_configuration_values():
    config = _config()
    config["types"][0]["guidelines"] = "\u200b"

    with pytest.raises(ConfigurationError):
        validate_configuration(config)


@pytest.mark.parametrize("mutate", [
    lambda c: c.__setitem__("schemaVersion", 2),
    lambda c: c.__setitem__("schemaVersion", True),
    lambda c: c.__setitem__("schemaVersion", "1"),
    lambda c: c.pop("schemaVersion"),
    lambda c: c.pop("revision"),
    lambda c: c.__setitem__("revision", True),
    lambda c: c.__setitem__("revision", 1.5),
    lambda c: c["types"].append(copy.deepcopy(c["types"][0])),
    lambda c: c["types"][0]["template"].__setitem__(0, {"kind": "field", "value": "missing"}),
    lambda c: c["types"][0]["template"].__setitem__(0, {"kind": "sequence", "value": "bad"}),
    lambda c: c["types"][0].__setitem__("group", "not-a-group"),
    lambda c: c["types"][0].__setitem__("group", []),
    lambda c: c["types"][0].__setitem__("sequenceFieldIDs", ["missing"]),
])
def test_invalid_configuration_is_rejected(mutate):
    config = _config()
    mutate(config)

    with pytest.raises(ConfigurationError):
        validate_configuration(config)


def test_configuration_rejects_duplicate_normalized_type_and_field_names():
    config = _config()
    duplicate_type = copy.deepcopy(config["types"][0])
    duplicate_type["id"] = "other-intro"
    duplicate_type["name"] = "  song  intro  "
    config["types"].append(duplicate_type)
    with pytest.raises(ConfigurationError, match="duplicate type name"):
        validate_configuration(config)

    config = _config()
    duplicate_field = copy.deepcopy(config["fields"][0])
    duplicate_field["id"] = "other-song"
    duplicate_field["name"] = "  SÓNG  TITLE "
    config["fields"].append(duplicate_field)
    with pytest.raises(ConfigurationError, match="duplicate field name"):
        validate_configuration(config)


@pytest.mark.parametrize("case", json.loads(
    (Path(__file__).parent / "fixtures" / "suggestion-whitespace.json").read_text()))
@pytest.mark.parametrize("collection,property_name", [
    ("types", "name"), ("types", "guidelines"), ("fields", "name"), ("fields", "instructions")])
def test_shared_configuration_whitespace_contract(case, collection, property_name):
    config = _config()
    config[collection][0][property_name] = case["value"]
    if case["isBlank"]:
        with pytest.raises(ConfigurationError):
            validate_configuration(config)
    else:
        validate_configuration(config)
    folded = normalize_configuration_name("A" + case["value"] + "B")
    assert (folded == "a b") == case["isBlank"]
