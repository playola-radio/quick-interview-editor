import json
import uuid
from pathlib import Path

import pytest

from cut_suggester.llm import LLMResponse
from cut_suggester.models import Sentence
from cut_suggester.transcript import load_transcript


SR = 1000


def _sentences(count=240, seconds=2):
    return [
        Sentence(i, i + 1, f"synthetic sentence {i}", (i * 2 + 1, i * 2 + 2),
                 i * seconds, (i + 1) * seconds,
                 i * seconds * SR, (i + 1) * seconds * SR)
        for i in range(count)
    ]


class _Responses:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.prompts = []

    def complete(self, prompt, *, purpose=""):
        self.prompts.append(prompt)
        return LLMResponse(json.dumps({"clips": next(self.responses)}))


def test_discovery_dedupes_overlap_windows_but_preserves_repeated_take():
    from cut_suggester.configured_discovery import discover_configured

    llm = _Responses([
        [
            {"type": "image-id", "start": 119, "end": 121, "label": "Station ID"},
            {"type": "image-id", "start": 20, "end": 24, "label": "Station ID"},
        ],
        [{"type": "image-id", "start": 118, "end": 121, "label": "Station ID"}],
    ])

    candidates = discover_configured(
        _sentences(220), [{"id": "image-id", "guidelines": "Complete station IDs only."}], llm,
        run_id=uuid.UUID("12345678-1234-5678-1234-567812345678"), sample_rate=SR,
    )

    assert [(c["start_index"], c["end_index"]) for c in candidates] == [(20, 24), (118, 121)]
    assert all(c["candidate_id"] for c in candidates)


def test_output_uses_transcript_evidence_and_stable_uuid():
    from cut_suggester.configured_discovery import discover_configured

    sentence = Sentence(0, 99, "Evidence only", (7, 8), 4.5, 12.5, 4500, 12500)
    args = ([sentence], [{"id": "custom-voice", "guidelines": "A complete voice take."}],
            _Responses([[{"type": "custom-voice", "start": 0, "end": 0, "label": "Voice"}]]))
    first = discover_configured(*args, run_id="12345678-1234-5678-1234-567812345678", sample_rate=SR)
    second = discover_configured(
        [sentence], args[1], _Responses([[{"type": "custom-voice", "start": 0, "end": 0, "label": "Voice"}]]),
        run_id="12345678-1234-5678-1234-567812345678", sample_rate=SR,
    )

    assert set(first[0]) == {
        "product_type", "start_index", "end_index", "label", "song", "song_verified", "word_ids",
        "start_sample", "end_sample", "start_sec", "end_sec", "duration_sec", "rank", "score", "warnings", "candidate_id",
    }
    assert first[0]["word_ids"] == [7, 8]
    assert first[0]["start_sample"] == 4500 and first[0]["duration_sec"] == 8
    assert first[0]["candidate_id"] == second[0]["candidate_id"]


@pytest.mark.parametrize("clip", [
    {"type": "unknown", "start": 0, "end": 0, "label": "x"},
    {"type": "image-id", "start": True, "end": 0, "label": "x"},
    {"type": "image-id", "start": 0, "end": False, "label": "x"},
    {"type": "image-id", "start": 0.0, "end": 0, "label": "x"},
    {"type": "image-id", "start": -1, "end": 0, "label": "x"},
    {"type": "image-id", "start": 1, "end": 0, "label": "x"},
    {"type": "image-id", "start": 0, "end": 2, "label": "x"},
    {"type": "image-id", "start": 0, "end": 0, "label": "  "},
])
def test_rejects_malformed_provider_clips(clip):
    from cut_suggester.configured_discovery import DiscoveryError, discover_configured

    with pytest.raises(DiscoveryError):
        discover_configured(
            _sentences(2), [{"id": "image-id", "guidelines": "Complete ID."}], _Responses([[clip]]),
            run_id=uuid.uuid4(), sample_rate=SR,
        )


def test_rejects_clip_outside_specific_overlap_window():
    from cut_suggester.configured_discovery import DiscoveryError, discover_configured

    with pytest.raises(DiscoveryError, match="window"):
        discover_configured(
            _sentences(220), [{"id": "image-id", "guidelines": "Complete ID."}],
            _Responses([[], [{"type": "image-id", "start": 109, "end": 111, "label": "ID"}]]),
            run_id=uuid.uuid4(), sample_rate=SR,
        )


def test_empty_types_and_bad_request_parameters_make_no_provider_calls():
    from cut_suggester.configured_discovery import DiscoveryError, discover_configured

    llm = _Responses([])
    assert discover_configured(_sentences(), [], llm, run_id=uuid.uuid4(), sample_rate=SR) == []
    assert llm.prompts == []
    with pytest.raises(DiscoveryError):
        discover_configured(_sentences(), [], llm, run_id="not-a-uuid", sample_rate=SR)
    with pytest.raises(DiscoveryError):
        discover_configured(_sentences(), [], llm, run_id=uuid.uuid4(), sample_rate=SR, window=0)
    assert llm.prompts == []


