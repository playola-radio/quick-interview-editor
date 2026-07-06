# Step 2 — Import + Live Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Before writing any Swift code, invoke every applicable `pfw-*` skill** (see CLAUDE.md mapping) and list them in your checklist.

**Goal:** Let a user drop any audio clip onto the app and watch it transcribe live — each clip in its own tab — by adding a `plan` engine command, a streaming `EngineClient.transcribe` surface, per-song tab models, and honest progress/cancel/error UI.

**Architecture:** The Python engine gains a `plan` subcommand that analyzes (transcribe → canonical AIFF → per-word samples → silences) and emits `edit-plan.json` to stdout with `segments: []`, streaming `QIE_EVENT` progress lines to stderr. Swift wraps it as `EngineClient.transcribe(URL) -> AsyncThrowingStream<EngineEvent, Error>`. A `RootModel` owns an in-app tab bar of `SongTabModel`s; each tab consumes the stream, drives a progress→loaded→failed phase, and hands the finished `EditPlan` to the Step-1 `TranscriptPageModel` (now plan-driven) as its loaded-state renderer.

**Tech Stack:** Python 3.12 (engine, pytest), Swift 6 / SwiftUI (macOS 15), Point-Free stack (`swift-dependencies`, `swift-identified-collections`, `swift-custom-dump`, `IssueReporting`), Swift Testing, XcodeGen.

## Global Constraints

- **Build/test the app:** `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates`.
- **After creating/renaming any file under `QuickInterviewEditor/`**, run `cd QuickInterviewEditor && xcodegen generate` before `xcodebuild`, and commit the regenerated `.xcodeproj` with the task.
- **Test target must NOT directly link `swift-dependencies`** — it gets `Dependencies` transitively via the app target. Do not add it to `project.yml`'s test target (breaks `withDependencies` overrides).
- **Value comparisons in tests** use `expectNoDifference` / `expectDifference` (CustomDump), never raw `#expect(a == b)`.
- **Never use `Task.sleep` in tests.** Use `withMainSerialExecutor` (from `Dependencies`) + immediate test doubles for ordering.
- **Test naming:** camelCase, no underscores. Tests colocate next to the model.
- **Signing:** `DEVELOPMENT_TEAM: FSRSPV9N9Q` (already in `project.yml`).
- **Engine env:** `.venv` (Homebrew python3.12; uses `afconvert`, not ffmpeg). Run engine tests with `python3 -m pytest -q` (or `.venv/bin/python -m pytest -q`).
- **Dev engine path is dev-only** (roadmap Phase 1 packages the real helper). Mark it clearly.
- **MV rule:** zero logic in views. Every string/flag/decision is a model property. Models are `@MainActor @Observable`, inherit `ViewModel`, and follow the CLAUDE.md `// MARK:` order.
- **Out of scope:** waveform, slices/export, packaging/notarization, `@Shared` promotion, work-dir cleanup, transcription queueing.

---

## Task 1: Engine `plan` subcommand (Python)

Add an analyze-only command that reuses existing engine internals and emits the app's contract to stdout with progress on stderr. Never writes beside the user's clip.

**Files:**
- Modify: `logic_markers/cli.py` (add `_emit_event`, `run_plan`, `_cmd_plan`, and the `plan` subparser)
- Test: `tests/test_plan.py` (create)

**Interfaces:**
- Consumes: `logic_markers.whisperx_backend.transcribe_transcript`, `logic_markers.audio.convert_to_aiff` / `read_aiff_mono`, `logic_markers.aiff_markers.read_sample_rate` / `parse_chunks`, `logic_markers.silence.detect_silences`, `logic_markers.editplan.build_edit_plan`, `logic_markers.words.Transcript`.
- Produces: CLI `python -m logic_markers.cli plan <audio> --work-dir <dir> [--sample-rate N] [--refresh]` → one `edit-plan.json` on stdout; `QIE_EVENT {json}` lines on stderr; `segments: []`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_plan.py`. The test writes a tiny real WAV (so `afconvert` works) and **pre-seeds the transcript cache in the work dir** so WhisperX never runs:

```python
import json
import subprocess
import sys
import wave
from pathlib import Path

from logic_markers.words import Segment, Transcript, Word


def _write_wav(path: Path, seconds=0.5, sr=16000):
    n = int(seconds * sr)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"\x00\x00" * n)  # silence is fine; alignment is pre-seeded


def _seed_transcript(cache: Path):
    t = Transcript(
        words=(
            Word(id=1, text="hello", start=0.05, end=0.15),
            Word(id=2, text="world", start=0.20, end=0.35),
        ),
        segments=(Segment(id=1, word_ids=(1, 2), text="hello world"),),
    )
    cache.write_text(json.dumps(t.to_dict()))


