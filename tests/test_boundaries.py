from logic_markers.boundaries import Boundaries, snap_boundaries
from logic_markers.silence import Silence

SR = 1000  # 1 sample per ms keeps the arithmetic obvious


def test_snaps_outward_to_the_edge_of_nearby_silences():
    silences = [Silence(0, 100), Silence(300, 400)]
    b = snap_boundaries(0.120, 0.280, silences, SR, total_samples=1000)
    assert b.start_status == "snapped" and b.end_status == "snapped"
    # start lands near the END of the leading silence (not its midpoint), before the word
    assert 80 <= b.start_sample <= 100 and b.start_sample < 120
    # end lands near the START of the trailing silence, after the word
    assert 300 <= b.end_sample <= 320 and b.end_sample > 280


def test_never_clips_the_word_even_when_snapping():
    silences = [Silence(0, 100), Silence(300, 400)]
    b = snap_boundaries(0.120, 0.280, silences, SR, total_samples=1000)
    assert b.start_sample <= 120  # <= first-word start
    assert b.end_sample >= 280    # >= last-word end


def test_falls_back_to_padding_when_no_silence_is_near():
    silences = [Silence(0, 100)]  # far from the word at 2.0s..2.1s
    b = snap_boundaries(2.000, 2.100, silences, SR, total_samples=5000)
    assert b.start_status == "padded" and b.end_status == "padded"
    assert b.start_sample == 2000 - 100   # cs - pad(100ms)
    assert b.end_sample == 2100 + 250     # ce + fade tail(250ms)
    # still never clips
    assert b.start_sample <= 2000 and b.end_sample >= 2100


def test_padded_end_gets_a_fade_tail_past_the_soft_neighbor_limit():
    # no silence, next kept chunk is close; the tail may bleed into it for a fade
    b = snap_boundaries(1.000, 1.200, [], SR, 5000, limit_end_sample=1210)
    assert b.end_status == "padded"
    assert b.end_sample == 1200 + 250  # bleeds past the soft limit 1210


def test_fade_tail_never_crosses_deleted_audio():
    # next word is deleted -> hard limit clamps the tail short of it
    b = snap_boundaries(1.000, 1.200, [], SR, 5000, hard_end_sample=1260)
    assert b.end_sample == 1260  # clamped to the deleted-audio boundary, not 1450


def test_boundaries_clamp_to_signal_bounds():
    silences = []
    b = snap_boundaries(0.010, 4.995, silences, SR, total_samples=5000)
    assert b.start_sample >= 0
    assert b.end_sample <= 5000


def test_no_silence_at_all_pads_both_sides():
    b = snap_boundaries(1.000, 1.200, [], SR, total_samples=5000)
    assert isinstance(b, Boundaries)
    assert b.start_sample == 900 and b.end_sample == 1200 + 250  # pad in, fade tail out


def test_overlapping_neighbor_timestamp_never_clips_the_kept_word():
    # prev word 0.90-1.10 overlaps kept word 1.00-1.20; limit must not clip it
    b = snap_boundaries(1.000, 1.200, [], SR, 5000, limit_start_sample=1100)
    assert b.start_sample <= 1000  # not pushed to 1100 (inside the word)
    b2 = snap_boundaries(1.000, 1.200, [], SR, 5000, limit_end_sample=1100)
    assert b2.end_sample >= 1200


def test_end_does_not_snap_to_a_far_silence_and_swallow_next_chunk():
    # chunk A ends at 1.13s; the only silence (2.0s) is beyond the search radius
    silences = [Silence(2000, 2300)]
    a = snap_boundaries(0.500, 1.130, silences, SR, 5000, limit_end_sample=1170)
    assert a.end_status == "padded"           # did NOT snap to the far silence
    assert a.end_sample < 2000                # so it can't swallow the next chunk
    assert a.end_sample == 1130 + 250         # only the intentional fade tail bleeds in
    # file B's start still can't reach back before A's content end
    b = snap_boundaries(1.170, 1.500, silences, SR, 5000, limit_start_sample=1130)
    assert b.start_sample >= 1130
