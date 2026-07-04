from logic_markers.words import (
    Segment,
    Transcript,
    Word,
    render_transcript,
)


def _sample_transcript() -> Transcript:
    words = (
        Word(1, "So", 0.10, 0.30),
        Word(2, "young", 0.40, 0.80),
        Word(3, "Hayes", 0.90, 1.20),
        Word(4, "What", 2.00, 2.30),
        Word(5, "now", 2.40, 2.70),
    )
    segments = (
        Segment(1, (1, 2, 3), "So young Hayes"),
        Segment(2, (4, 5), "What now"),
    )
    return Transcript(words=words, segments=segments)


def test_render_transcript_tags_each_segment_with_its_id():
    text = render_transcript(_sample_transcript())
    lines = [ln for ln in text.splitlines() if ln and not ln.startswith("#")]
    assert lines == ["[1] So young Hayes", "[2] What now"]


def test_render_transcript_includes_editing_instructions_header():
    text = render_transcript(_sample_transcript())
    assert text.splitlines()[0].startswith("#")
    assert "blank line" in text.lower()


def test_transcript_dict_round_trip_preserves_word_times_and_ids():
    t = _sample_transcript()
    restored = Transcript.from_dict(t.to_dict())
    assert restored == t
    # end times and ids survive
    assert restored.words[0].id == 1
    assert restored.words[0].end == 0.30
    assert restored.segments[1].word_ids == (4, 5)


def test_word_end_may_be_missing():
    w = Word(1, "hi", 0.0, None)
    restored = Word.from_dict(w.to_dict())
    assert restored.end is None


def test_words_by_id_lookup():
    t = _sample_transcript()
    assert t.word(3).text == "Hayes"
    assert t.word(4).start == 2.00
