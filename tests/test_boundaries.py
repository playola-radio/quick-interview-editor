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
    assert b.start_sample == 2000 - 100  # cs - pad(100ms)
    assert b.end_sample == 2100 + 100
    # still never clips
    assert b.start_sample <= 2000 and b.end_sample >= 2100


def test_boundaries_clamp_to_signal_bounds():
    silences = []
    b = snap_boundaries(0.010, 4.995, silences, SR, total_samples=5000)
    assert b.start_sample >= 0
    assert b.end_sample <= 5000


def test_no_silence_at_all_pads_both_sides():
    b = snap_boundaries(1.000, 1.200, [], SR, total_samples=5000)
    assert isinstance(b, Boundaries)
    assert b.start_sample == 900 and b.end_sample == 1300


def test_neighbor_limits_stop_adjacent_chunks_stealing_words():
    # chunk A ends at 1.13s, chunk B starts at 1.17s, silence only far away (2.0s)
    silences = [Silence(2000, 2300)]
    # file A: its end must not reach past B's content start (1170)
    a = snap_boundaries(0.500, 1.130, silences, SR, 5000, limit_end_sample=1170)
    assert a.end_sample <= 1170
    # file B: its start must not reach before A's content end (1130)
    b = snap_boundaries(1.170, 1.500, silences, SR, 5000, limit_start_sample=1130)
    assert b.start_sample >= 1130
    # overlap is at most the tiny inter-chunk gap, not whole words
    assert a.end_sample - b.start_sample <= 40
