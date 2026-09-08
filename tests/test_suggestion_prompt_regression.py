from pathlib import Path
import copy
import json

from cut_suggester.models import DEFAULT_SPECS, ProductType, Sentence, TopicPartition
from cut_suggester.prompts import stage2_prompt
from cut_suggester.suggestion_config import configured_tuned_specs


_FIXTURE = Path(__file__).parent / "fixtures" / "suggestion-default-stage2.txt"


def test_untouched_default_prompt_matches_baseline():
    sentences = [
        Sentence(0, 1, "I wrote this song on the road.", (1,), 0, 20, 0, 20000)
    ]
    partitions = [TopicPartition(0, 0, "Writing")]

    assert stage2_prompt(sentences, partitions, DEFAULT_SPECS) == _FIXTURE.read_text(
        encoding="utf-8"
    )


def test_configured_default_with_images_and_custom_keeps_tuned_prompt_bytes():
    config = json.loads((Path(__file__).parent / "fixtures" / "suggestion-contract-v2.json").read_text())["configuration"]
    custom = copy.deepcopy(config["types"][0])
    custom["id"] = "custom-story"
    custom["name"] = "Custom Story"
    config["types"].append(custom)
    sentences = [Sentence(0, 1, "I wrote this song on the road.", (1,), 0, 20, 0, 20000)]
    partitions = [TopicPartition(0, 0, "Writing")]

    assert stage2_prompt(sentences, partitions, configured_tuned_specs(config)) == _FIXTURE.read_text()


def test_spotlight_only_prompt_mentions_only_spotlight_without_intro_guidance():
    specs = {ProductType.SPOTLIGHT: DEFAULT_SPECS[ProductType.SPOTLIGHT]}
    sentences = [Sentence(0, 1, "Story", (1,), 0, 20, 0, 20000)]

    prompt = stage2_prompt(sentences, [TopicPartition(0, 0, "Topic")], specs)

    assert '"type": "spotlight"' in prompt
    assert '"intro"' not in prompt
    assert "For an intro" not in prompt


def test_intro_only_prompt_mentions_intro_and_intro_guidance():
    specs = {ProductType.INTRO: DEFAULT_SPECS[ProductType.INTRO]}
    sentences = [Sentence(0, 1, "Story", (1,), 0, 20, 0, 20000)]

    prompt = stage2_prompt(sentences, [TopicPartition(0, 0, "Topic")], specs)

    assert '"type": "intro"' in prompt
    assert '"spotlight"' not in prompt
    assert "For an intro" in prompt


def test_edited_configured_guidance_appears_in_tuned_prompt():
    config = json.loads((Path(__file__).parent / "fixtures" / "suggestion-contract-v2.json").read_text())["configuration"]
    next(item for item in config["types"] if item["id"] == "intro")["guidelines"] = "Edited intro guidance"
    sentences = [Sentence(0, 1, "Story", (1,), 0, 20, 0, 20000)]

    prompt = stage2_prompt(sentences, [TopicPartition(0, 0, "Topic")], configured_tuned_specs(config))

    assert "Edited intro guidance" in prompt
