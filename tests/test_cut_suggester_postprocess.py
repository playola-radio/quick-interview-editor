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
    merge_adjacent_same_label,
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


def test_dedupe_collapses_transitive_overlap_chain_to_longest():
    # A~B and B~C each overlap >=50%, and the longest span (c) duplicates both.
    # A replacement must be re-checked against ALL retained clips: the old early
    # `break` could leave a residual duplicate. The cluster collapses to the
    # single longest span with no residual overlaps.
    sents = _sents(["s"] * 120)
    a = build_candidate(sents, _clip(0, 60), DEFAULT_SPECS, SR)   # span 61
    b = build_candidate(sents, _clip(30, 90), DEFAULT_SPECS, SR)  # span 61, dupes a
    c = build_candidate(sents, _clip(0, 98), DEFAULT_SPECS, SR)   # span 99, dupes a and b
    kept = dedupe_overlapping([a, b, c])
    assert len(kept) == 1
    assert (kept[0].start_index, kept[0].end_index) == (0, 98)  # the longest survives


def test_dedupe_leaves_no_residual_overlap_when_longest_replaces_two():
    # Three same-start-cluster candidates: the longest must absorb both others so
    # no two retained same-type candidates overlap >=50%.
    sents = _sents(["s"] * 120)
    cands = [
        build_candidate(sents, _clip(0, 40), DEFAULT_SPECS, SR),   # span 41
        build_candidate(sents, _clip(0, 100), DEFAULT_SPECS, SR),  # span 101 (longest)
        build_candidate(sents, _clip(20, 70), DEFAULT_SPECS, SR),  # span 51
    ]
    kept = dedupe_overlapping(cands)
    for i in range(len(kept)):
        for j in range(i + 1, len(kept)):
            lo = max(kept[i].start_index, kept[j].start_index)
            hi = min(kept[i].end_index, kept[j].end_index)
            overlap = max(0, hi - lo + 1)
            shorter = min(
                kept[i].end_index - kept[i].start_index + 1,
                kept[j].end_index - kept[j].start_index + 1,
            )
            assert overlap / shorter < 0.5  # no residual duplicate pair
    assert (kept[0].start_index, kept[0].end_index) == (0, 100)


def test_dedupe_keeps_disjoint_candidates():
    sents = _sents(["s"] * 100)
    a = build_candidate(sents, _clip(0, 40), DEFAULT_SPECS, SR)
    b = build_candidate(sents, _clip(50, 90), DEFAULT_SPECS, SR)
    kept = dedupe_overlapping([a, b])
    assert len(kept) == 2


# --- minimal merge of over-split same-label fragments ----------------------
def test_merge_adjacent_same_label_fragments_into_one_clip():
    sents = _sents(["s"] * 20, sec_per=10.0)
    c1 = build_candidate(sents, _labelled(0, 2, "Radney Foster"), DEFAULT_SPECS, SR)
    c2 = build_candidate(sents, _labelled(3, 5, "radney  foster"), DEFAULT_SPECS, SR)  # same normalized
    c3 = build_candidate(sents, _labelled(6, 8, "Radney Foster"), DEFAULT_SPECS, SR)
    other = build_candidate(sents, _labelled(10, 13, "Different Story"), DEFAULT_SPECS, SR)
    merged = merge_adjacent_same_label([c1, c2, c3, other], sents, DEFAULT_SPECS, SR)
    assert len(merged) == 2
    combined = next(m for m in merged if m.label == "Radney Foster")
    assert (combined.start_index, combined.end_index) == (0, 8)
    assert combined.word_ids == list(c1.word_ids) + list(c2.word_ids) + list(c3.word_ids)
    assert any("merged" in w for w in combined.warnings)


def test_merge_leaves_different_types_labels_and_distant_fragments_alone():
    sents = _sents(["s"] * 30, sec_per=10.0)
    a = build_candidate(sents, _labelled(0, 2, "X", "spotlight"), DEFAULT_SPECS, SR)
    b = build_candidate(sents, _labelled(3, 5, "X", "intro"), DEFAULT_SPECS, SR)  # different type
    c = build_candidate(sents, _labelled(20, 22, "X", "spotlight"), DEFAULT_SPECS, SR)  # too far
    out = merge_adjacent_same_label([a, b, c], sents, DEFAULT_SPECS, SR)
    assert len(out) == 3


def test_merge_stops_at_interleaved_other_type():
    # spotlight, intro, spotlight in adjacent order: the intro breaks the run so
    # the two spotlight fragments stay separate (no cross-type grouping).
    sents = _sents(["s"] * 20, sec_per=10.0)
    a = build_candidate(sents, _labelled(0, 2, "X", "spotlight"), DEFAULT_SPECS, SR)
    b = build_candidate(sents, _labelled(3, 5, "X", "intro"), DEFAULT_SPECS, SR)
    c = build_candidate(sents, _labelled(6, 8, "X", "spotlight"), DEFAULT_SPECS, SR)
    out = merge_adjacent_same_label([a, b, c], sents, DEFAULT_SPECS, SR)
    assert len(out) == 3


def test_merge_keeps_fragments_when_merged_span_exceeds_hard_max():
    # Two same-label spotlight fragments that are each individually acceptable but
    # whose merge exceeds hard_max (240s) must stay separate, so enforcement can
    # keep the valid pieces instead of dropping the whole over-long merge.
    sents = _sents(["s"] * 60, sec_per=10.0)
    a = build_candidate(sents, _labelled(0, 11, "Long Story"), DEFAULT_SPECS, SR)  # 120s
    b = build_candidate(sents, _labelled(12, 25, "Long Story"), DEFAULT_SPECS, SR)  # 140s -> merged 260s
    out = merge_adjacent_same_label([a, b], sents, DEFAULT_SPECS, SR)
    assert len(out) == 2  # not merged; both survive enforcement (<= hard_max)
    assert not any("merged" in w for c in out for w in c.warnings)


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


def _labelled(start, end, label, ptype="spotlight"):
    return {"type": ptype, "start": start, "end": end, "label": label}
