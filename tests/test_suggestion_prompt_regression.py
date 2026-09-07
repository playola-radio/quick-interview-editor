from pathlib import Path

from cut_suggester.models import DEFAULT_SPECS, Sentence, TopicPartition
from cut_suggester.prompts import stage2_prompt


_FIXTURE = Path(__file__).parent / "fixtures" / "suggestion-default-stage2.txt"


def test_untouched_default_prompt_matches_baseline():
    sentences = [
        Sentence(0, 1, "I wrote this song on the road.", (1,), 0, 20, 0, 20000)
    ]
    partitions = [TopicPartition(0, 0, "Writing")]

    assert stage2_prompt(sentences, partitions, DEFAULT_SPECS) == _FIXTURE.read_text(
        encoding="utf-8"
    )
