from logic_markers.cli import build_markers
from logic_markers.transcribe import Word


def test_build_markers_maps_seconds_to_sample_frames():
    words = [Word("Hello", 0.5), Word("world", 1.2)]
    markers = build_markers(words, sample_rate=44100)
    assert [(m.id, m.position, m.name) for m in markers] == [
        (1, 22050, "Hello"),
        (2, 52920, "world"),
    ]


def test_build_markers_ids_are_positive_and_unique():
    words = [Word("a", 0.0), Word("b", 0.1), Word("c", 0.2)]
    ids = [m.id for m in build_markers(words, 44100)]
    assert ids == [1, 2, 3]


def test_build_markers_strips_whitespace():
    markers = build_markers([Word("  hi ", 0.0)], 44100)
    assert markers[0].name == "hi"


def test_duplicate_timestamps_get_distinct_increasing_positions():
    # Whisper sometimes gives consecutive words the same start time.
    words = [Word("Ray", 4.06), Word("opens", 4.06), Word("up", 4.06)]
    positions = [m.position for m in build_markers(words, 44100)]
    assert positions == sorted(positions)
    assert len(set(positions)) == 3  # all distinct


def test_word_order_is_preserved_when_positions_collide():
    words = [Word("Ray", 4.06), Word("opens", 4.06), Word("up", 4.10)]
    markers = build_markers(words, 44100)
    # names stay in spoken order, positions strictly increase
    assert [m.name for m in markers] == ["Ray", "opens", "up"]
    assert markers[0].position < markers[1].position < markers[2].position


def test_out_of_order_timestamps_are_forced_monotonic():
    # a later word reporting an earlier start must not jump ahead
    words = [Word("first", 2.0), Word("second", 1.9)]
    markers = build_markers(words, 44100)
    assert markers[0].position < markers[1].position
    assert [m.name for m in markers] == ["first", "second"]
