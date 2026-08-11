# WhisperX Transcription Progress Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the meaningless indeterminate spinner in the "Transcribing with WhisperX" state with a real, subprocess-driven progress bar plus an upfront note and a live "About X min remaining" estimate.

**Architecture:** WhisperX 3.8.6's `transcribe()`/`align()` `progress_callback` (with `combined_progress=True`) feeds a Python emitter that writes throttled `QIE_EVENT {…,"fraction":0..1}` lines on stderr. The existing `LiveEngine` stderr reader decodes the new `fraction` into `EngineProgress`; `SongTabModel` derives a determinate progress value + ETA from it; `SongTabView` swaps to `ProgressView(value:)`. The bar represents the transcription phase only — it fills 0→100 during transcribe+align, then goes indeterminate for the fast tail phases (convert/silence/plan).

**Tech Stack:** Python 3.12 (pytest), whisperx 3.8.6; Swift/SwiftUI, swift-dependencies (`Clock`), Swift Testing + swift-custom-dump.

## Global Constraints

- `whisperx==3.8.6` is already pinned in `requirements.txt` — no version change needed. The 0–50 (transcribe) / 50–100 (align) split of `combined_progress` is WhisperX-internal; correctness must not depend on the exact 50 boundary (it drives only the cosmetic label swap).
- Point-Free skills are mandatory before Swift code: `pfw-observable-models`, `pfw-dependencies`, `pfw-testing`, `pfw-custom-dump`, `pfw-modern-swiftui`. Value assertions use `expectNoDifference`, never raw `#expect(a == b)`.
- Zero logic in the view: every label and the determinate/indeterminate choice is a model computed property.
- No `Task.sleep` in tests; use `TestClock`.
- Python engine tests: `python3 -m pytest -q`. Swift build/test per the repo's XcodeGen setup.
- Implementation order is Python-first (Tasks 1–3) so the emitted `QIE_EVENT` contract is proven before any Swift work.

---

### Task 1: Python — `_ProgressEmitter` (clamp / throttle / label / endpoints)

A small, whisperx-free class that turns WhisperX's 0–100 float callbacks into throttled, validated `QIE_EVENT` progress lines. Unit-tested in isolation.

**Files:**
- Modify: `logic_markers/cli.py` (add `import math` near the top imports; add the class after `_progress`, ~line 45)
- Test: `tests/test_progress_emitter.py` (create)

**Interfaces:**
- Consumes: the module-level `_emit_event(event: dict) -> None` (injectable for tests).
- Produces: `class _ProgressEmitter` with `__init__(self, emit=_emit_event)`, `__call__(self, percent: float) -> None` (the whisperx callback), and `finish(self) -> None`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_progress_emitter.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_progress_emitter.py -q`
Expected: FAIL with `ImportError: cannot import name '_ProgressEmitter'`.

- [ ] **Step 3: Write minimal implementation**

In `logic_markers/cli.py`, add `import math` to the stdlib imports (near `import json`), then add after `_progress` (~line 45):

```python
class _ProgressEmitter:
    """Turns WhisperX's 0-100 progress_callback into throttled QIE_EVENT lines.

    Emits the first callback unconditionally, then only when the whole-number
    percent changes, and clamps/drops junk. `finish()` guarantees a final 1.0
    (unless nothing fired, e.g. a cached transcript, or 100 already emitted).
    """

    def __init__(self, emit=_emit_event) -> None:
        self._emit = emit
        self._last_percent: int | None = None

    def __call__(self, percent: float) -> None:
        try:
            p = float(percent)
        except (TypeError, ValueError):
            return
        if not math.isfinite(p):
            return
        p = max(0.0, min(100.0, p))
        whole = int(p)
        if self._last_percent is not None and whole == self._last_percent:
            return
        self._last_percent = whole
        self._emit_fraction(p / 100.0)

    def finish(self) -> None:
        if self._last_percent is None or self._last_percent == 100:
            return
        self._last_percent = 100
        self._emit_fraction(1.0)

    def _emit_fraction(self, fraction: float) -> None:
        fraction = max(0.0, min(1.0, fraction))
        label = "Aligning words…" if fraction >= 0.5 else "Transcribing audio…"
        self._emit(
            {
                "type": "progress",
                "phase": "transcribing",
                "message": label,
                "fraction": round(fraction, 4),
            }
        )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_progress_emitter.py -q`
Expected: PASS (6 passed).

- [ ] **Step 5: Commit**

```bash
git add logic_markers/cli.py tests/test_progress_emitter.py
git commit -m "feat(engine): add _ProgressEmitter for throttled WhisperX progress events"
```

---

### Task 2: Python — thread `progress_callback` through the whisperx backend

Add an optional `progress_callback` to `transcribe_transcript` and `_aligned_segments`, forwarded to both `model.transcribe` and `whisperx.align` with `combined_progress=True`. Default `None` keeps every other caller unchanged.

**Files:**
- Modify: `logic_markers/whisperx_backend.py` (`_aligned_segments` ~line 51, `transcribe_transcript` ~line 89)
- Test: `tests/test_whisperx_progress_forwarding.py` (create)

**Interfaces:**
- Consumes: WhisperX's `model.transcribe(..., combined_progress=, progress_callback=)` and `whisperx.align(..., combined_progress=, progress_callback=)` (both accept these in 3.8.6).
- Produces:
  - `_aligned_segments(source, model_name, device, compute_type, *, progress_callback=None) -> list[dict]`
  - `transcribe_transcript(source, model_name="large-v2", device="cpu", compute_type="int8", *, progress_callback=None) -> Transcript`

- [ ] **Step 1: Write the failing test**

Create `tests/test_whisperx_progress_forwarding.py`. It injects a fake `whisperx` module so no models/audio are needed, and asserts the callback is forwarded with `combined_progress=True` to both stages:

```python
import sys
import types