def test_stops_after_terminal_window_and_rejects_gapped_window_parameters():
    from cut_suggester.configured_discovery import DiscoveryError, discover_configured

    llm = _Responses([[]])
    assert discover_configured(
        _sentences(120), [{"id": "custom-voice", "guidelines": "Complete voice."}], llm,
        run_id=uuid.uuid4(), sample_rate=SR,
    ) == []
    assert len(llm.prompts) == 1
    with pytest.raises(DiscoveryError, match="step"):
        discover_configured(_sentences(), [], llm, run_id=uuid.uuid4(), sample_rate=SR, window=10, step=11)


def test_custom_only_prompt_uses_requested_type_and_does_not_impose_imaging_rule():
    from cut_suggester.configured_discovery import discover_configured

    llm = _Responses([[]])
    discover_configured(
        _sentences(1), [{"id": "custom-voice", "guidelines": "URLs are required in these takes."}], llm,
        run_id=uuid.uuid4(), sample_rate=SR,
    )

    assert '"type":"custom-voice"' in llm.prompts[0]
    assert '"type":"image-id"' not in llm.prompts[0]
    assert "incidental self-identification" not in llm.prompts[0].lower()


def test_later_window_prompt_example_uses_global_coordinates_inside_that_window():
    from cut_suggester.configured_discovery import discover_configured

    llm = _Responses([[], []])
    discover_configured(
        _sentences(220), [{"id": "custom-voice", "guidelines": "Complete voice."}], llm,
        run_id=uuid.uuid4(), sample_rate=SR,
    )

    assert '"start":110,"end":111' in llm.prompts[1]


def test_mixed_prompt_keeps_custom_url_guidance_separate_from_imaging_exclusions():
    from cut_suggester.configured_discovery import discover_configured

    llm = _Responses([[]])
    discover_configured(
        _sentences(1), [
            {"id": "image-id", "guidelines": "Only complete station IDs."},
            {"id": "custom-web-story", "guidelines": "URLs and stories are required evidence."},
        ], llm, run_id=uuid.uuid4(), sample_rate=SR,
    )

    assert "URLs and stories are required evidence." in llm.prompts[0]
    assert "For built-in imaging types only" in llm.prompts[0]


def test_response_times_and_words_are_ignored_and_duration_boundaries_are_enforced():
    from cut_suggester.configured_discovery import discover_configured

    sentences = [
        Sentence(0, 1, "subsecond", (1,), 0, 0.5, 0, 500),
        Sentence(1, 2, "exact second", (2,), 0.5, 1.5, 500, 1500),
        Sentence(2, 3, "long take", (3,), 1.5, 241.5, 1500, 241500),
    ]
    llm = _Responses([[
        {"type": "custom", "start": 0, "end": 0, "label": "sub", "word_ids": [999], "start_sec": 999, "end_sec": 1000},
        {"type": "custom", "start": 1, "end": 1, "label": "one", "word_ids": [999], "start_sample": 999},
        {"type": "custom", "start": 2, "end": 2, "label": "max"},
    ]])
    out = discover_configured(sentences, [{"id": "custom", "guidelines": "Complete custom takes."}], llm,
                              run_id=uuid.uuid4(), sample_rate=SR)

    assert [(item["label"], item["duration_sec"], item["word_ids"], item["start_sec"]) for item in out] == [
        ("one", 1.0, [2], 0.5), ("max", 240.0, [3], 1.5)
    ]


def test_imaging_precedence_and_mutual_coverage_threshold_are_strict():
    from cut_suggester.configured_discovery import _resolve_overlaps, duplicate_imaging_classification

    def candidate(type_id, start, end):
        return {"product_type": type_id, "start_index": start, "end_index": end, "warnings": []}

    # Ten-sentence spans need eight shared sentences; seven is below the 80% threshold.
    assert not duplicate_imaging_classification(candidate("image-promo", 0, 9), candidate("image-pre-commercial", 3, 12))
    assert duplicate_imaging_classification(candidate("image-promo", 0, 9), candidate("image-pre-commercial", 2, 11))
    out = _resolve_overlaps([candidate("image-promo", 2, 11), candidate("image-pre-commercial", 2, 11)])
    assert [item["product_type"] for item in out] == ["image-pre-commercial"]