def _run_plan(tmp_path: Path):
    src = tmp_path / "clip.wav"
    _write_wav(src)
    work = tmp_path / "work"
    work.mkdir()
    _seed_transcript(work / "clip.wav.transcript.json")
    proc = subprocess.run(
        [sys.executable, "-m", "logic_markers.cli", "plan",
         str(src), "--work-dir", str(work)],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stderr
    return src, work, proc


def test_plan_emits_editplan_json_with_empty_segments(tmp_path):
    src, _work, proc = _run_plan(tmp_path)
    plan = json.loads(proc.stdout)
    assert plan["schema_version"] == 1
    assert plan["segments"] == []
    assert [w["text"] for w in plan["words"]] == ["hello", "world"]
    assert all(w["start_sample"] is not None and w["end_sample"] is not None
               for w in plan["words"])
    assert plan["source"]["sample_rate"] > 0
    assert plan["source"]["duration_samples"] > 0


def test_plan_writes_nothing_beside_source(tmp_path):
    src, _work, _proc = _run_plan(tmp_path)
    siblings = sorted(p.name for p in src.parent.iterdir())
    assert siblings == ["clip.wav"]  # no .transcript.json / .aiff / .edit-plan.json


def test_plan_emits_progress_events_on_stderr(tmp_path):
    _src, _work, proc = _run_plan(tmp_path)
    phases = []
    for line in proc.stderr.splitlines():
        if line.startswith("QIE_EVENT "):
            evt = json.loads(line[len("QIE_EVENT "):])
            if evt.get("type") == "progress":
                phases.append(evt["phase"])
    assert "transcribing" in phases
    assert "writing_plan" in phases
    assert phases == sorted(phases, key=["transcribing", "converting",
            "analyzing_silence", "writing_plan"].index)  # in canonical order
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m pytest tests/test_plan.py -q`
Expected: FAIL — `plan` is not a known subcommand (argparse error / nonzero exit).

- [ ] **Step 3: Implement `plan` in `logic_markers/cli.py`**

Add near the top (after imports):

```python
def _emit_event(event: dict) -> None:
    """One machine event per stderr line; stdout stays pure JSON."""
    print(f"QIE_EVENT {json.dumps(event)}", file=sys.stderr, flush=True)


def _progress(phase: str, message: str) -> None:
    _emit_event({"type": "progress", "phase": phase, "message": message})
```

Add a work-dir-scoped transcript loader (does NOT write beside the source):

```python
def _load_or_transcribe_transcript_in(source: Path, work_dir: Path, refresh: bool) -> Transcript:
    from .whisperx_backend import transcribe_transcript

    cache = work_dir / (source.name + ".transcript.json")
    if cache.exists() and not refresh:
        return Transcript.from_dict(json.loads(cache.read_text()))
    transcript = transcribe_transcript(source)
    cache.write_text(json.dumps(transcript.to_dict(), indent=2))
    return transcript
```

Add the analyze routine and command:

```python
def run_plan(source: Path, work_dir: Path, sample_rate: int, refresh: bool = False) -> dict:
    """Analyze (no cut): transcript + canonical AIFF + samples + silences → edit-plan dict."""
    work_dir.mkdir(parents=True, exist_ok=True)

    _progress("transcribing", "Transcribing with WhisperX (first run downloads models)")
    transcript = _load_or_transcribe_transcript_in(source, work_dir, refresh)

    _progress("converting", "Converting audio")
    aiff_path = work_dir / (source.stem + ".plan.aiff")
    convert_to_aiff(source, aiff_path, sample_rate)
    aiff_bytes = aiff_path.read_bytes()
    sr = aiff_markers.read_sample_rate(aiff_bytes)
    _, chunks = aiff_markers.parse_chunks(aiff_bytes)
    channels = struct.unpack(">h", dict(chunks)[b"COMM"][0:2])[0]
    mono, _ = read_aiff_mono(aiff_bytes)
    total_samples = len(mono)

    _progress("analyzing_silence", "Finding silence")
    silences = detect_silences(mono, sr, **SILENCE_PARAMS)

    _progress("writing_plan", "Preparing transcript")
    return build_edit_plan(
        source_path=source, sample_rate=sr, channels=channels,
        total_samples=total_samples, params={**SNAP_PARAMS, **SILENCE_PARAMS},
        transcript=transcript, silences=silences, segments=[],
    )


def _cmd_plan(args) -> int:
    plan = run_plan(args.input, args.work_dir, args.sample_rate, args.refresh)
    json.dump(plan, sys.stdout)
    sys.stdout.flush()
    return 0
```

Wire the subparser inside `main` (next to the others):

```python
    p = sub.add_parser("plan", help="analyze audio into an edit-plan (no cut); JSON to stdout")
    p.add_argument("input", type=Path, help="source audio (wav/mp3/m4a/aiff)")
    p.add_argument("--work-dir", type=Path, required=True, help="scratch dir for caches (NOT next to source)")
    p.add_argument("--sample-rate", type=int, default=44100)
    p.add_argument("--refresh", action="store_true", help="ignore cached transcript")
    p.set_defaults(func=_cmd_plan)
```

Note: `build_edit_plan` already emits `"silences": [{"start": s.start, "end": s.end} …]` with integer sample indices, and `"segments": []` when `segments=[]` — no change needed there. `build_edit_plan` fills `start_sample`/`end_sample` via `_sample(w.start/w.end, sr)`; a missing `end` yields `end_sample: null`, so also fill missing ends: in `run_plan`, before `build_edit_plan`, normalize the transcript's word ends using the engine's own fallback so the UI always has a range:

```python
    from .editplan import _word_end
    by_id = {w.id: w for w in transcript.words}
    filled = tuple(
        w if w.end is not None else Word(id=w.id, text=w.text, start=w.start,
                                         end=_word_end(w, by_id))
        for w in transcript.words
    )
    transcript = Transcript(words=filled, segments=transcript.segments)
```

(Insert this right after loading the transcript; import `Word` from `.words` at top: `from .words import Transcript, render_transcript` → add `Word as RichWord` or reuse existing import — use `from .words import Transcript` plus `from .words import Word as TWord` and build `TWord(...)`. Match the existing import style in the file.)

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m pytest tests/test_plan.py -q`
Expected: PASS (3 tests). Then `python3 -m pytest -q` — the full suite still green.

- [ ] **Step 5: Commit**

```bash
git add logic_markers/cli.py tests/test_plan.py
git commit -m "feat(engine): add plan subcommand (analyze-only, JSON to stdout, progress on stderr)"
```

---

## Task 2: EditPlan contract fixes — `Silence` as samples + empty-segments decoding

Retype `Silence` to integer sample indices (Codex-flagged: values are samples, not seconds) and prove an empty-`segments` plan decodes.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Models/EditPlan.swift:43-46`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Models/EditPlanDecodingTests.swift`

**Interfaces:**
- Produces: `EditPlan.Silence { var startSample: Int; var endSample: Int }` (JSON keys `"start"`/`"end"`).

- [ ] **Step 1: Write the failing test** — append to `EditPlanDecodingTests.swift`:

```swift
@Test func decodesSilencesAsSampleIntegers() throws {
  let json = """
  {"schema_version":1,
   "source":{"path":"a","sample_rate":44100,"channels":1,"duration_samples":100},
   "words":[],"silences":[{"start":1000,"end":2000}],"segments":[]}
  """.data(using: .utf8)!
  let plan = try JSONDecoder().decode(EditPlan.self, from: json)
  expectNoDifference(plan.silences, [EditPlan.Silence(startSample: 1000, endSample: 2000)])
}

@Test func decodesEmptySegments() throws {
  let json = """
  {"schema_version":1,
   "source":{"path":"a","sample_rate":44100,"channels":1,"duration_samples":100},
   "words":[],"silences":[],"segments":[]}
  """.data(using: .utf8)!
  let plan = try JSONDecoder().decode(EditPlan.self, from: json)
  expectNoDifference(plan.segments, [])
}
```

(If `EditPlanDecodingTests.swift` lacks `import CustomDump` / `import Testing` / `@testable import QuickInterviewEditor`, add them.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd QuickInterviewEditor && xcodegen generate && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates -only-testing:QuickInterviewEditorTests/EditPlanDecodingTests 2>&1 | tail -20`
Expected: FAIL — `Silence` has no `startSample`/`endSample`.

- [ ] **Step 3: Retype `Silence`** in `EditPlan.swift`:

```swift
  /// Engine emits SAMPLE indices here (start inclusive, end exclusive), not seconds.
  struct Silence: Codable, Equatable {
    var startSample: Int
    var endSample: Int
    enum CodingKeys: String, CodingKey {
      case startSample = "start"
      case endSample = "end"
    }
  }
```

- [ ] **Step 4: Run to verify it passes**

Run the same `-only-testing:…/EditPlanDecodingTests` command.
Expected: PASS. (No other code references `Silence.start/end`, so nothing else breaks — confirm with a full build in a later task.)

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Models/EditPlan.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Models/EditPlanDecodingTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "fix(model): type EditPlan.Silence as sample indices; test empty-segments decode"
```

---

## Task 3: Engine event + error types

Value types the streaming surface needs. No behavior yet.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Core/EngineEvent.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Core/EngineEventTests.swift`

**Interfaces:**
- Produces:
  - `enum EngineEvent: Equatable, Sendable { case progress(EngineProgress); case completed(EditPlan) }`
  - `struct EngineProgress: Equatable, Sendable { var phase: Phase; var message: String; enum Phase: String, Equatable, Sendable { case transcribing; case converting; case analyzingSilence = "analyzing_silence"; case writingPlan = "writing_plan" } }`
  - `enum EngineClientError: Error, Equatable { case unimplemented(String); case engineNotFound(String); case engineFailed(String); case decodeFailed(String) }` conforming to `LocalizedError`.

- [ ] **Step 1: Write the failing test** — `EngineEventTests.swift`:

```swift
import Testing
@testable import QuickInterviewEditor

struct EngineEventTests {
  @Test func phaseDecodesFromEngineRawValue() {
    #expect(EngineProgress.Phase(rawValue: "analyzing_silence") == .analyzingSilence)
    #expect(EngineProgress.Phase(rawValue: "writing_plan") == .writingPlan)
    #expect(EngineProgress.Phase(rawValue: "transcribing") == .transcribing)
  }

  @Test func errorHasUserFacingDescription() {
    let e = EngineClientError.engineFailed("boom")
    #expect(e.errorDescription?.contains("boom") == true)
  }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd QuickInterviewEditor && xcodegen generate && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates -only-testing:QuickInterviewEditorTests/EngineEventTests 2>&1 | tail -20`
Expected: FAIL — types not found.

- [ ] **Step 3: Implement `EngineEvent.swift`:**

```swift
import Foundation

enum EngineEvent: Equatable, Sendable {
  case progress(EngineProgress)
  case completed(EditPlan)
}

struct EngineProgress: Equatable, Sendable {
  enum Phase: String, Equatable, Sendable {
    case transcribing
    case converting
    case analyzingSilence = "analyzing_silence"
    case writingPlan = "writing_plan"
  }
  var phase: Phase
  var message: String
}

enum EngineClientError: Error, Equatable, LocalizedError {
  case unimplemented(String)
  case engineNotFound(String)
  case engineFailed(String)
  case decodeFailed(String)

  var errorDescription: String? {
    switch self {
    case let .unimplemented(name): return "EngineClient.\(name) was called without a test override."
    case let .engineNotFound(path): return "Transcription engine not found at \(path)."
    case let .engineFailed(message): return "Transcription failed: \(message)"
    case let .decodeFailed(message): return "Could not read the transcription result: \(message)"
    }
  }
}
```

- [ ] **Step 4: Run to verify it passes** — same `-only-testing` command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Core/EngineEvent.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Core/EngineEventTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(core): add EngineEvent/EngineProgress/EngineClientError types"
```

---

## Task 4: `EngineClient.transcribe` surface + hardened `testValue` + `previewValue`

Grow the client with a streaming `transcribe`, make missing test overrides fail cleanly (Step-1 SIGTRAP follow-up), and add a preview value. Live `transcribe` is a placeholder here; Task 5 implements it.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Core/EngineClient.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Core/EngineClientTests.swift`

**Interfaces:**
- Consumes: `EngineEvent`, `EngineProgress`, `EngineClientError` (Task 3).
- Produces: `EngineClient.transcribe: @Sendable (URL) -> AsyncThrowingStream<EngineEvent, Error>`; `EngineClient.testValue` (both closures fail cleanly); `EngineClient.previewValue` (fixture-backed). `loadPlan` unchanged in signature.

*Design note:* the live engine creates its own work dir internally, so `transcribe` takes only the audio `URL` (simplification of the spec's `(URL, workDir)` — the model never needs the dir).

- [ ] **Step 1: Write the failing test** — replace `EngineClientTests.swift` body with:

```swift
import CustomDump
import Dependencies
import Foundation
import IssueReporting
import Testing
@testable import QuickInterviewEditor

struct EngineClientTests {
  @Test func liveValueDecodesFromURL() async throws {
    let url = Bundle(for: EngineClientBundleToken.self)
      .url(forResource: "edit-plan", withExtension: "json")!
    let plan = try await EngineClient.liveValue.loadPlan(url)
    expectNoDifference(plan.words.count, 122)
  }

  @Test func testValueLoadPlanFailsCleanlyWithoutOverride() async {
    await withKnownIssue {
      _ = try await EngineClient.testValue.loadPlan(URL(fileURLWithPath: "/x"))
    }
  }

  @Test func testValueTranscribeFailsCleanlyWithoutOverride() async {
    await withKnownIssue {
      for try await _ in EngineClient.testValue.transcribe(URL(fileURLWithPath: "/x")) {}
    }
  }

  @Test func previewValueYieldsFixture() async throws {
    var got: EditPlan?
    for try await event in EngineClient.previewValue.transcribe(URL(fileURLWithPath: "/x")) {
      if case let .completed(plan) = event { got = plan }
    }
    expectNoDifference(got?.words.count, 122)
  }
}

private final class EngineClientBundleToken {}
```

`withKnownIssue` passes only if the body reports an issue (via `reportIssue`) or throws — proving the default fails cleanly instead of trapping.

- [ ] **Step 2: Run to verify it fails**

Run: `cd QuickInterviewEditor && xcodegen generate && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates -only-testing:QuickInterviewEditorTests/EngineClientTests 2>&1 | tail -25`
Expected: FAIL — `transcribe`, `previewValue` don't exist.

- [ ] **Step 3: Rewrite `EngineClient.swift`:**

```swift
import Dependencies
import Foundation
import IssueReporting

struct EngineClient: Sendable {
  var loadPlan: @Sendable (URL) async throws -> EditPlan
  var transcribe: @Sendable (URL) -> AsyncThrowingStream<EngineEvent, Error>
}

extension EngineClient: DependencyKey {
  static let liveValue = EngineClient(
    loadPlan: { url in try EditPlan.decoded(from: url) },
    transcribe: { url in EngineClient.liveTranscribe(audio: url) }  // Task 5
  )
}

extension EngineClient: TestDependencyKey {
  static let testValue = EngineClient(
    loadPlan: { _ in
      reportIssue("EngineClient.loadPlan called without a test override")
      throw EngineClientError.unimplemented("loadPlan")
    },
    transcribe: { _ in
      AsyncThrowingStream { continuation in
        reportIssue("EngineClient.transcribe called without a test override")
        continuation.finish(throwing: EngineClientError.unimplemented("transcribe"))
      }
    }
  )

  /// Used automatically by SwiftUI previews; convenient fixture, never in tests.
  static let previewValue = EngineClient(
    loadPlan: { _ in .fixture },
    transcribe: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.completed(.fixture))
        continuation.finish()
      }
    }
  )
}