import numpy as np

import logic_markers.whisperx_backend as backend


def _install_fake_whisperx(monkeypatch, calls):
    fake = types.ModuleType("whisperx")

    class _Model:
        def transcribe(self, audio, batch_size=None, combined_progress=False,
                       progress_callback=None):
            calls.append(("transcribe", combined_progress))
            if progress_callback:
                progress_callback(25.0)
                progress_callback(50.0)
            return {"language": "en", "segments": [{"text": "hi", "start": 0.0, "end": 1.0}]}

    def load_model(arch, device, compute_type=None, local_files_only=False):
        return _Model()

    def load_align_model(language_code=None, device=None, model_dir=None,
                         model_cache_only=False):
        return object(), {}

    def align(segments, align_model, metadata, audio, device,
              return_char_alignments=False, combined_progress=False,
              progress_callback=None):
        calls.append(("align", combined_progress))
        if progress_callback:
            progress_callback(75.0)
            progress_callback(100.0)
        return {"segments": [
            {"text": "hi", "start": 0.0, "end": 1.0,
             "words": [{"word": "hi", "start": 0.0, "end": 1.0}]}
        ]}

    fake.load_model = load_model
    fake.load_align_model = load_align_model
    fake.align = align
    monkeypatch.setitem(sys.modules, "whisperx", fake)
    # _load_audio_16k_mono shells out to afconvert; stub it to a tiny array.
    monkeypatch.setattr(backend, "_load_audio_16k_mono", lambda source: np.zeros(16000, dtype=np.float32))


def test_progress_callback_forwarded_to_both_stages(monkeypatch, tmp_path):
    calls = []
    _install_fake_whisperx(monkeypatch, calls)
    received = []
    backend.transcribe_transcript(tmp_path / "x.wav", progress_callback=lambda p: received.append(p))
    assert ("transcribe", True) in calls
    assert ("align", True) in calls
    assert received == [25.0, 50.0, 75.0, 100.0]