def test_synthetic_dataset_labels_reference_real_transcript_evidence_and_valid_durations():
    directory = Path("evals/cut_suggestions/datasets/suggestion_types")
    labels = json.loads((directory / "labels.json").read_text())
    transcript = json.loads((directory / "transcript.json").read_text())
    sentences = load_transcript(str(directory / "transcript.json"), sample_rate=SR)
    words = {word["id"]: word for word in transcript["words"]}

    assert labels["synthetic"] is True
    promo = next(item for item in labels["positives"] if item["type"] == "image-promo")
    nested = next(item for item in labels["positives"] if item["type"] == "image-id" and item["start"] == 15)
    spotlight = next(item for item in labels["positives"] if item["type"] == "spotlight")
    assert promo["end"] - promo["start"] + 1 == 15
    assert sentences[promo["end"]].end_sec - sentences[promo["start"]].start_sec == 37.5
    assert promo["start"] < nested["start"] <= nested["end"] < promo["end"]
    assert sentences[spotlight["end"]].end_sec - sentences[spotlight["start"]].start_sec >= 15
    assert "https://" in sentences[30].text and "Station One" in sentences[35].text
    assert any(item["start"] == 12 and item["forbiddenTypes"] == ["image-id"] for item in labels["negativeSpans"])
    assert any(item["start"] == 38 and "Unfinished handoff" in item["note"] for item in labels["negativeSpans"])
    assert sentences[37].text.startswith("Wait") and sentences[38].text.startswith("Coming up")
    assert labels["subtypeClassifications"][0]["winner"] == "image-pre-commercial"
    assert all(0 <= item["start"] <= item["end"] < len(sentences) for item in labels["positives"] + labels["negativeSpans"])
    assert all(segment["text"] == words[segment["word_ids"][0]]["text"] for segment in transcript["segments"])


def test_same_take_and_imaging_precedence_keep_nested_and_custom_overlaps():
    from cut_suggester.configured_discovery import (
        _resolve_overlaps,
        duplicate_imaging_classification,
        same_take,
    )

    def candidate(type_id, start, end):
        return {"product_type": type_id, "start_index": start, "end_index": end, "warnings": []}

    assert same_take(candidate("x", 0, 2), candidate("x", 1, 3))
    assert not same_take(candidate("x", 0, 2), candidate("x", 3, 5))
    assert duplicate_imaging_classification(candidate("x", 0, 9), candidate("x", 1, 10))
    assert not duplicate_imaging_classification(candidate("x", 0, 1), candidate("x", 0, 14))

    out = _resolve_overlaps([
        candidate("image-promo", 0, 14), candidate("image-id", 4, 5),
        candidate("image-pre-commercial", 20, 24), candidate("image-post-commercial", 20, 24),
        candidate("custom-voice", 20, 24),
    ])
    assert {(c["product_type"], c["start_index"], c["end_index"]) for c in out} == {
        ("image-promo", 0, 14), ("image-id", 4, 5),
        ("image-post-commercial", 20, 24), ("custom-voice", 20, 24),
    }
    post = next(c for c in out if c["product_type"] == "image-post-commercial")
    assert "ambiguous" in post["warnings"][0]


def test_generic_duration_enforcement_is_one_to_240_seconds():
    from cut_suggester.configured_discovery import discover_configured

    sentences = _sentences(122, seconds=2)
    clips = [
        {"type": "image-promo", "start": 0, "end": 0, "label": "two seconds"},
        {"type": "image-promo", "start": 1, "end": 121, "label": "too long"},
    ]
    out = discover_configured(sentences, [{"id": "image-promo", "guidelines": "Promo."}], _Responses([clips, []]),
                              run_id=uuid.uuid4(), sample_rate=SR, window=130, step=130)
    assert [(c["start_index"], c["end_index"]) for c in out] == [(0, 0)]


def test_new_imaging_prompt_preserves_repeats_full_promo_and_later_window_coordinates():
    from cut_suggester.configured_discovery import _prompt
    types = {'image-id': 'Complete IDs.', 'image-promo': 'Full promos.'}
    new = _prompt(_sentences(), types, 110, 219, discovery_prompt_version='configured-v2')
    assert 'Each independently complete performance' in new
    assert 'Return BOTH every complete independently usable ID' in new
    assert 'FULL continuous promo' in new
    assert '[110] says' in new and '110–111 and 112–113' in new
    old = _prompt(_sentences(), types, 110, 219)
    assert 'Each independently complete performance' not in old
    assert _prompt(_sentences(), types, 110, 219, discovery_prompt_version='v2') == old
    short = _prompt(_sentences(), types, 239, 239, discovery_prompt_version='configured-v2')
    assert 'For example' not in short


def test_custom_only_new_version_prompt_is_byte_identical_to_old():
    from cut_suggester.configured_discovery import _prompt
    types = {'custom-voice': 'URLs and stories are required.'}
    assert _prompt(_sentences(), types, 0, 3, discovery_prompt_version='configured-v2') == _prompt(_sentences(), types, 0, 3)
