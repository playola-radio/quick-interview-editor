import json

from cut_suggester.transcript import load_transcript, sentences_from_dict


def _fixture_dict() -> dict:
    # Two segments; word ids are stable and carry seconds.
    return {
        "words": [
            {"id": 1, "text": "So", "start": 0.0, "end": 0.5},
            {"id": 2, "text": "now", "start": 0.5, "end": 1.0},
            {"id": 3, "text": "we're", "start": 1.0, "end": 1.5},
            {"id": 4, "text": "here.", "start": 1.5, "end": 2.0},
            {"id": 5, "text": "Second", "start": 3.0, "end": 3.4},
            {"id": 6, "text": "one.", "start": 3.4, "end": 4.0},
        ],
        "segments": [
            {"id": 1, "word_ids": [1, 2, 3, 4], "text": "So now we're here."},
            {"id": 2, "word_ids": [5, 6], "text": "Second one."},
        ],
    }


def test_sentences_carry_word_ids_and_samples_from_seconds():
    sents = sentences_from_dict(_fixture_dict(), sample_rate=1000)
    assert [s.index for s in sents] == [0, 1]
    first = sents[0]
    assert first.segment_id == 1
    assert first.word_ids == (1, 2, 3, 4)
    assert first.start_sec == 0.0 and first.end_sec == 2.0
    assert first.start_sample == 0 and first.end_sample == 2000  # 2.0s * 1000
    assert sents[1].start_sample == 3000  # 3.0s * 1000


def test_missing_final_end_falls_back_to_start_not_zero():
    d = {
        "words": [{"id": 1, "text": "final", "start": 2.0, "end": None}],
        "segments": [{"id": 1, "word_ids": [1], "text": "final"}],
    }
    (s,) = sentences_from_dict(d, sample_rate=1000)
    assert s.end_sec == 2.4  # start + fallback, not collapsed to 0 / to start
    assert s.end_sample == 2400


def test_empty_segments_are_skipped_and_indices_stay_contiguous():
    d = {
        "words": [{"id": 1, "text": "hi", "start": 0.0, "end": 0.5}],
        "segments": [
            {"id": 1, "word_ids": [], "text": ""},
            {"id": 2, "word_ids": [1], "text": "hi"},
        ],
    }
    sents = sentences_from_dict(d, sample_rate=1000)
    assert [s.index for s in sents] == [0]
    assert sents[0].segment_id == 2


def test_load_transcript_reads_a_json_file(tmp_path):
    p = tmp_path / "t.json"
    p.write_text(json.dumps(_fixture_dict()))
    sents = load_transcript(str(p), sample_rate=1000)
    assert len(sents) == 2