def test_no_callback_still_works(monkeypatch, tmp_path):
    calls = []
    _install_fake_whisperx(monkeypatch, calls)
    result = backend.transcribe_transcript(tmp_path / "x.wav")  # no callback
    assert [w.text for w in result.words] == ["hi"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_whisperx_progress_forwarding.py -q`
Expected: FAIL — `transcribe_transcript()` got an unexpected keyword argument `progress_callback` (or the `combined_progress`/callback assertions fail).

- [ ] **Step 3: Write minimal implementation**

In `logic_markers/whisperx_backend.py`, change `_aligned_segments` (line 51) signature and the two whisperx calls:

```python
def _aligned_segments(
    source: Path, model_name: str, device: str, compute_type: str,
    *, progress_callback=None,
) -> list[dict]:
```

Update the transcribe call (line 71):

```python
    result = model.transcribe(
        audio, batch_size=16,
        combined_progress=True, progress_callback=progress_callback,
    )
```

Update the align call (line 82):

```python
    aligned = whisperx.align(
        result["segments"], align_model, metadata, audio, device,
        return_char_alignments=False,
        combined_progress=True, progress_callback=progress_callback,
    )
```

Change `transcribe_transcript` (line 89) signature and its `_aligned_segments` call (line 96):

```python
def transcribe_transcript(
    source: Path,
    model_name: str = "large-v2",
    device: str = "cpu",
    compute_type: str = "int8",
    *, progress_callback=None,
) -> Transcript:
    """Full transcription with per-word start/end grouped into segments."""
    segments_raw = _aligned_segments(
        source, model_name, device, compute_type, progress_callback=progress_callback
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_whisperx_progress_forwarding.py -q`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
git add logic_markers/whisperx_backend.py tests/test_whisperx_progress_forwarding.py
git commit -m "feat(engine): forward progress_callback into whisperx transcribe/align"
```

---

### Task 3: Python — wire the emitter into `run_plan` (+ real-audio verification)

Build a `_ProgressEmitter` in `run_plan`, thread it through `_load_or_transcribe_transcript_in`, reword the pre-transcribe message to "Preparing audio…", and call `finish()` after transcription completes.

**Files:**
- Modify: `logic_markers/cli.py` — `_load_or_transcribe_transcript_in` (line 61) and `run_plan` (lines 294–299)
- Test: `tests/test_run_plan_progress.py` (create)

**Interfaces:**
- Consumes: `_ProgressEmitter` (Task 1), `transcribe_transcript(..., progress_callback=)` (Task 2).
- Produces: `_load_or_transcribe_transcript_in(source, work_dir, refresh, *, on_progress=None) -> Transcript`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_run_plan_progress.py`. It stubs `transcribe_transcript` at the module path it is imported from and asserts the emitter's `on_progress` reaches it, and that a pre-transcribe "Preparing audio…" event is emitted:

```python
import json

import logic_markers.cli as cli
import logic_markers.whisperx_backend as backend
from logic_markers.words import Transcript, Word as RichWord


def test_load_or_transcribe_forwards_on_progress(monkeypatch, tmp_path, capsys):
    seen = []

    def fake_transcribe_transcript(source, progress_callback=None):
        assert progress_callback is not None
        progress_callback(25.0)
        progress_callback(75.0)
        return Transcript(words=(RichWord(id=1, text="hi", start=0.0, end=1.0),),
                          segments=())

    monkeypatch.setattr(backend, "transcribe_transcript", fake_transcribe_transcript)

    emitter = cli._ProgressEmitter()
    cli._load_or_transcribe_transcript_in(
        tmp_path / "a.wav", tmp_path, refresh=False, on_progress=emitter
    )
    lines = [l for l in capsys.readouterr().err.splitlines() if l.startswith("QIE_EVENT ")]
    fractions = [json.loads(l[len("QIE_EVENT "):]).get("fraction") for l in lines]
    assert fractions == [0.25, 0.75]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_run_plan_progress.py -q`
Expected: FAIL — `_load_or_transcribe_transcript_in()` got an unexpected keyword argument `on_progress`.

- [ ] **Step 3: Write minimal implementation**

In `logic_markers/cli.py`, update `_load_or_transcribe_transcript_in` (line 61):

```python
def _load_or_transcribe_transcript_in(
    source: Path, work_dir: Path, refresh: bool, *, on_progress=None
) -> Transcript:
    """Same as `_load_or_transcribe_transcript`, but cached in `work_dir` (never beside source)."""
    from .whisperx_backend import transcribe_transcript

    cache = work_dir / (source.name + ".transcript.json")
    if cache.exists() and not refresh:
        return Transcript.from_dict(json.loads(cache.read_text()))
    transcript = transcribe_transcript(source, progress_callback=on_progress)
    cache.write_text(json.dumps(transcript.to_dict(), indent=2))
    return transcript
```

In `run_plan` (lines 298–299), replace the single pre-transcribe event and the call:

```python
    _progress("transcribing", "Preparing audio…")
    _transcribe_progress = _ProgressEmitter()
    transcript = _load_or_transcribe_transcript_in(
        source, work_dir, refresh, on_progress=_transcribe_progress
    )
    _transcribe_progress.finish()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_run_plan_progress.py -q`
Expected: PASS (1 passed).

- [ ] **Step 5: Run the full Python suite**

Run: `python3 -m pytest -q`
Expected: PASS (all existing tests still green).

- [ ] **Step 6: Manual real-audio verification (cannot be a unit test)**

This is the only check that catches wrong kwarg placement / callback scale / timing against the real WhisperX 3.8.6 — stubs cannot. Using the project venv and any short real audio file (e.g. a 30–60s clip):

Run:
```bash
/Users/brian/playola/logic-utils/.venv/bin/python -m logic_markers.cli plan \
  <short-audio-file> --work-dir /tmp/qie-progress-check --sample-rate 44100 \
  2>&1 1>/dev/null | grep -o 'QIE_EVENT {"type": "progress"[^}]*}' | head -40
```
Expected: after one `"Preparing audio…"` line (no `fraction`), a sequence of `"transcribing"` events whose `fraction` rises through the run, label flips from `Transcribing audio…` to `Aligning words…` around 0.5, and the last transcribe `fraction` is `1.0`. Note in the PR description that this was run and what fractions appeared.

- [ ] **Step 7: Commit**

```bash
git add logic_markers/cli.py tests/test_run_plan_progress.py
git commit -m "feat(engine): emit real transcription progress fractions from run_plan"
```

---

### Task 4: Swift — `fraction` on `EngineProgress` + decode/clamp in `LiveEngine`

Add the numeric field to the model type and decode it (clamped, NaN-dropped) in the transcribe stderr reader.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Core/EngineEvent.swift:17-26`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Core/LiveEngine.swift` — `WireEvent` (line ~275) and the parse loop (lines ~210–221)
- Test: add to `QuickInterviewEditor/QuickInterviewEditor/Core/…` existing engine tests, or create `LiveEngineWireTests.swift` colocated with other Core tests (follow the repo's existing Core test location).

**Interfaces:**
- Produces: `EngineProgress` gains `var fraction: Double? = nil` (memberwise init keeps existing `EngineProgress(phase:message:)` call sites compiling). A static decode helper `LiveEngine.sanitizedFraction(_:) -> Double?` (clamp to 0...1, drop non-finite) for direct testing.

- [ ] **Step 1: Write the failing test**

Add a test (Swift Testing) for the clamp helper:

```swift
import Testing
@testable import QuickInterviewEditor

@MainActor
struct LiveEngineWireTests {
  @Test func sanitizedFractionClampsAndDropsJunk() {
    #expect(LiveEngine.sanitizedFraction(0.4) == 0.4)
    #expect(LiveEngine.sanitizedFraction(-1) == 0)
    #expect(LiveEngine.sanitizedFraction(2) == 1)
    #expect(LiveEngine.sanitizedFraction(.nan) == nil)
    #expect(LiveEngine.sanitizedFraction(.infinity) == nil)
    #expect(LiveEngine.sanitizedFraction(nil) == nil)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Build the test target. Expected: compile error — `sanitizedFraction` and `fraction` do not exist.

- [ ] **Step 3: Write minimal implementation**

In `EngineEvent.swift`, add the field to `EngineProgress`:

```swift
struct EngineProgress: Equatable, Sendable {
  enum Phase: String, Equatable, Sendable {
    case transcribing
    case converting
    case analyzingSilence = "analyzing_silence"
    case writingPlan = "writing_plan"
  }
  var phase: Phase
  var message: String
  var fraction: Double? = nil
}
```

In `LiveEngine.swift`, add `fraction` to `WireEvent`:

```swift
  private struct WireEvent: Decodable {
    var type: String
    var phase: String?
    var message: String?
    var fraction: Double?
  }
```

Add the static helper (near `WireEvent`):

```swift
  static func sanitizedFraction(_ value: Double?) -> Double? {
    guard let value, value.isFinite else { return nil }
    return min(max(value, 0), 1)
  }
```

Update the parse loop (lines ~219–221) to pass the sanitized fraction:

```swift
            continuation.yield(
              .progress(EngineProgress(
                phase: phase,
                message: wire.message ?? "",
                fraction: sanitizedFraction(wire.fraction)))
            )
```

- [ ] **Step 4: Run test to verify it passes**

Build/run the test target. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Core/EngineEvent.swift \
        QuickInterviewEditor/QuickInterviewEditor/Core/LiveEngine.swift \
        QuickInterviewEditor/QuickInterviewEditor/Core/LiveEngineWireTests.swift
git commit -m "feat(app): decode clamped transcription fraction into EngineProgress"
```

---

### Task 5: Swift — `SongTabModel` derived progress fraction + note + monotonic value

Derive a determinate progress value from `phase` (single source of truth), never moving backward, and add the upfront note. No ETA yet (Task 6).

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabTests.swift` (create if absent; follow `RecordIntroPageTests.swift` structure)

**Interfaces:**
- Consumes: `EngineProgress.fraction` (Task 4), `EngineClient.transcribe` stream.
- Produces on `SongTabModel`: `var progressFraction: Double?`, `var isProgressDeterminate: Bool`, `var determinateValue: Double`, `let progressNote: String`; private `var maxFraction: Double?` updated in `startTranscription`.

- [ ] **Step 1: Write the failing test**

Create/extend `SongTabTests.swift`:

```swift
import Dependencies
import Testing
@testable import QuickInterviewEditor

@MainActor
struct SongTabTests {

  private func stream(_ events: [EngineEvent]) -> EngineClient {
    var client = EngineClient.testValue
    client.transcribe = { _ in
      AsyncThrowingStream { continuation in
        for e in events { continuation.yield(e) }
        continuation.finish()
      }
    }
    return client
  }

  @Test func preparingPhaseIsIndeterminate() async {
    let model = withDependencies {
      $0.engine = stream([.progress(EngineProgress(phase: .transcribing, message: "Preparing audio…"))])
    } operation: { SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav")) }
    await model.startTranscription()
    #expect(model.isProgressDeterminate == false)
    expectNoDifference(model.progressFraction, nil)
  }

  @Test func transcribingFractionIsDeterminate() async {
    let model = withDependencies {
      $0.engine = stream([
        .progress(EngineProgress(phase: .transcribing, message: "Transcribing audio…", fraction: 0.25)),
      ])
    } operation: { SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav")) }
    await model.startTranscription()
    #expect(model.isProgressDeterminate == true)
    expectNoDifference(model.progressFraction, 0.25)
    expectNoDifference(model.determinateValue, 0.25)
  }

  @Test func fractionNeverMovesBackward() async {
    let model = withDependencies {
      $0.engine = stream([
        .progress(EngineProgress(phase: .transcribing, message: "x", fraction: 0.6)),
        .progress(EngineProgress(phase: .transcribing, message: "x", fraction: 0.4)),
      ])
    } operation: { SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav")) }
    await model.startTranscription()
    expectNoDifference(model.progressFraction, 0.6)
  }

  @Test func tailPhaseGoesIndeterminate() async {
    let model = withDependencies {
      $0.engine = stream([
        .progress(EngineProgress(phase: .transcribing, message: "x", fraction: 1.0)),
        .progress(EngineProgress(phase: .converting, message: "Converting audio")),
      ])
    } operation: { SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav")) }
    await model.startTranscription()
    #expect(model.isProgressDeterminate == false)
    expectNoDifference(model.progressMessage, "Converting audio")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Build/run. Expected: compile error — `progressFraction` / `determinateValue` / `progressNote` do not exist.

- [ ] **Step 3: Write minimal implementation**

In `SongTabModel.swift`, add to `// MARK: - Properties`:

```swift
  @ObservationIgnored private var maxFraction: Double?
```

Add to `// MARK: - Display Text`:

```swift
  let progressNote = "This can take several minutes — longer files take longer."
```

Add to `// MARK: - View Helpers`:

```swift
  var progressFraction: Double? {
    guard case .transcribing(let p) = phase,
          let p, p.phase == .transcribing, p.fraction != nil
    else { return nil }
    return maxFraction
  }
  var isProgressDeterminate: Bool { progressFraction != nil }
  var determinateValue: Double { maxFraction ?? 0 }
```

In `startTranscription()`, update `maxFraction` when a transcribing fraction arrives. Replace the `.progress` case (line 89):

```swift
        case .progress(let progress):
          if progress.phase == .transcribing, let f = progress.fraction {
            maxFraction = max(maxFraction ?? 0, f)
          }
          phase = .transcribing(progress)
```

Reset `maxFraction` at the start of a run. In `start()` (line 74 area) after `phase = .transcribing(nil)`, add `maxFraction = nil`.

- [ ] **Step 4: Run test to verify it passes**

Build/run `SongTabTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabModel.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabTests.swift
git commit -m "feat(app): derive monotonic transcription progress + note on SongTabModel"
```

---

### Task 6: Swift — elapsed tick task + `etaMessage`

Add a `Clock` dependency, a single cancellable tick task that advances `elapsedSeconds`, and an ETA string computed by a pure, directly-tested function (honest across the transcribe/align split).

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabModel.swift`
- Test: `SongTabTests.swift`

**Interfaces:**
- Consumes: `@Dependency(\.continuousClock)`; `maxFraction`, `phase` (Task 5).
- Produces: `var etaMessage: String?`; `static func etaText(elapsedSeconds: Double, fraction: Double) -> String?`; private `var elapsedSeconds: Double`, `var tickTask: Task<Void, Never>?`.

- [ ] **Step 1: Write the failing test**

Add to `SongTabTests.swift` (pure ETA math needs no clock):

```swift
  @Test func etaTextBelowThresholdIsNil() {
    expectNoDifference(SongTabModel.etaText(elapsedSeconds: 1, fraction: 0.01), nil)
  }

  @Test func etaTextDuringTranscribeFormatsRemaining() {
    // fraction 0.25 -> within-transcribe p = 0.5; elapsed 120s -> remaining 120s.
    expectNoDifference(
      SongTabModel.etaText(elapsedSeconds: 120, fraction: 0.25),
      "About 2 min remaining")
  }

  @Test func etaTextUnderOneMinute() {
    // p = 0.8, elapsed 120s -> remaining 30s.
    expectNoDifference(
      SongTabModel.etaText(elapsedSeconds: 120, fraction: 0.4),
      "Less than a minute remaining")
  }

  @Test func etaTextWhileAligningIsNonNumeric() {
    expectNoDifference(
      SongTabModel.etaText(elapsedSeconds: 300, fraction: 0.7),
      "Aligning words — almost done")
  }
```

And a tick-task test with `TestClock`:

```swift
  @Test func elapsedAdvancesWithClock() async {
    let clock = TestClock()
    let model = withDependencies {
      $0.continuousClock = clock
      var client = EngineClient.testValue
      client.transcribe = { _ in
        AsyncThrowingStream { c in
          c.yield(.progress(EngineProgress(phase: .transcribing, message: "x", fraction: 0.25)))
          // leave the stream open so the tick task keeps running
        }
      }
      $0.engine = client
    } operation: { SongTabModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav")) }

    model.start()
    await clock.advance(by: .seconds(120))
    // fraction 0.25 -> p 0.5, elapsed 120 -> remaining 120s
    expectNoDifference(model.etaMessage, "About 2 min remaining")
    model.cancel()
  }
```

- [ ] **Step 2: Run test to verify it fails**

Build/run. Expected: compile error — `etaText` / `etaMessage` / `continuousClock` usage does not exist.

- [ ] **Step 3: Write minimal implementation**

In `SongTabModel.swift`, add the dependency under `// MARK: - Dependencies`:

```swift
  @ObservationIgnored @Dependency(\.continuousClock) var clock
```

Add properties:

```swift
  @ObservationIgnored private var elapsedSeconds: Double = 0
  @ObservationIgnored private var tickTask: Task<Void, Never>?
```

Add the pure ETA function and the `etaMessage` helper:

```swift
  static func etaText(elapsedSeconds: Double, fraction: Double) -> String? {
    if fraction >= 0.5 { return "Aligning words — almost done" }
    let p = fraction / 0.5                      // progress within the transcribe half
    guard p >= 0.05 else { return nil }         // too early to estimate
    let remaining = elapsedSeconds * (1 - p) / p
    if remaining < 60 { return "Less than a minute remaining" }
    let minutes = Int((remaining / 60).rounded())
    return "About \(max(minutes, 1)) min remaining"
  }

  var etaMessage: String? {
    guard let f = progressFraction else { return nil }
    return Self.etaText(elapsedSeconds: elapsedSeconds, fraction: f)
  }
```

Start the tick task in `start()` (after setting `.transcribing(nil)` and resetting `maxFraction`):

```swift
    elapsedSeconds = 0
    startTicking()
```

Add the tick lifecycle helpers:

```swift
  private func startTicking() {
    tickTask?.cancel()
    let start = clock.now
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let d = start.duration(to: self.clock.now)
        self.elapsedSeconds =
          Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        try? await self.clock.sleep(for: .seconds(1))
      }
    }
  }

  private func stopTicking() {
    tickTask?.cancel()
    tickTask = nil
  }
```

Tear the tick task down on terminal states. In `startTranscription()`, call `stopTicking()` on both `.loaded` (after `phase = .loaded`) and in the `catch` that sets `.failed`. Do **not** stop it in the `CancellationError` branch (existing behavior leaves last progress on tab teardown). Also add `stopTicking()` to `retryTapped()` (before re-queueing) and, to be safe on teardown, `deinit`-equivalent: since this is `@MainActor`, add a `func tearDown()` the parent already calls — check `RootModel`; if there is no teardown hook, cancelling in `.loaded`/`.failed`/`retryTapped` plus `cancel()` covers the lifecycle. Add `stopTicking()` to `cancel()` as well:

```swift
  func cancel() {
    task?.cancel()
    stopTicking()
  }
```

- [ ] **Step 4: Run test to verify it passes**

Build/run `SongTabTests`. Expected: PASS. If the `TestClock` tick test races, wrap the model interaction with `withMainSerialExecutor { }` per `pfw-testing`.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabModel.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabTests.swift
git commit -m "feat(app): add elapsed tick + self-calibrating ETA to SongTabModel"
```

---

### Task 7: Swift — `SongTabView` determinate bar + note + ETA

Render the real bar when determinate, the indeterminate spinner otherwise, plus the note and ETA lines. View holds no logic.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabView.swift`

**Interfaces:**
- Consumes: `model.isProgressDeterminate`, `model.determinateValue`, `model.progressMessage`, `model.progressNote`, `model.etaMessage`, `model.showsCancel` (all from Tasks 5–6).

- [ ] **Step 1: Update the view**

Replace the `.queued, .transcribing` branch body (lines 9–18):

```swift
    case .queued, .transcribing:
      VStack(spacing: 14) {
        if model.isProgressDeterminate {
          ProgressView(value: model.determinateValue)
            .progressViewStyle(.linear)
            .frame(maxWidth: 320)
        } else {
          ProgressView()
        }
        Text(model.progressMessage).foregroundStyle(Color(white: 0.7))
        Text(model.progressNote)
          .font(.caption)
          .multilineTextAlignment(.center)
          .foregroundStyle(Color(white: 0.5))
          .frame(maxWidth: 320)
        if let eta = model.etaMessage {
          Text(eta).font(.caption).foregroundStyle(Color(white: 0.5))
        }
        if model.showsCancel {
          Button(model.cancelButtonLabel) { onCancel() }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black)
```

- [ ] **Step 2: Build and run the app to eyeball it**

Build and launch the app (per repo run instructions), import a short audio file, and confirm: "Preparing audio…" + spinner, then a filling bar with "Transcribing audio…", the note, and a live ETA; near the end the label reads "Aligning words — almost done"; then a brief indeterminate "Converting audio"/"Finding silence" before the editor loads.

- [ ] **Step 3: Run the full Swift test suite**

Run the app's test target. Expected: all SongTab + Core tests pass.

- [ ] **Step 4: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabView.swift
git commit -m "feat(app): show determinate transcription bar, note, and ETA"
```

---

## Self-review notes

- **Spec coverage:** subprocess-driven fraction (T1–T4), 100%≠done tail transition (T5 `tailPhaseGoesIndeterminate`), honest ETA across the split (T6 `etaText`), clamp/NaN/monotonic/first+final (T1, T4, T5), Preparing window reword (T3), note + live ETA (T6/T7), version pin already satisfied. Covered.
- **Backward-compat:** all Python callback params are keyword-only with `None` defaults; `EngineProgress.fraction` defaults to `nil`. No existing caller changes.
- **Cancellation:** `cancel()` and `.loaded`/`.failed`/`retryTapped` stop the tick task; the `CancellationError` branch intentionally does not, preserving today's "leave last progress on teardown" behavior and untouched `onReadyForNext` semantics.
- **Type consistency:** `maxFraction`, `progressFraction`, `determinateValue`, `elapsedSeconds`, `etaText`, `etaMessage` names are used identically across tasks.
