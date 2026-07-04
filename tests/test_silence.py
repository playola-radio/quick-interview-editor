import numpy as np

from logic_markers.silence import Silence, adaptive_threshold_db, detect_silences

SR = 16000


def _tone(seconds: float, amp: float, freq: float = 200.0) -> np.ndarray:
    t = np.arange(int(seconds * SR)) / SR
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def test_detects_a_single_gap_between_two_tones():
    sig = np.concatenate([_tone(0.2, 0.3), np.zeros(int(0.3 * SR), np.float32), _tone(0.2, 0.3)])
    regions = detect_silences(sig, SR)
    assert len(regions) == 1
    r = regions[0]
    # gap is roughly 0.2s .. 0.5s
    assert 0.17 * SR <= r.start <= 0.25 * SR
    assert 0.45 * SR <= r.end <= 0.53 * SR


def test_adaptive_threshold_sits_above_noise_floor_and_within_clamp():
    # quiet background ~ -49 dBFS, loud ~ -9 dBFS
    sig = np.concatenate([_tone(0.3, 0.5), _tone(0.3, 0.005), _tone(0.3, 0.5)])
    thr = adaptive_threshold_db(sig, SR)
    assert -60.0 <= thr <= -30.0
    # should separate the quiet section from the loud one
    assert -55.0 <= thr <= -35.0


def test_quiet_section_detected_against_a_real_noise_floor():
    sig = np.concatenate([_tone(0.3, 0.5), _tone(0.3, 0.005), _tone(0.3, 0.5)])
    regions = detect_silences(sig, SR)
    assert any(0.3 * SR <= r.start and r.end <= 0.65 * SR for r in regions)


def test_short_gap_below_min_duration_is_ignored():
    sig = np.concatenate([_tone(0.2, 0.3), np.zeros(int(0.05 * SR), np.float32), _tone(0.2, 0.3)])
    regions = detect_silences(sig, SR, min_silence_ms=120)
    assert regions == []


def test_no_silence_in_continuous_tone():
    assert detect_silences(_tone(0.6, 0.4), SR) == []


def test_regions_are_within_signal_bounds():
    sig = np.concatenate([_tone(0.2, 0.3), np.zeros(int(0.3 * SR), np.float32), _tone(0.2, 0.3)])
    for r in detect_silences(sig, SR):
        assert isinstance(r, Silence)
        assert 0 <= r.start < r.end <= len(sig)