extension DependencyValues {
  var engine: EngineClient {
    get { self[EngineClient.self] }
    set { self[EngineClient.self] = newValue }
  }
}
```

Add a temporary stub so it compiles before Task 5 (delete in Task 5):

```swift
extension EngineClient {
  static func liveTranscribe(audio: URL) -> AsyncThrowingStream<EngineEvent, Error> {
    AsyncThrowingStream { $0.finish(throwing: EngineClientError.engineNotFound("live engine not implemented yet")) }
  }
}
```

- [ ] **Step 4: Run to verify it passes** — same `-only-testing:…/EngineClientTests` command. Expected: PASS (4 tests). Then run the full suite once — existing `TranscriptPageTests` still override `engine.loadPlan`, so they stay green.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Core/EngineClient.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Core/EngineClientTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(core): stream EngineClient.transcribe; harden testValue; add previewValue"
```

---

## Task 5: Live `transcribe` subprocess implementation

Spawn the dev engine in its own process group, parse `QIE_EVENT` progress from stderr, decode the `edit-plan.json` from stdout, and kill the whole group on cancel. Not unit-tested (real subprocess); verified manually + covered by a skipped-when-unavailable integration test.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Core/LiveEngine.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Core/EngineClient.swift` (remove the Task-4 stub; point `liveValue.transcribe` at the real impl)
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Core/LiveEngineIntegrationTests.swift` (create; auto-skips without `.venv`)

