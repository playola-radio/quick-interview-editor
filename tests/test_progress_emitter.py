import math

from logic_markers.cli import _PhaseEmitter, _StageRouter


def _collect():
    events = []
    return events, (lambda e: events.append(e))


def test_first_callback_always_emits_with_phase_metadata():
    events, emit = _collect()
    em = _PhaseEmitter(1, 3, "transcribing", "Transcribing", "Transcribing audio…", emit=emit)
    em(0.037)  # starts above zero; must still emit a first event
    assert len(events) == 1
    e = events[0]
    assert e["type"] == "progress"
    assert e["phase"] == "transcribing"
    assert e["phase_index"] == 1
    assert e["phase_count"] == 3
    assert e["label"] == "Transcribing"
    assert e["fraction"] == 0.037


def test_throttles_within_same_whole_percent():
    events, emit = _collect()
    em = _PhaseEmitter(2, 3, "aligning", "Aligning words", "Aligning words…", emit=emit)
    em(0.101)
    em(0.104)  # same whole percent -> no new event
    em(0.11)   # new whole percent -> emits
    assert [e["fraction"] for e in events] == [0.101, 0.11]


def test_monotonic_within_phase_drops_backward_fractions():
    events, emit = _collect()
    em = _PhaseEmitter(1, 3, "transcribing", "Transcribing", "…", emit=emit)
    em(0.50)
    em(0.30)  # lower than the last emitted percent -> dropped (no backward jump)
    em(0.51)  # forward again -> emits
    assert [e["fraction"] for e in events] == [0.50, 0.51]


def test_clamps_and_drops_nan_inf():
    events, emit = _collect()
    em = _PhaseEmitter(1, 3, "transcribing", "Transcribing", "…", emit=emit)
    em(-0.05)         # clamp -> 0.0
    em(1.5)            # clamp -> 1.0 (whole percent 100)
    em(float("nan"))  # dropped
    em(math.inf)       # dropped
    assert [e["fraction"] for e in events] == [0.0, 1.0]


def test_finish_emits_final_one_for_its_phase_when_not_already_full():
    events, emit = _collect()
    em = _PhaseEmitter(1, 3, "transcribing", "Transcribing", "…", emit=emit)
    em(0.80)
    em.finish()
    assert events[-1]["fraction"] == 1.0
    assert events[-1]["phase_index"] == 1  # finish carries the phase's own metadata


def test_finish_is_noop_when_phase_never_emitted():
    # A skipped phase (e.g. cached transcript => no align) must never fabricate 100%.
    events, emit = _collect()
    em = _PhaseEmitter(2, 3, "aligning", "Aligning words", "…", emit=emit)
    em.finish()
    assert events == []


def test_finish_is_noop_when_already_full():
    events, emit = _collect()
    em = _PhaseEmitter(1, 3, "transcribing", "Transcribing", "…", emit=emit)
    em(1.0)      # already full
    em.finish()  # no duplicate
    assert [e["fraction"] for e in events] == [1.0]


def test_stage_router_maps_stages_and_caps_transcribe_before_align():
    events, emit = _collect()
    transcribe = _PhaseEmitter(1, 3, "transcribing", "Transcribing", "T…", emit=emit)
    align = _PhaseEmitter(2, 3, "aligning", "Aligning words", "A…", emit=emit)
    router = _StageRouter(transcribe, align)

    router("transcribe", 0.5)  # phase 1 progress
    router("align", 0.5)       # first align: cap phase 1 at 100%, then phase 2 progress
    router.finish()            # cap phase 2 at 100% (phase 1 already full -> no-op)

    assert [(e["phase_index"], e["fraction"]) for e in events] == [
        (1, 0.5), (1, 1.0), (2, 0.5), (2, 1.0),
    ]


def test_stage_router_finish_skips_phases_that_never_emitted():
    # Cached-transcript path: neither stage ran. finish() must emit nothing.
    events, emit = _collect()
    transcribe = _PhaseEmitter(1, 3, "transcribing", "Transcribing", "T…", emit=emit)
    align = _PhaseEmitter(2, 3, "aligning", "Aligning words", "A…", emit=emit)
    router = _StageRouter(transcribe, align)
    router.finish()
    assert events == []
