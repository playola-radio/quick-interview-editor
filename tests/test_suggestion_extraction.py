import json

import pytest

from cut_suggester.extraction import (
    parse_extraction_response,
    plan_extraction_batches,
    required_field_ids,
)
from cut_suggester.models import Sentence


def test_parser_preserves_explicit_missing_field_evidence():
    expected = {"c1": {"artist-name"}}

    assert parse_extraction_response(
        json.dumps({"results": [{"candidate_id": "c1", "fields": [{"field_id": "artist-name", "value": None}]}]}),
        expected,
    ) == {"c1": {"artist-name": None}}


def test_parser_rejects_missing_expected_candidate():
    with pytest.raises(ValueError):
        parse_extraction_response('{"results": []}', {"c1": {"artist-name"}})


@pytest.mark.parametrize("response", [
    '{"results":[{"candidate_id":"c1","fields":[]}]}',
    '{"results":[{"candidate_id":"other","fields":[{"field_id":"artist-name","value":"x"}]}]}',
    '{"results":[{"candidate_id":"c1","fields":[{"field_id":"other","value":"x"}]}]}',
    '{"results":[{"candidate_id":"c1","fields":[{"field_id":"artist-name","value":4}]}]}',
    '[]',
])
def test_parser_rejects_incomplete_foreign_wrong_typed_and_malformed_responses(response):
    with pytest.raises(ValueError):
        parse_extraction_response(response, {"c1": {"artist-name"}})


@pytest.mark.parametrize("response", [
    '{"results":[{"candidate_id":"c1","fields":[{"field_id":"artist-name","value":"x"},{"field_id":"artist-name","value":"y"}]}]}',
    '{"results":[{"candidate_id":"c1","fields":[{"field_id":"artist-name","value":"x"}]},{"candidate_id":"c1","fields":[{"field_id":"artist-name","value":"x"}]}]}',
    '{"results":[{"candidate_id":"c1","fields":[{"field_id":"artist-name","value":"x"}],"fields":[]}]}',
])
def test_parser_rejects_duplicate_records_and_json_keys(response):
    with pytest.raises(ValueError):
        parse_extraction_response(response, {"c1": {"artist-name"}})


def test_parser_trims_foundation_whitespace_and_treats_empty_as_missing():
    response = '{"results":[{"candidate_id":"c1","fields":[{"field_id":"artist-name","value":"\\u200b  American Aquarium \\u200b"}]}]}'

    assert parse_extraction_response(response, {"c1": {"artist-name"}}) == {
        "c1": {"artist-name": "American Aquarium"}
    }
    assert parse_extraction_response(
        '{"results":[{"candidate_id":"c1","fields":[{"field_id":"artist-name","value":"\\u200b \\u200b"}]}]}',
        {"c1": {"artist-name"}},
    ) == {"c1": {"artist-name": None}}


def test_required_field_ids_include_template_and_grouping_fields_only():
    assert required_field_ids({
        "template": [{"kind": "field", "value": "song-title"}, {"kind": "sequence"}],
        "sequenceFieldIDs": ["artist-name"],
    }) == ["artist-name", "song-title"]


def _sentences():
    return [
        Sentence(i, i + 100, text, (i,), i, i + 1, i * 1000, (i + 1) * 1000)
        for i, text in enumerate(["before one", "before two", "Song Nobody Wins by American Aquarium", "after one", "after two", "later evidence"])
    ]


def _type():
    return {"id": "intro", "template": [{"kind": "field", "value": "song-title"}], "sequenceFieldIDs": ["artist-name"]}


def _fields():
    return [
        {"id": "song-title", "instructions": "Find the recording title."},
        {"id": "artist-name", "instructions": "Find the performer, never infer it from a speaker."},
        {"id": "descriptive-title", "instructions": "Do not use this unless requested."},
    ]


def test_batch_plan_includes_snapshot_instructions_candidate_then_context_and_speaker_evidence():
    batches = plan_extraction_batches(
        [{"candidate_id": "c1", "product_type": "intro", "start_index": 2, "end_index": 2}],
        [_type()], _fields(), _sentences(), speaker_ids={102: "Radney Foster"},
    )

    assert len(batches.batches) == 1
    batch = batches.batches[0]
    assert batch.candidate_ids == ("c1",)
    assert batch.expected == {"c1": {"artist-name", "song-title"}}
    assert "Find the recording title." in batch.prompt
    assert "never infer it from a speaker" in batch.prompt
    assert batch.prompt.index("Song Nobody Wins") < batch.prompt.index("before one")
    assert "speaker_id: Radney Foster" in batch.prompt
    assert "do not treat speaker identity as performer evidence" in batch.prompt
    assert "For candidate c1, return exactly these field IDs: artist-name, song-title." in batch.prompt
    assert '"value":null' in batch.prompt


