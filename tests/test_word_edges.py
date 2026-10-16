import numpy as np
import pytest

from logic_markers.editplan import _sample
from logic_markers.word_edges import HOP_MS, PAD_MS, refine_word_edges
from logic_markers.words import Word

SR = 16000
TOL = (PAD_MS + HOP_MS) / 1000 + 1 / SR


def _tone(seconds, amp=0.4):
    t = np.arange(round(seconds * SR)) / SR
    return (amp * np.sin(2 * np.pi * 200.0 * t)).astype(np.float32)


def _silence(seconds):
    return np.zeros(round(seconds * SR), np.float32)


def _sig(*parts):
    return np.concatenate(parts)


def _w(i, start, end):
    return Word(id=i, text=f"w{i}", start=start, end=end, confidence=0.5)


def test_pause_edges_move_to_true_tone_edges():
    # tone a 0.3-0.7, silence 0.7-1.0, tone b 1.0-1.4
    sig = _sig(_silence(0.3), _tone(0.4), _silence(0.3), _tone(0.4), _silence(0.3))
    a, b = refine_word_edges((_w(1, 0.3, 0.62), _w(2, 1.06, 1.4)), sig, SR)
    assert a.end == pytest.approx(0.7, abs=TOL)
    assert b.start == pytest.approx(1.0, abs=TOL)


def test_pause_edges_already_in_silence_are_never_pulled_into_the_word():
    sig = _sig(_silence(0.3), _tone(0.4), _silence(0.3), _tone(0.4), _silence(0.3))
    a, b = refine_word_edges((_w(1, 0.3, 0.8), _w(2, 0.9, 1.4)), sig, SR)
    assert (a.end, b.start) == (0.8, 0.9)


def test_quiet_consonant_under_a_raised_noise_floor_stays_in_the_word():
    noise = np.random.default_rng(0).uniform(-0.02, 0.02, round(1.6 * SR)).astype(np.float32)
    sig = _sig(_silence(0.2), _tone(0.4), _tone(0.1, amp=0.02), _silence(0.2),
               _tone(0.4), _silence(0.3)) + noise
    a, _ = refine_word_edges((_w(1, 0.2, 0.7), _w(2, 0.9, 1.3)), sig, SR)
    assert a.end == 0.7


def test_stop_closure_inside_a_word_is_not_taken_for_the_pause():
    # word a 0.2-0.7 has a silent closure 0.59-0.68 before its release; b follows at once
    sig = _sig(_silence(0.2), _tone(0.39), _silence(0.09), _tone(0.02), _tone(0.4),
               _silence(0.3))
    a, b = refine_word_edges((_w(1, 0.2, 0.7), _w(2, 0.7, 1.1)), sig, SR)
    assert a.end >= 0.69
    assert a.end == b.start


def test_end_never_jumps_over_the_next_words_onset_to_a_later_closure():
    # a 0.2-0.6, 40 ms pause, b's onset 0.64-0.75, closure inside b 0.75-0.85, b resumes;
    # b is reported very late, so the closure sits inside the raw gap
    sig = _sig(_silence(0.2), _tone(0.4), _silence(0.04), _tone(0.11), _silence(0.1),
               _tone(0.35), _silence(0.3))
    a, _ = refine_word_edges((_w(1, 0.2, 0.58), _w(2, 0.9, 1.2)), sig, SR)
    assert 0.6 <= a.end <= 0.64


def test_end_stops_at_an_unquiet_short_pause_before_the_next_words_onset():
    # the 15 ms pause between a and b's onset never registers as quiet under the noise floor
    noise = np.random.default_rng(0).uniform(-0.001, 0.001, round(1.475 * SR)).astype(np.float32)
    sig = _sig(_silence(0.2), _tone(0.4), _silence(0.015), _tone(0.11), _silence(0.1),
               _tone(0.35), _silence(0.3)) + noise
    a, _ = refine_word_edges((_w(1, 0.2, 0.58), _w(2, 0.78, 1.175)), sig, SR)
    assert 0.59 <= a.end <= 0.615


def test_start_stops_at_a_dip_before_an_untranscribed_sound():
    # an untranscribed sound 0.8-1.0 runs into word b (1.02-1.3) through a dip, not silence
    sig = _sig(_silence(0.3), _tone(0.4), _silence(0.1), _tone(0.2), _tone(0.02, amp=0.08),
               _tone(0.28), _silence(0.3))
    _, b = refine_word_edges((_w(1, 0.3, 0.7), _w(2, 1.05, 1.3)), sig, SR)
    assert 1.0 <= b.start <= 1.05


def test_speech_entirely_below_the_quiet_threshold_keeps_its_span():
    sig = _sig(_silence(0.2), _tone(0.4, amp=0.0005), _silence(0.2),
               _tone(0.4, amp=0.0005), _silence(0.3))
    a, b = refine_word_edges((_w(1, 0.2, 0.6), _w(2, 0.8, 1.2)), sig, SR)
    assert a.start <= 0.2 and a.end >= 0.6
    assert b.start <= 0.8 and b.end >= 1.2


def test_connected_boundary_lands_in_dip_and_is_shared():
    # tone 0.3-0.7, 40 ms dip 0.7-0.74, tone 0.74-1.14
    sig = _sig(_silence(0.3), _tone(0.4), _tone(0.04, amp=0.1), _tone(0.4), _silence(0.3))
    a, b = refine_word_edges((_w(1, 0.3, 0.75), _w(2, 0.75, 1.14)), sig, SR)
    # raw midpoint is 0.75; the dip is centred on 0.72
    assert a.end == b.start
    assert a.end == pytest.approx(0.72, abs=0.015)


