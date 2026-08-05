"""Pure post-processing: no network, no subprocess, no audio."""

from cut_suggester.models import (
    DEFAULT_SPECS,
    ProductType,
    Sentence,
)
from cut_suggester.postprocess import (
    build_candidate,
    dedupe_overlapping,
    enforce_duration_window,
    rank_candidates,
    validate_clip,
    verify_song,
)

SR = 1000  # 1000 samples/sec keeps the arithmetic obvious


def _sents(texts, sec_per=1.0):
    """One sentence per text, each `sec_per` seconds long, back to back."""
    out = []
    wid = 1
    for i, t in enumerate(texts):
        start = i * sec_per
        end = start + sec_per
        out.append(
            Sentence(
                index=i,
                segment_id=i + 1,
                text=t,
                word_ids=(wid, wid + 1),
                start_sec=start,
                end_sec=end,
                start_sample=round(start * SR),
                end_sample=round(end * SR),
            )
        )
        wid += 2
    return out


# --- JSON-span validation --------------------------------------------------
def test_validate_clip_accepts_a_well_formed_clip():
    ok, _ = validate_clip({"type": "spotlight", "start": 0, "end": 3, "label": "A story"})
    assert ok


def test_validate_clip_rejects_unknown_type():
    ok, reason = validate_clip({"type": "bumper", "start": 0, "end": 1, "label": "x"})
    assert not ok and "type" in reason


def test_validate_clip_rejects_reversed_span():
    ok, reason = validate_clip({"type": "intro", "start": 5, "end": 2, "label": "x"})
    assert not ok and "start" in reason


def test_validate_clip_rejects_non_integer_indices():
    ok, _ = validate_clip({"type": "intro", "start": "0", "end": 2, "label": "x"})
    assert not ok


# --- span -> word-id mapping + duration from samples -----------------------
def test_build_candidate_maps_span_to_words_and_samples():
    sents = _sents(["one", "two", "three"], sec_per=2.0)
    c = build_candidate(
        sents, {"type": "spotlight", "start": 0, "end": 1, "label": "Two things"}, DEFAULT_SPECS, SR
    )
    assert c.word_ids == [1, 2, 3, 4]  # sentences 0 and 1
    assert c.start_sample == 0
    assert c.end_sample == 4000  # end of sentence 1 = 4.0s * 1000
    assert c.duration_sec == 4.0  # from samples, not from any LLM estimate


def test_build_candidate_ignores_llm_duration_estimate():
    sents = _sents(["a", "b"], sec_per=3.0)
    raw = {"type": "spotlight", "start": 0, "end": 1, "label": "x", "duration": 999}
    c = build_candidate(sents, raw, DEFAULT_SPECS, SR)
    assert c.duration_sec == 6.0  # samples win over the bogus 999


def test_build_candidate_clamps_out_of_range_indices():
    sents = _sents(["a", "b", "c"])
    c = build_candidate(
        sents, {"type": "spotlight", "start": -2, "end": 99, "label": "x"}, DEFAULT_SPECS, SR
    )
    assert c.start_index == 0 and c.end_index == 2


# --- duration-window enforcement -------------------------------------------
def test_enforce_drops_fragments_and_over_merges_keeps_valid():
    sents = _sents(["s"] * 400, sec_per=1.0)
    frag = build_candidate(sents, _clip(0, 9), DEFAULT_SPECS, SR)  # 10s -> fragment
    good = build_candidate(sents, _clip(0, 59), DEFAULT_SPECS, SR)  # 60s -> keep
    huge = build_candidate(sents, _clip(0, 299), DEFAULT_SPECS, SR)  # 300s -> over hard_max
    kept, dropped = enforce_duration_window([frag, good, huge], DEFAULT_SPECS)
    assert [c.duration_sec for c in kept] == [60.0]
    assert len(dropped) == 2


# --- dedupe / merge across window seams ------------------------------------
def test_dedupe_keeps_the_longer_of_two_overlapping_candidates():
    sents = _sents(["s"] * 100)
    short = build_candidate(sents, _clip(0, 40), DEFAULT_SPECS, SR)
    longer = build_candidate(sents, _clip(0, 60), DEFAULT_SPECS, SR)
    kept = dedupe_overlapping([short, longer])
    assert len(kept) == 1
    assert kept[0].end_index == 60


def test_dedupe_keeps_overlapping_candidates_of_different_types():
    # An intro may legitimately live inside a broader spotlight — not a dup.
    sents = _sents(["s"] * 100)
    spot = build_candidate(sents, _clip(0, 60, "spotlight"), DEFAULT_SPECS, SR)
    intro = build_candidate(sents, _clip(10, 20, "intro"), DEFAULT_SPECS, SR)
    kept = dedupe_overlapping([spot, intro])
    assert len(kept) == 2


def test_dedupe_keeps_distinct_same_type_stories_sharing_a_few_sentences():
    # 3 shared transition sentences out of ~50 must not collapse two stories.
    sents = _sents(["s"] * 100)
    a = build_candidate(sents, _clip(0, 50), DEFAULT_SPECS, SR)
    b = build_candidate(sents, _clip(48, 98), DEFAULT_SPECS, SR)  # overlap = 3
    kept = dedupe_overlapping([a, b])
    assert len(kept) == 2


def test_dedupe_keeps_disjoint_candidates():
    sents = _sents(["s"] * 100)
    a = build_candidate(sents, _clip(0, 40), DEFAULT_SPECS, SR)
    b = build_candidate(sents, _clip(50, 90), DEFAULT_SPECS, SR)
    kept = dedupe_overlapping([a, b])
    assert len(kept) == 2


# --- ranking ---------------------------------------------------------------
def test_rank_prefers_target_window_and_assigns_1_based_rank():
    sents = _sents(["s"] * 400)
    off = build_candidate(sents, _clip(0, 199), DEFAULT_SPECS, SR)  # 200s, outside target
    on = build_candidate(sents, _clip(0, 79), DEFAULT_SPECS, SR)  # 80s, inside target
    ranked = rank_candidates([off, on], DEFAULT_SPECS)
    top = min(ranked, key=lambda c: c.rank)
    assert top.duration_sec == 80.0
    assert sorted(c.rank for c in ranked) == [1, 2]


# --- song-label validation -------------------------------------------------
def test_verify_song_true_when_title_present_in_transcript():
    assert verify_song("No Depression", "we all read No Depression magazine back then")


def test_verify_song_false_when_title_absent():
    assert not verify_song("Purple Rain", "we all read No Depression magazine back then")


def _clip(start, end, ptype="spotlight"):
    return {"type": ptype, "start": start, "end": end, "label": "x"}