def test_batch_context_prioritizes_neighbors_for_every_candidate_before_remaining_source():
    sentences = _sentences() + [
        Sentence(6, 106, "farther source order", (6,), 6, 7, 6000, 7000),
        Sentence(7, 107, "final source order", (7,), 7, 8, 7000, 8000),
    ]
    plan = plan_extraction_batches(
        [
            {"candidate_id": "c1", "product_type": "intro", "start_index": 1, "end_index": 1},
            {"candidate_id": "c2", "product_type": "intro", "start_index": 4, "end_index": 4},
        ], [_type()], _fields(), sentences, max_input_characters=1800,
    )

    prompt = plan.batches[0].prompt
    assert prompt.index("Candidate c2 context: [2]") < prompt.index("Additional context: [7]")


def test_batch_plan_has_no_requests_when_no_fields_are_referenced():
    batches = plan_extraction_batches(
        [{"candidate_id": "c1", "product_type": "spotlight", "start_index": 2, "end_index": 2}],
        [{"id": "spotlight", "template": [{"kind": "sequence"}], "sequenceFieldIDs": []}],
        _fields(), _sentences(),
    )

    assert batches.batches == ()
    assert batches.input_size_diagnostics == ()


def test_batch_expected_metadata_can_be_passed_directly_to_the_parser():
    batch = plan_extraction_batches(
        [{"candidate_id": "c1", "product_type": "intro", "start_index": 2, "end_index": 2}],
        [_type()], _fields(), _sentences(),
    ).batches[0]

    assert parse_extraction_response(
        '{"results":[{"candidate_id":"c1","fields":[{"field_id":"artist-name","value":null},{"field_id":"song-title","value":"Nobody Wins"}]}]}',
        batch.expected,
    )["c1"]["song-title"] == "Nobody Wins"


def test_batch_plan_reports_oversize_mandatory_candidate_evidence_without_a_batch():
    plan = plan_extraction_batches(
        [{"candidate_id": "c1", "product_type": "intro", "start_index": 2, "end_index": 2}],
        [_type()], _fields(), _sentences(), max_input_characters=40,
    )

    assert plan.batches == ()
    assert plan.input_size_diagnostics[0].candidate_id == "c1"


def test_batch_plan_splits_at_the_hard_twenty_candidate_limit():
    candidates = [
        {"candidate_id": f"c{i}", "product_type": "intro", "start_index": 2, "end_index": 2}
        for i in range(21)
    ]

    plan = plan_extraction_batches(candidates, [_type()], _fields(), _sentences())

    assert [len(batch.candidate_ids) for batch in plan.batches] == [20, 1]
    assert plan.batches[0].candidate_ids[0] == "c0"
    assert plan.batches[-1].candidate_ids == ("c20",)


def test_mandatory_limit_splits_valid_candidates_without_truncating_candidate_evidence():
    candidates = [
        {"candidate_id": "c1", "product_type": "intro", "start_index": 2, "end_index": 2},
        {"candidate_id": "c2", "product_type": "intro", "start_index": 2, "end_index": 2},
    ]
    one = plan_extraction_batches(candidates[:1], [_type()], _fields(), _sentences()).batches[0]
    both = plan_extraction_batches(candidates, [_type()], _fields(), _sentences(), max_input_characters=one.mandatory_characters + 2)

    assert [batch.candidate_ids for batch in both.batches] == [("c1",), ("c2",)]
    assert all("Song Nobody Wins by American Aquarium" in batch.prompt for batch in both.batches)


def test_oversize_candidate_does_not_discard_valid_neighbors():
    sentences = _sentences()
    sentences[2] = Sentence(2, 102, "x" * 500, (2,), 2, 3, 2000, 3000)
    candidates = [
        {"candidate_id": "first", "product_type": "intro", "start_index": 0, "end_index": 0},
        {"candidate_id": "oversize", "product_type": "intro", "start_index": 2, "end_index": 2},
        {"candidate_id": "last", "product_type": "intro", "start_index": 1, "end_index": 1},
    ]

    plan = plan_extraction_batches(candidates, [_type()], _fields(), sentences, max_input_characters=900)

    assert [batch.candidate_ids for batch in plan.batches] == [("first",), ("last",)]
    assert [diagnostic.candidate_id for diagnostic in plan.input_size_diagnostics] == ["oversize"]


def test_mixed_types_keep_distinct_required_field_sets_per_candidate():
    types = [
        _type(),
        {"id": "custom", "template": [{"kind": "field", "value": "descriptive-title"}], "sequenceFieldIDs": []},
    ]
    plan = plan_extraction_batches([
        {"candidate_id": "intro", "product_type": "intro", "start_index": 2, "end_index": 2},
        {"candidate_id": "custom", "product_type": "custom", "start_index": 3, "end_index": 3},
    ], types, _fields(), _sentences())

    batch = plan.batches[0]
    assert batch.expected == {
        "intro": frozenset({"artist-name", "song-title"}),
        "custom": frozenset({"descriptive-title"}),
    }
    assert "For candidate intro, return exactly these field IDs: artist-name, song-title." in batch.prompt
    assert "For candidate custom, return exactly these field IDs: descriptive-title." in batch.prompt
