import math

from logic_markers.cli import _ProgressEmitter


def _collect():
    events = []
    return events, (lambda e: events.append(e))


def test_first_callback_always_emits():
    events, emit = _collect()
    em = _ProgressEmitter(emit=emit)
    em(3.7)  # starts above zero; must still emit a first event
    assert len(events) == 1
    assert events[0]["type"] == "progress"
    assert events[0]["phase"] == "transcribing"
    assert events[0]["fraction"] == 0.037


def test_throttles_within_same_whole_percent():
    events, emit = _collect()
    em = _ProgressEmitter(emit=emit)
    em(10.1)
    em(10.4)  # same whole percent -> no new event
    em(11.0)  # new whole percent -> emits
    assert [e["fraction"] for e in events] == [0.101, 0.11]


def test_clamps_and_drops_nan_inf():
    events, emit = _collect()
    em = _ProgressEmitter(emit=emit)
    em(-5)          # clamp -> 0.0
    em(150)         # clamp -> 1.0 (whole percent 100)
    em(float("nan"))  # dropped
    em(math.inf)      # dropped
    assert [e["fraction"] for e in events] == [0.0, 1.0]


def test_label_switches_at_half():
    events, emit = _collect()
    em = _ProgressEmitter(emit=emit)
    em(40)
    em(60)
    assert events[0]["message"] == "Transcribing audio…"
    assert events[1]["message"] == "Aligning words…"


def test_finish_emits_final_one_when_not_already_full():
    events, emit = _collect()
    em = _ProgressEmitter(emit=emit)
    em(80)
    em.finish()
    assert events[-1]["fraction"] == 1.0


def test_finish_is_noop_when_never_called_or_already_full():
    events, emit = _collect()
    em = _ProgressEmitter(emit=emit)
    em.finish()  # never fired -> nothing (avoids a spurious 100% on cache hits)
    em(100)      # already full
    em.finish()  # no duplicate
    assert [e["fraction"] for e in events] == [1.0]
