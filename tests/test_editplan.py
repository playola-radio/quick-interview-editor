from logic_markers.editplan import (
    ResolvedSegment,
    build_edit_plan,
    parse_edit_file,
    resolve_blocks,
)
from logic_markers.silence import Silence
from logic_markers.words import Segment, Transcript, Word


def _transcript() -> Transcript:
    # seg1 and seg3 are the SAME phrase — tests id-based disambiguation.
    words = (
        Word(1, "the", 0.0, 0.1), Word(2, "quick", 0.2, 0.3),
        Word(3, "brown", 0.4, 0.5), Word(4, "fox", 0.6, 0.7),
        Word(5, "and", 1.0, 1.1), Word(6, "then", 1.2, 1.3),
        Word(7, "the", 2.0, 2.1), Word(8, "quick", 2.2, 2.3),
        Word(9, "brown", 2.4, 2.5), Word(10, "fox", 2.6, 2.7),
    )
    segments = (
        Segment(1, (1, 2, 3, 4), "the quick brown fox"),
        Segment(2, (5, 6), "and then"),
        Segment(3, (7, 8, 9, 10), "the quick brown fox"),
    )
    return Transcript(words=words, segments=segments)


def test_parse_ignores_comments_and_splits_on_blank_lines():
    text = (
        "# instructions\n# more\n\n"
        "[1] the quick brown fox\n\n"
        "[3] the quick brown fox\n"
    )
    blocks = parse_edit_file(text)
    assert len(blocks) == 2
    assert blocks[0][0].segment_id == 1
    assert blocks[1][0].segment_id == 3


def test_keep_whole_line_covers_the_segment_span():
    blocks = parse_edit_file("[1] the quick brown fox\n")
    (b,) = resolve_blocks(blocks, _transcript())
    assert b.word_ids == [1, 2, 3, 4]
    assert b.start == 0.0 and b.end == 0.7


def test_repeated_phrase_disambiguated_by_id():
    blocks = parse_edit_file("[3] the quick brown fox\n")
    (b,) = resolve_blocks(blocks, _transcript())
    assert b.word_ids == [7, 8, 9, 10]  # NOT 1..4
    assert b.start == 2.0


def test_intra_line_deletion_trims_the_span():
    blocks = parse_edit_file("[1] brown fox\n")
    (b,) = resolve_blocks(blocks, _transcript())
    assert b.word_ids == [3, 4]
    assert b.start == 0.4 and b.end == 0.7


def test_consecutive_lines_merge_into_one_contiguous_block():
    blocks = parse_edit_file("[1] the quick brown fox\n[2] and then\n")
    (b,) = resolve_blocks(blocks, _transcript())
    assert b.word_ids == [1, 2, 3, 4, 5, 6]
    assert b.start == 0.0 and b.end == 1.3


def test_blank_line_produces_two_output_blocks():
    blocks = parse_edit_file("[1] the quick brown fox\n\n[3] the quick brown fox\n")
    resolved = resolve_blocks(blocks, _transcript())
    assert len(resolved) == 2
    assert [r.index for r in resolved] == [0, 1]


def test_missing_tag_warns_but_still_resolves():
    blocks = parse_edit_file("and then\n")
    (b,) = resolve_blocks(blocks, _transcript())
    assert b.word_ids == [5, 6]
    assert any("tag" in w.lower() for w in b.warnings)


def test_unknown_segment_id_is_warned_and_skipped():
    blocks = parse_edit_file("[9] nonexistent segment\n")
    resolved = resolve_blocks(blocks, _transcript())
    assert resolved == []  # nothing resolvable -> no output block


def test_build_edit_plan_has_versioned_shape_and_word_samples():
    seg = ResolvedSegment(
        index=0, output_name="song.1.aiff", word_ids=[1, 2],
        content_start_sample=0, content_end_sample=30870,
        start_sample=0, end_sample=33000, start_status="snapped",
        end_status="padded", overlaps_previous=False, overlaps_next=False,
        segment_ids=[1], warnings=[],
    )
    plan = build_edit_plan(
        source_path="song.m4a", sample_rate=44100, channels=2,
        total_samples=1_000_000, params={"roll_ms": 20},
        transcript=_transcript(), silences=[Silence(0, 4410)], segments=[seg],
    )
    assert plan["schema_version"] == 1
    assert plan["source"]["sample_rate"] == 44100
    assert plan["segments"][0]["output_name"] == "song.1.aiff"
    assert plan["segments"][0]["source_end_sample"] == 33000
    # word carries both seconds and sample positions
    w0 = plan["words"][0]
    assert w0["start"] == 0.0 and w0["start_sample"] == 0
    assert plan["words"][1]["start_sample"] == round(0.2 * 44100)
