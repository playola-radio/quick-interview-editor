from logic_markers.editplan import parse_edit_file, resolve_blocks
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