**Interfaces:**
- Consumes: `EngineEvent`, `EngineProgress`, `EngineClientError`.
- Produces: `enum LiveEngine { static func transcribe(audio: URL) -> AsyncThrowingStream<EngineEvent, Error> }`.

- [ ] **Step 1: Implement `LiveEngine.swift`.** Key requirements, in order:

1. **Resolve the dev engine** (dev-only constant; documented): repo root = the `logic-utils` checkout containing `.venv`. Resolve via an env override first, else a compiled-in path:

```swift
import Foundation

enum LiveEngine {
  // DEV ONLY. The notarized helper is roadmap Phase 1. Override with QIE_ENGINE_REPO.
  private static var repoRoot: URL {
    if let p = ProcessInfo.processInfo.environment["QIE_ENGINE_REPO"] {
      return URL(fileURLWithPath: p)
    }
    return URL(fileURLWithPath: #filePath)            // …/QuickInterviewEditor/QuickInterviewEditor/Core/LiveEngine.swift
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()  // → repo root
  }
  private static var pythonURL: URL { repoRoot.appendingPathComponent(".venv/bin/python") }
```

2. **Make a per-job work dir** under Application Support:

```swift
  private static func makeWorkDir() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("Quick Interview Editor/Jobs/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }
```

3. **`transcribe`** returns an `AsyncThrowingStream` whose builder task: validates the python exists (`else finish(throwing: .engineNotFound(pythonURL.path))`); spawns via a **new process group**; reads stderr lines, decoding `QIE_EVENT ` progress → `continuation.yield(.progress(...))`; accumulates stdout; on exit 0 decodes stdout → `.completed`, else `.engineFailed(stderr tail)`; on `continuation.onTermination` (cancel) kills the group.

