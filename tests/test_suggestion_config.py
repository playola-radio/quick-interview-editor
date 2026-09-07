import copy
import json
from pathlib import Path

import pytest

from cut_suggester.models import ProductType
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


def test_configuration_name_normalization_matches_foundation_width_and_folding_rules():
    assert normalize_configuration_name("  Café  Ｆ  ﬁ  ß ") == "cafe f fi ss"
    assert normalize_configuration_name("①") == "①"
    assert normalize_configuration_name("㎒") == "㎒"
    assert normalize_configuration_name("ǅ") == "ǆ"


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