def test_connected_boundary_prefers_nearby_clear_dip_over_deeper_neighbour_dip():
    # True boundary at 0.7 has a shallow dip; a deeper dip at 0.76 is inside b.
    sig = _sig(_silence(0.3), _tone(0.39), _tone(0.02, amp=0.16),
               _tone(0.04), _tone(0.02, amp=0.04), _tone(0.37), _silence(0.3))
    a, b = refine_word_edges((_w(1, 0.3, 0.7), _w(2, 0.7, 1.14)), sig, SR)
    assert a.end == b.start
    assert a.end == pytest.approx(0.7, abs=HOP_MS / 1000)


def test_connected_flat_energy_keeps_raw_gap_midpoint():
    sig = _sig(_silence(0.3), _tone(1.0), _silence(0.3))
    a, b = refine_word_edges((_w(1, 0.3, 0.78), _w(2, 0.82, 1.3)), sig, SR)
    assert a.end == b.start
    assert a.end == pytest.approx(0.8, abs=1 / SR)


def test_breath_in_a_pause_is_owned_by_neither_word():
    # a 0.3-0.7, silence, breath 0.85-0.91, silence, b 1.1-1.5
    sig = _sig(
        _silence(0.3), _tone(0.4), _silence(0.15), _tone(0.06, amp=0.1),
        _silence(0.19), _tone(0.4), _silence(0.3),
    )
    a, b = refine_word_edges((_w(1, 0.3, 0.66), _w(2, 1.14, 1.5)), sig, SR)
    assert a.end == pytest.approx(0.7, abs=TOL)
    assert b.start == pytest.approx(1.1, abs=TOL)


def test_boundary_never_crosses_the_neighbouring_midpoints():
    # silence sits entirely beyond word b's midpoint
    sig = _sig(_tone(0.5), _tone(0.5), _tone(0.5), _silence(0.5), _tone(0.3))
    a_raw, b_raw = _w(1, 0.0, 0.5), _w(2, 0.6, 0.9)
    a, b = refine_word_edges((a_raw, b_raw), sig, SR)
    m_a = (round(a_raw.start * SR) + round(a_raw.end * SR)) // 2
    m_b = (round(b_raw.start * SR) + round(b_raw.end * SR)) // 2
    assert m_a < round(a.end * SR) <= round(b.start * SR) <= m_b


def test_first_and_last_edges_refine_outward_to_silence():
    sig = _sig(_silence(0.3), _tone(0.4), _silence(0.3))
    (w,) = refine_word_edges((_w(1, 0.34, 0.66),), sig, SR)
    assert w.start == pytest.approx(0.3, abs=TOL)
    assert w.end == pytest.approx(0.7, abs=TOL)


def test_first_and_last_edges_stay_raw_without_nearby_silence():
    sig = _tone(1.0)
    raw = _w(1, 0.2, 0.8)
    (w,) = refine_word_edges((raw,), sig, SR)
    assert (w.start, w.end) == (raw.start, raw.end)


def test_unrefinable_words_are_unchanged_and_break_the_chain():
    sig = _sig(_silence(0.3), _tone(0.4), _silence(0.3), _tone(0.4), _silence(0.3),
               _tone(0.4), _silence(0.3))
    missing_end = Word(id=2, text="w2", start=1.06, end=None)
    zero_span = Word(id=2, text="w2", start=1.06, end=1.06)
    for middle in (missing_end, zero_span):
        a, mid, c = refine_word_edges(
            (_w(1, 0.3, 0.62), middle, _w(3, 1.9, 2.3)), sig, SR
        )
        assert mid == middle
        assert a.end == 0.62
        assert c.start == 1.9


def test_empty_inputs_are_returned_unchanged():
    assert refine_word_edges((), _tone(0.5), SR) == ()
    words = (_w(1, 0.1, 0.2),)
    assert refine_word_edges(words, np.zeros(0, np.float32), SR) == words


@pytest.mark.parametrize("seed", range(8))
def test_output_invariants_hold_for_garbage_alignments(seed):
    rng = np.random.default_rng(seed)
    parts = []
    for _ in range(14):
        if rng.random() < 0.45:
            parts.append(_silence(rng.uniform(0.02, 0.4)))
        else:
            parts.append(_tone(rng.uniform(0.05, 0.4), amp=rng.uniform(0.05, 0.5)))
    sig = _sig(*parts)
    total = len(sig) / SR

    count = 12
    centers = np.sort(rng.uniform(0.0, total, count))
    words = []
    for i, c in enumerate(centers):
        half = rng.uniform(0.01, 0.4)
        start = max(0.0, c - half)
        end = min(total, c + half)
        words.append(Word(id=i, text=f"w{i}", start=start, end=end, confidence=0.1 * i))
    words = tuple(w for w in words if round(w.end * SR) > round(w.start * SR))
    mids = [(round(w.start * SR) + round(w.end * SR)) // 2 for w in words]
    words = tuple(w for w, m, prev in zip(words, mids, [-1] + mids) if m > prev)

    refined = refine_word_edges(words, sig, SR)

    assert [(w.id, w.text, w.confidence) for w in refined] == [
        (w.id, w.text, w.confidence) for w in words
    ]
    spans = []
    for w in refined:
        s, e = round(w.start * SR), round(w.end * SR)
        assert _sample(s / SR, SR) == s
        assert _sample(e / SR, SR) == e
        assert 0 <= s < e <= len(sig)
        spans.append((s, e))
    for (_, e), (s, _) in zip(spans, spans[1:]):
        assert e <= s
    for raw, (s, e) in zip(words, spans):
        m = (round(raw.start * SR) + round(raw.end * SR)) // 2
        assert s <= m < e