Use a small `posix_spawn` wrapper so the child is a group leader (Foundation `Process` can't set a new pgid). Sketch:

```swift
  static func transcribe(audio: URL) -> AsyncThrowingStream<EngineEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            throw EngineClientError.engineNotFound(pythonURL.path)
          }
          let work = try makeWorkDir()
          let proc = try SpawnedProcess(
            executable: pythonURL,
            arguments: ["-m", "logic_markers.cli", "plan", audio.path,
                        "--work-dir", work.path, "--sample-rate", "44100"],
            currentDirectory: repoRoot)          // sets its own process group

          // Stream stderr lines for progress; collect stdout bytes.
          async let stdoutData = proc.readStdoutToEnd()
          for try await line in proc.stderrLines() {
            guard line.hasPrefix("QIE_EVENT ") else { continue }
            let json = Data(line.dropFirst("QIE_EVENT ".count).utf8)
            if let evt = try? JSONDecoder().decode(WireEvent.self, from: json),
               evt.type == "progress", let phase = EngineProgress.Phase(rawValue: evt.phase ?? "") {
              continuation.yield(.progress(EngineProgress(phase: phase, message: evt.message ?? "")))
            }
          }
          let code = await proc.waitForExit()
          let out = try await stdoutData
          if code != 0 {
            throw EngineClientError.engineFailed(proc.stderrTail())
          }
          do {
            let plan = try JSONDecoder().decode(EditPlan.self, from: out)
            continuation.yield(.completed(plan))
            continuation.finish()
          } catch {
            throw EngineClientError.decodeFailed(String(describing: error))
          }
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }  // SpawnedProcess kills the group on deinit/cancel
    }
  }

  private struct WireEvent: Decodable { var type: String; var phase: String?; var message: String? }
}
```

`SpawnedProcess` (same file) wraps `posix_spawn` with `POSIX_SPAWN_SETPGROUP` (pgid 0 ⇒ child becomes its own group leader), exposes async stdout/stderr reads over `Pipe` file handles, `waitForExit()`, a captured `stderrTail()`, and on cancel/deinit sends `kill(-pid, SIGTERM)` then, after a short grace, `kill(-pid, SIGKILL)`, and closes/drains both pipes so shutdown can't deadlock. Implement it plainly with `posix_spawn`, `Pipe`, and a `DispatchSource`/`FileHandle` reader; keep it in this one file. **Do not** rely on `Process.terminate()`.

- [ ] **Step 2: Point the live value at it** — in `EngineClient.swift`, delete the Task-4 `liveTranscribe` stub extension and set `transcribe: { url in LiveEngine.transcribe(audio: url) }`.

- [ ] **Step 3: Add an auto-skipping integration test** — `LiveEngineIntegrationTests.swift`:

```swift
import Foundation
import Testing
@testable import QuickInterviewEditor

struct LiveEngineIntegrationTests {
  private var venvPython: String? {
    let repo = ProcessInfo.processInfo.environment["QIE_ENGINE_REPO"]
    guard let repo else { return nil }
    let p = repo + "/.venv/bin/python"
    return FileManager.default.isExecutableFile(atPath: p) ? p : nil
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["QIE_RUN_LIVE_ENGINE"] == "1"))
  func transcribesASampleClipEndToEnd() async throws {
    // Only runs when QIE_RUN_LIVE_ENGINE=1 and QIE_ENGINE_REPO points at a repo
    // with a working .venv and a small committed sample clip. Manual/CI-gated.
    try #require(venvPython != nil)
    // … drive LiveEngine.transcribe against a tiny clip, assert a .completed EditPlan …
  }
}
```

(This test is opt-in; the process-group kill is verified manually — see Step 4.)

- [ ] **Step 4: Manual verification (record results in the PR):**

1. `cd QuickInterviewEditor && xcodegen generate && xcodebuild build -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates` — compiles.
2. With a real `.venv` present, run the app (or the opt-in test), drop a short clip, confirm progress phases advance and a transcript loads.
3. Start a transcription, cancel it, and confirm no orphaned `python`/`afconvert` remain: `pgrep -laf 'logic_markers.cli plan|afconvert'` returns nothing after cancel.

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Core/LiveEngine.swift \
        QuickInterviewEditor/QuickInterviewEditor/Core/EngineClient.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Core/LiveEngineIntegrationTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(core): live transcribe subprocess with process-group cancel"
```

---

## Task 6: `TranscriptPageModel` becomes plan-driven (renderer)

Let the page render an already-decoded `EditPlan` (from the transcribe stream) without a URL/engine round-trip. Additive — the Step-1 URL path stays for the live-decode/preview seam, so existing tests keep passing.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/TranscriptPage/TranscriptPageTests.swift`

**Interfaces:**
- Produces: `TranscriptPageModel(editPlan: EditPlan)` — populates `words` immediately; `viewAppeared` is a no-op when constructed this way.

- [ ] **Step 1: Write the failing test** — append to `TranscriptPageTests.swift`:

```swift
@Test func initWithEditPlanPopulatesWordsImmediately() {
  let model = TranscriptPageModel(editPlan: Fixtures.editPlan())
  expectNoDifference(model.words.count, 122)
  #expect(model.words.first { $0.text == "want" }?.isRunTogether == true)
}
```

- [ ] **Step 2: Run to verify it fails** — `-only-testing:QuickInterviewEditorTests/TranscriptPageTests`. Expected: FAIL (no such initializer).

- [ ] **Step 3: Add the convenience init** in `TranscriptPageModel.swift` (in the Initialization MARK):

```swift
  convenience init(editPlan: EditPlan) {
    self.init(planURL: nil)
    self.editPlan = editPlan
    recomputeWords()
  }
```

`recomputeWords()` is `private` but in-class, so this compiles. `viewAppeared()` already guards `let planURL else { return }`, so a plan-driven model won't reload.

- [ ] **Step 4: Run to verify it passes** — same command. Expected: PASS (existing tests + the new one).

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/TranscriptPage/TranscriptPageModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/TranscriptPage/TranscriptPageTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(transcript): plan-driven init so the page renders a supplied EditPlan"
```

---

## Task 7: `SongTabModel` — one song's transcribe→load lifecycle

Owns a single clip: consumes the transcribe stream, drives a phase, exposes display strings, and composes a `TranscriptPageModel` when loaded. Cancel/retry included.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/SongTab/SongTabTests.swift`

**Interfaces:**
- Consumes: `EngineClient.transcribe`, `EngineEvent`, `EngineProgress`, `TranscriptPageModel(editPlan:)`.
- Produces:
  - `final class SongTabModel: ViewModel, Identifiable` with `let id: UUID`, `let sourceURL: URL`.
  - `enum Phase: Equatable { case transcribing(EngineProgress?); case loaded; case failed(String) }`, `var phase: Phase`.
  - `var transcript: TranscriptPageModel?` (set on `.loaded`).
  - Actions: `func startTranscription() async`, `func start()`, `func cancel()`, `func retryTapped()`.
  - Display: `var title: String`, `var progressMessage: String`, `var showsCancel: Bool`, `var errorMessage: String?`, `var isLoaded: Bool`.

- [ ] **Step 1: Write the failing tests** — `SongTabTests.swift`:

```swift
import CustomDump
import Dependencies
import Foundation
import Testing
@testable import QuickInterviewEditor

@MainActor
struct SongTabTests {
  private func stream(_ events: [EngineEvent], throwing error: Error? = nil)
    -> AsyncThrowingStream<EngineEvent, Error> {
    AsyncThrowingStream { c in
      for e in events { c.yield(e) }
      c.finish(throwing: error)
    }
  }

  @Test func progressThenCompletedWalksToLoaded() async {
    let plan = Fixtures.editPlan()
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    await withDependencies {
      $0.engine.transcribe = { [self] _ in
        stream([.progress(.init(phase: .transcribing, message: "Transcribing")),
                .completed(plan)])
      }
    } operation: {
      await model.startTranscription()
    }
    #expect(model.isLoaded)
    expectNoDifference(model.transcript?.words.count, 122)
  }

  @Test func progressUpdatesMessageBeforeCompletion() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    await withDependencies {
      $0.engine.transcribe = { [self] _ in
        stream([.progress(.init(phase: .converting, message: "Converting audio"))],
               throwing: CancellationError())
      }
    } operation: {
      await model.startTranscription()
    }
    // last observed progress message stays visible
    expectNoDifference(model.progressMessage, "Converting audio")
  }

  @Test func failureSetsFailedPhaseWithMessage() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    await withDependencies {
      $0.engine.transcribe = { [self] _ in
        stream([], throwing: EngineClientError.engineFailed("no models"))
      }
    } operation: {
      await model.startTranscription()
    }
    expectNoDifference(model.errorMessage, "Transcription failed: no models")
    #expect(!model.isLoaded)
  }

  @Test func titleIsFilenameWithoutExtension() {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/a/Interview_047.m4a"))
    expectNoDifference(model.title, "Interview_047")
  }
}
```

- [ ] **Step 2: Run to verify it fails** — `xcodegen generate` then `-only-testing:QuickInterviewEditorTests/SongTabTests`. Expected: FAIL — `SongTabModel` not found.

- [ ] **Step 3: Implement `SongTabModel.swift`:**

```swift
import Dependencies
import Foundation
import Observation

@MainActor
@Observable
final class SongTabModel: ViewModel, Identifiable {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.engine) var engine

  // MARK: - Initialization
  let id = UUID()
  let sourceURL: URL
  init(sourceURL: URL) {
    self.sourceURL = sourceURL
    super.init()
  }

  // MARK: - Phase
  enum Phase: Equatable {
    case transcribing(EngineProgress?)
    case loaded
    case failed(String)
  }

  // MARK: - Properties
  var phase: Phase = .transcribing(nil)
  var transcript: TranscriptPageModel?
  @ObservationIgnored private var task: Task<Void, Never>?

  // MARK: - Display Text
  let cancelButtonLabel = "Cancel"
  let retryButtonLabel = "Retry"
  let startingMessage = "Starting…"

  // MARK: - View Helpers
  var title: String { sourceURL.deletingPathExtension().lastPathComponent }
  var isLoaded: Bool { if case .loaded = phase { return true }; return false }
  var showsCancel: Bool { if case .transcribing = phase { return true }; return false }
  var progressMessage: String {
    if case let .transcribing(p) = phase { return p?.message ?? startingMessage }
    return ""
  }
  var errorMessage: String? { if case let .failed(m) = phase { return m }; return nil }

  // MARK: - User Actions
  func start() { task = Task { await startTranscription() } }

  func startTranscription() async {
    phase = .transcribing(nil)
    transcript = nil
    do {
      for try await event in engine.transcribe(sourceURL) {
        switch event {
        case let .progress(p): phase = .transcribing(p)
        case let .completed(plan):
          transcript = TranscriptPageModel(editPlan: plan)
          phase = .loaded
        }
      }
    } catch is CancellationError {
      // cancelled: leave last progress; the tab is being closed by RootModel
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  func cancel() { task?.cancel() }

  func retryTapped() { start() }
}
```

- [ ] **Step 4: Run to verify it passes** — same `-only-testing` command. Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/SongTab/SongTabTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(tab): SongTabModel drives transcribe stream to a loaded transcript"
```

---

## Task 8: `RootModel` — the tab bar owner

Owns the tabs, opens one per dropped/picked file, selects/closes them, and shows the empty state.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/RootPage/RootModel.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/RootPage/RootTests.swift`

**Interfaces:**
- Consumes: `SongTabModel`, `EngineClient.transcribe` (for the tabs it starts).
- Produces:
  - `final class RootModel: ViewModel` with `var tabs: IdentifiedArrayOf<SongTabModel>`, `var selectedTabID: SongTabModel.ID?`, `var isImporterPresented: Bool`.
  - Actions: `func fileDropped(_ urls: [URL])`, `func filePicked(_ url: URL)`, `func importButtonTapped()`, `func tabSelected(_ id:)`, `func closeTab(_ id:)`.
  - Display: `var showsEmptyState: Bool`, plus empty-state / import copy.

- [ ] **Step 1: Write the failing tests** — `RootTests.swift`:

```swift
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing
@testable import QuickInterviewEditor

@MainActor
struct RootTests {
  private func neverCompleting() -> AsyncThrowingStream<EngineEvent, Error> {
    AsyncThrowingStream { _ in }  // holds the tab in .transcribing; no completion
  }

  @Test func startsEmpty() {
    let model = withDependencies { $0.engine.transcribe = { _ in AsyncThrowingStream { $0.finish() } } }
      operation: { RootModel() }
    #expect(model.tabs.isEmpty)
    #expect(model.showsEmptyState)
  }

  @Test func openingAFileAddsAndSelectsATab() {
    withDependencies {
      $0.engine.transcribe = { _ in self.neverCompleting() }
    } operation: {
      let model = RootModel()
      model.filePicked(URL(fileURLWithPath: "/a/clip.m4a"))
      expectNoDifference(model.tabs.count, 1)
      #expect(model.selectedTabID == model.tabs.last?.id)
      #expect(!model.showsEmptyState)
    }
  }

  @Test func droppingTwoFilesOpensTwoTabs() {
    withDependencies {
      $0.engine.transcribe = { _ in self.neverCompleting() }
    } operation: {
      let model = RootModel()
      model.fileDropped([URL(fileURLWithPath: "/a.m4a"), URL(fileURLWithPath: "/b.m4a")])
      expectNoDifference(model.tabs.count, 2)
    }
  }

  @Test func closingATabRemovesItAndFixesSelection() {
    withDependencies {
      $0.engine.transcribe = { _ in self.neverCompleting() }
    } operation: {
      let model = RootModel()
      model.fileDropped([URL(fileURLWithPath: "/a.m4a"), URL(fileURLWithPath: "/b.m4a")])
      let first = model.tabs[0].id
      model.closeTab(first)
      expectNoDifference(model.tabs.count, 1)
      #expect(model.tabs[id: first] == nil)
      #expect(model.selectedTabID == model.tabs.first?.id)
    }
  }
}
```

*Note on async safety:* `neverCompleting()` never touches `testValue` and never completes, so each tab's background task stays suspended inside the `withDependencies` scope and is cancelled when its tab is closed — no override escapes scope. Tab-management assertions run synchronously right after `filePicked`/`fileDropped` because those append + select **before** the task does any work.

- [ ] **Step 2: Run to verify it fails** — `xcodegen generate` then `-only-testing:QuickInterviewEditorTests/RootTests`. Expected: FAIL — `RootModel` not found.

- [ ] **Step 3: Implement `RootModel.swift`:**

```swift
import Dependencies
import Foundation
import IdentifiedCollections
import Observation

@MainActor
@Observable
final class RootModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.engine) var engine

  // MARK: - Properties
  var tabs: IdentifiedArrayOf<SongTabModel> = []
  var selectedTabID: SongTabModel.ID?
  var isImporterPresented = false

  // MARK: - Display Text
  let emptyStateTitle = "Drop an audio clip to transcribe"
  let emptyStateSubtitle = "Drag a file here, or choose one to open."
  let importButtonLabel = "Open Audio File…"
  let closeTabLabel = "Close tab"

  // MARK: - View Helpers
  var showsEmptyState: Bool { tabs.isEmpty }
  var selectedTab: SongTabModel? { selectedTabID.flatMap { tabs[id: $0] } }

  // MARK: - User Actions
  func fileDropped(_ urls: [URL]) { for url in urls { openSong(url) } }
  func filePicked(_ url: URL) { openSong(url) }
  func importButtonTapped() { isImporterPresented = true }
  func tabSelected(_ id: SongTabModel.ID) { selectedTabID = id }

  func closeTab(_ id: SongTabModel.ID) {
    tabs[id: id]?.cancel()
    let wasSelected = selectedTabID == id
    tabs.remove(id: id)
    if wasSelected { selectedTabID = tabs.last?.id }
  }

  // MARK: - Private Helpers
  private func openSong(_ url: URL) {
    let tab = withDependencies(from: self) { SongTabModel(sourceURL: url) }
    tabs.append(tab)
    selectedTabID = tab.id
    tab.start()
  }
}
```

`withDependencies(from: self)` makes the child tab inherit the same (test-overridden) `engine`, so a dropped file in a test uses the test's `transcribe`.

- [ ] **Step 4: Run to verify it passes** — same command. Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/RootPage/RootModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/RootPage/RootTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(root): RootModel owns the song tab bar (open/select/close)"
```

---

## Task 9: Views + app wiring (dumb views, drag-drop, open panel, app entry)

Render everything from model state; no logic in views. Swap the app entry to `RootModel`/`RootView`.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/RootPage/RootView.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/ImportPage/ImportPageView.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabView.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/QuickInterviewEditorApp.swift`

**Interfaces:**
- Consumes: `RootModel`, `SongTabModel`, `TranscriptPageView`.

- [ ] **Step 1: `SongTabView.swift`** — switch on phase; zero logic beyond a `switch` that maps model state to subviews (the copy all comes from the model):

```swift
import SwiftUI

struct SongTabView: View {
  @Bindable var model: SongTabModel

  var body: some View {
    switch model.phase {
    case .transcribing:
      VStack(spacing: 14) {
        ProgressView()
        Text(model.progressMessage).foregroundStyle(Color(white: 0.7))
        if model.showsCancel {
          Button(model.cancelButtonLabel) { model.cancel() }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black)
    case .loaded:
      if let transcript = model.transcript { TranscriptPageView(model: transcript) }
    case .failed:
      VStack(spacing: 14) {
        Text(model.errorMessage ?? "").foregroundStyle(Color(red: 0.89, green: 0.58, blue: 0.58))
        Button(model.retryButtonLabel) { model.retryTapped() }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black)
    }
  }
}
```

Note: the `cancel()` here stops transcription but leaves the tab; closing the tab (Task 8 `closeTab`) is the tab strip's ✕ in `RootView`. (If you'd rather Cancel also close the tab, wire the button to a closure `onCancel` injected by `RootView` calling `root.closeTab(model.id)` — keep the decision consistent with the spec's "cancel returns to import"; simplest is: Cancel → `root.closeTab`. Pick one and note it in the PR.)

- [ ] **Step 2: `ImportPageView.swift`** — empty-state drop zone; binds copy from `RootModel`:

```swift
import SwiftUI

struct ImportPageView: View {
  @Bindable var model: RootModel

  var body: some View {
    VStack(spacing: 12) {
      Text(model.emptyStateTitle).font(.system(size: 20, weight: .semibold))
        .foregroundStyle(Color(white: 0.85))
      Text(model.emptyStateSubtitle).foregroundStyle(Color(white: 0.5))
      Button(model.importButtonLabel) { model.importButtonTapped() }
        .padding(.top, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
  }
}
```

- [ ] **Step 3: `RootView.swift`** — tab strip + selected tab or empty state; window-wide drop + `.fileImporter`:

```swift
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
  @Bindable var model: RootModel

  var body: some View {
    VStack(spacing: 0) {
      if !model.tabs.isEmpty { tabStrip }
      content
    }
    .frame(minWidth: 900, minHeight: 600)
    .background(Color.black)
    .dropDestination(for: URL.self) { urls, _ in
      model.fileDropped(urls.filter { $0.isFileURL }); return true
    }
    .fileImporter(isPresented: $model.isImporterPresented,
                  allowedContentTypes: [.audio]) { result in
      if case let .success(url) = result { model.filePicked(url) }
    }
  }

  private var tabStrip: some View {
    HStack(spacing: 6) {
      ForEach(model.tabs) { tab in
        HStack(spacing: 6) {
          Text(tab.title).lineLimit(1)
          Button { model.closeTab(tab.id) } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain).accessibilityLabel(model.closeTabLabel)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(model.selectedTabID == tab.id ? Color(white: 0.16) : Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { model.tabSelected(tab.id) }
      }
      Spacer()
    }
    .padding(8)
    .background(Color(white: 0.06))
  }

  @ViewBuilder private var content: some View {
    if let tab = model.selectedTab {
      SongTabView(model: tab)
    } else {
      ImportPageView(model: model)
    }
  }
}
```

- [ ] **Step 4: Swap the app entry** — `QuickInterviewEditorApp.swift`:

```swift
import SwiftUI

@main
struct QuickInterviewEditorApp: App {
  @State private var model = RootModel()

  var body: some Scene {
    WindowGroup {
      RootView(model: model)
        .preferredColorScheme(.dark)
    }
  }
}
```

- [ ] **Step 5: Build + run the full suite**

Run: `cd QuickInterviewEditor && xcodegen generate && xcodebuild test -scheme QuickInterviewEditor -destination 'platform=macOS' -allowProvisioningUpdates 2>&1 | tail -30`
Expected: build succeeds; all suites pass (Python + Swift). Views are untested by design; behavior is covered by the model tests.

- [ ] **Step 6: Commit**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views QuickInterviewEditor/QuickInterviewEditor/QuickInterviewEditorApp.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(ui): tabbed import → progress → transcript; drop + open-panel; RootView entry"
```

---

## Task 10: Docs — mark Step-2 follow-ups + engine contract note

Keep the paper trail current so Step 3+ picks up cleanly.

**Files:**
- Modify: `docs/superpowers/STEP1-FOLLOWUPS.md` (tick the resolved Step-2 items: testValue hardening done, `Silence` retyped)
- Modify: `CLAUDE.md` **only if** a build fact changed (e.g., note `plan` subcommand + `QIE_ENGINE_REPO`); otherwise skip.

- [ ] **Step 1:** In `STEP1-FOLLOWUPS.md`, move "testValue SIGTRAP hardening" and the `Silence` sample-typing note from "Track against Step 2" to a "Done in Step 2" section, referencing this plan.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/STEP1-FOLLOWUPS.md CLAUDE.md
git commit -m "docs: mark Step-2 follow-ups resolved (testValue, Silence typing)"
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- File import (drag + open panel) → Task 9 (`.dropDestination`, `.fileImporter`, `RootModel.fileDropped/filePicked`). ✅
- Live engine via `.venv` shell-out → Tasks 1 (`plan`) + 5 (`LiveEngine`). ✅
- Progress + cancel + errors → Task 1 (`QIE_EVENT`), Task 5 (stream + group-kill), Task 7 (phase/message/failed), Task 9 (progress/cancel/retry UI). ✅
- Result into Transcript page → Task 6 (`init(editPlan:)`) + Task 7 (compose) + Task 9 (render). ✅
- Multi-song tabs → Tasks 7/8/9. ✅
- `plan` emits samples+silences+empty segments, work-dir-clean → Task 1. ✅
- `testValue` hardening + `previewValue` → Task 4. ✅
- `Silence` retype, empty-segments decode, canonical rate → Task 2 (+ Task 1 `--sample-rate 44100`). ✅
- Concurrent tabs allowed → Tasks 7/8 (no queue; each tab its own task). ✅

**Placeholder scan:** No "TBD/handle errors"-style gaps; every code step shows code. Task 5's `SpawnedProcess` is described precisely (posix_spawn + `POSIX_SPAWN_SETPGROUP`, `kill(-pid, …)`, pipe drain) rather than pasted line-for-line — flagged as the one hand-written unit, with manual verification steps.

**Type consistency:** `transcribe: (URL) -> AsyncThrowingStream<EngineEvent, Error>` used identically in Tasks 4/5/7/8; `EngineProgress.Phase` raw values match engine phase strings from Task 1; `SongTabModel.Phase` / `title` / `progressMessage` / `errorMessage` names match between Task 7 impl and its tests and Task 9 view; `RootModel.tabs/selectedTabID/closeTab/fileDropped/filePicked` consistent across Tasks 8/9.

**Open decision recorded:** whether `SongTabView`'s Cancel closes the tab or only stops transcription — Task 9 Step 1 notes both wirings; implementer picks one and records it in the PR (default: Cancel → `root.closeTab`).
