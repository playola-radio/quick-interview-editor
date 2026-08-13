# Transport PR 1 — Engine pause/resume + session-tagged positions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `AudioPlayerClient` with real `pause`/`resume` and a per-playback `PlaybackSessionID` that tags every position, without changing any user-visible behavior.

**Architecture:** `AudioPlayerClient` gains a `PlaybackSessionID` on `play`, a `sessionID` on `PlaybackPosition`, and new `pause`/`resume` closures wrapping `AVAudioPlayerNode.pause()`/`.play()`. The live actor tracks the current session so `pause`/`resume`/`stop` are no-ops for a stale session. Existing `EditorModel` call sites thread a throwaway session per play and ignore the new `sessionID`, so behavior is byte-for-byte identical. This is the engine substrate; PR 2 introduces the `EditorModel` transport that actually uses sessions.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation, Point-Free swift-dependencies, Swift Testing, XcodeGen. macOS app in `QuickInterviewEditor/`.

**Spec:** `docs/superpowers/specs/2026-08-12-playback-transport-design.md` (see "Engine change" and PR decomposition item 1).

## Global Constraints

- MV architecture with `@Observable` models; **zero logic in views**; all playback logic in `EditorModel`. (This PR touches only `Core/` + `EditorModel` call sites + tests — no view changes.)
- Everything measured in **plan samples** (integers). The native-frame↔plan-sample conversion stays internal to the live actor.
- Every side-effecting boundary is a `Sendable` swift-dependencies client with `liveValue`, `testValue`, `previewValue`.
- Swift 6 strict concurrency. `AVAudioEngine`/`AVAudioPlayerNode` are confined to the `LivePlayerBox` actor; completion callbacks are `@Sendable` and hop back onto the actor.
- Tests: Swift Testing (`import Testing`, `@Test`), `expectNoDifference`/`expectDifference` from swift-custom-dump for value comparisons, **no `Task.sleep`**, `@Shared(.editPlan)` declared locally per test.
- CI runs on Xcode 16.4 (older than local). Keep AppKit/AVFoundation concurrency annotations explicit; do not rely on newer-toolchain inference.
- Build/test the macOS app per `plans/roadmap-macos-app.md` / the project memory (XcodeGen → `xcodebuild` on the `QuickInterviewEditor` scheme). Confirm the exact command from the repo before running.
- Commit messages: no `Co-Authored-By` / co-sign trailers.

## Interface being introduced (authoritative signatures)

```swift
struct PlaybackSessionID: Hashable, Sendable {
  var rawValue: UUID
  init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

struct PlaybackPosition: Sendable, Equatable {
  var sessionID: PlaybackSessionID
  var sample: Int
  var isPlaying: Bool
}

struct AudioPlayerClient: Sendable {
  var play:      @Sendable (URL, Range<Int>, Int, PlaybackSessionID) async throws -> Void
  var pause:     @Sendable (PlaybackSessionID) async -> Int?   // exact resting plan sample, or nil if session is stale
  var resume:    @Sendable (PlaybackSessionID) async -> Void
  var stop:      @Sendable (PlaybackSessionID?) async -> Void  // nil = stop whatever is playing
  var positions: @Sendable () -> AsyncStream<PlaybackPosition>
}
```

Semantics:
- `play(url, range, rate, session)` — as today, but records `session` as the current session and tags all its position ticks with it.
- `pause(session)` — if `session` is the current playing session: read the node's exact play position, convert to a plan sample, pause the node (no `isPlaying:false` broadcast — the playhead stays put), return the sample. Otherwise return `nil`. Does **not** complete the suspended `play` call.
- `resume(session)` — if `session` is the current (paused) session: restart the node and the tick loop. Otherwise no-op.
- `stop(session)` — if `session` is `nil` or equals the current session: supersede (as today: bump generation, resume the `play` waiter, stop node, broadcast the final `isPlaying:false` tick). Otherwise no-op.

---

## Task 1: Extend the client type, `PlaybackPosition`, and test/preview values

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Core/AudioPlayerClient.swift`

**Interfaces:**
- Consumes: nothing (leaf type).
- Produces: `PlaybackSessionID`, the new `PlaybackPosition` (with `sessionID`), and the 5-closure `AudioPlayerClient` shape above. Later tasks and PR 2 depend on these exact names/types.

- [ ] **Step 1: Add `PlaybackSessionID` and extend `PlaybackPosition`.**

At the top of the file (near the existing `PlaybackPosition`), add:

```swift
/// Identifies one continuous playback so a stale/superseded tick can never be mistaken
/// for the current one. A fresh id is minted per `play`.
struct PlaybackSessionID: Hashable, Sendable {
  var rawValue: UUID
  init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
```

Change `PlaybackPosition` to:

```swift
struct PlaybackPosition: Sendable, Equatable {
  var sessionID: PlaybackSessionID
  var sample: Int
  var isPlaying: Bool
}
```

- [ ] **Step 2: Change the `AudioPlayerClient` struct closures.**

Replace the `play`/`stop` declarations and add `pause`/`resume` so the struct reads:

```swift
struct AudioPlayerClient: Sendable {
  /// Plays url from range.lowerBound to range.upperBound (samples) and returns when playback
  /// finishes or `stop`/a superseding `play` is called. `session` tags this playback's ticks.
  var play: @Sendable (URL, Range<Int>, Int, PlaybackSessionID) async throws -> Void
  /// Pauses `session` if it is current, freezing the node; returns the exact resting plan
  /// sample (nil if `session` is not the current playback). Does not end the `play` call.
  var pause: @Sendable (PlaybackSessionID) async -> Int?
  /// Resumes `session` if it is the current paused playback; otherwise no-op.
  var resume: @Sendable (PlaybackSessionID) async -> Void
  /// Stops the current playback if `session` is nil or matches it; otherwise no-op.
  var stop: @Sendable (PlaybackSessionID?) async -> Void
  var positions: @Sendable () -> AsyncStream<PlaybackPosition>
}
```

- [ ] **Step 3: Update `testValue` and `previewValue` to the new arity.**

```swift
extension AudioPlayerClient: TestDependencyKey {
  static let testValue = AudioPlayerClient(
    play: { _, _, _, _ in
      reportIssue("AudioPlayerClient.play called without a test override")
      throw EngineClientError.unimplemented("AudioPlayerClient.play")
    },
    pause: { _ in
      reportIssue("AudioPlayerClient.pause called without a test override")
      return nil
    },
    resume: { _ in reportIssue("AudioPlayerClient.resume called without a test override") },
    stop: { _ in reportIssue("AudioPlayerClient.stop called without a test override") },
    positions: { AsyncStream { $0.finish() } }
  )

  static let previewValue = AudioPlayerClient(
    play: { _, _, _, _ in }, pause: { _ in nil }, resume: { _ in },
    stop: { _ in }, positions: { AsyncStream { $0.finish() } })
}
```

- [ ] **Step 4: Build the Core file (it will still fail to link against callers — expected).**

Run the project build (confirm the exact `xcodebuild` invocation from the repo first).
Expected: `AudioPlayerClient.swift` itself has no syntax errors; the `live()` factory in Task 2 and callers in Task 3 are still on the old shape, so the overall build fails there. That is fine — do not fix callers yet.

- [ ] **Step 5: Commit.**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Core/AudioPlayerClient.swift
git commit -m "feat(audio): add PlaybackSessionID + pause/resume to AudioPlayerClient type"
```

---

## Task 2: Implement live actor session tracking + real pause/resume

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Core/AudioPlayerClient.swift` (the `live()` factory and `LivePlayerBox` actor).

**Interfaces:**
- Consumes: the Task 1 type shape.
- Produces: a working `liveValue` whose `play`/`stop` behave exactly as before when driven with a fresh session and `stop(nil)`, plus functioning `pause`/`resume`.

- [ ] **Step 1: Add current-session state to `LivePlayerBox`.**

Add stored state alongside `startPlanSample`/`playRatio`:

```swift
private var currentSession: PlaybackSessionID?
```

- [ ] **Step 2: Thread the session into `play` and tag positions.**

Change `play`'s signature and record the session:

```swift
func play(url: URL, range: Range<Int>, planSampleRate: Int, session: PlaybackSessionID) async throws {
  // ... existing file/frame/ratio/guard code unchanged ...
  supersede(broadcastStop: false)
  currentSession = session
  startPlanSample = max(0, range.lowerBound)
  playRatio = ratio
  // ... rest unchanged ...
}
```

Tag both broadcast sites with the current session. In `emitPosition`:

```swift
private func emitPosition() {
  guard let session = currentSession,
    node.isPlaying, let nodeTime = node.lastRenderTime,
    let playerTime = node.playerTime(forNodeTime: nodeTime)
  else { return }
  let framesPlayed = max(0, playerTime.sampleTime)
  let planSample = startPlanSample + Int(Double(framesPlayed) / max(playRatio, .ulpOfOne))
  broadcast(PlaybackPosition(sessionID: session, sample: planSample, isPlaying: true))
}
```

In `stopTicking(broadcastStop:)`, tag the final tick and clear the session:

```swift
private func stopTicking(broadcastStop: Bool = true) {
  tickTask?.cancel()
  tickTask = nil
  if broadcastStop, let session = currentSession {
    broadcast(PlaybackPosition(sessionID: session, sample: startPlanSample, isPlaying: false))
  }
}
```

Note: `supersede()` calls `stopTicking()` then `stopNode()`; clear `currentSession = nil` at the end of `supersede` (after the final tick is broadcast) so a subsequent stale `pause`/`resume`/`stop` is a no-op:

```swift
private func supersede(broadcastStop: Bool = true) {
  generation += 1
  let waiter = continuation
  continuation = nil
  stopTicking(broadcastStop: broadcastStop)
  stopNode()
  currentSession = nil
  waiter?.resume()
}
```

(Do the same `currentSession = nil` at the end of `complete(generation:)`, after `stopTicking()`.)

- [ ] **Step 3: Implement `pause` and `resume` on the actor.**

```swift
/// Freezes the node in place and returns the exact plan sample it stopped at.
/// No `isPlaying:false` broadcast — the playhead must stay where paused.
func pause(session: PlaybackSessionID) -> Int? {
  guard currentSession == session, node.isPlaying,
    let nodeTime = node.lastRenderTime,
    let playerTime = node.playerTime(forNodeTime: nodeTime)
  else { return nil }
  let framesPlayed = max(0, playerTime.sampleTime)
  let planSample = startPlanSample + Int(Double(framesPlayed) / max(playRatio, .ulpOfOne))
  stopTicking(broadcastStop: false)   // stop polling; keep session + node position
  node.pause()                        // pauses without discarding the scheduled segment
  return planSample
}

/// Resumes a paused session: restart the node and the tick loop.
func resume(session: PlaybackSessionID) {
  guard currentSession == session, !node.isPlaying else { return }
  node.play()
  startTicking()
}
```

- [ ] **Step 4: Change `stop` to be session-scoped.**

```swift
func stop(session: PlaybackSessionID?) {
  guard let session else { supersede(); return }  // nil = stop whatever plays
  guard currentSession == session else { return }
  supersede()
}
```

- [ ] **Step 5: Update the `live()` factory closures to the new shapes.**

```swift
return AudioPlayerClient(
  play: { url, range, sampleRate, session in
    try await box.play(url: url, range: range, planSampleRate: sampleRate, session: session)
  },
  pause: { session in await box.pause(session: session) },
  resume: { session in await box.resume(session: session) },
  stop: { session in await box.stop(session: session) },
  positions: {
    // unchanged registration/termination plumbing
  }
)
```

- [ ] **Step 6: Build the Core file.**

Run the build. Expected: `AudioPlayerClient.swift` compiles. Callers in `EditorModel` and tests still fail (old arity) — fixed in Tasks 3–4.

- [ ] **Step 7: Commit.**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Core/AudioPlayerClient.swift
git commit -m "feat(audio): implement live pause/resume + session-tagged positions"
```

---

## Task 3: Thread a session through EditorModel's existing call sites (no behavior change)

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift`

**Interfaces:**
- Consumes: Task 1/2 `AudioPlayerClient` shape.
- Produces: an `EditorModel` that compiles against the new client with identical behavior. PR 2 will replace this throwaway-session threading with real transport state.

The call sites (verify line numbers before editing — they drift):
- `positions()` consumer at ~line 300 (reads `position.sample`/`position.isPlaying` — leave as-is; the new `sessionID` is ignored here in PR 1).
- `audioPlayer.play(...)` at ~lines 552, 752, 822.
- `audioPlayer.stop()` at ~lines 508, 534, 544, 566, 654, 671, 762, 853.

- [ ] **Step 1: Update every `play` call to pass a fresh session.**

At each of the three `play` call sites, mint a throwaway session inline and pass it as the 4th argument. Example for the slice-play site (~552):

```swift
try await audioPlayer.play(
  canonicalAudioURL, slice.startSample..<slice.endSample,
  editPlan.source.sampleRate, PlaybackSessionID())
```

And the two `canonicalAudioURL, range, editPlan.source.sampleRate` sites (~752, ~822):

```swift
try await audioPlayer.play(canonicalAudioURL, range, editPlan.source.sampleRate, PlaybackSessionID())
```

- [ ] **Step 2: Update every `stop()` call to `stop(nil)`.**

Replace each `await audioPlayer.stop()` with `await audioPlayer.stop(nil)` (8 sites). `nil` preserves today's "stop whatever is playing" behavior exactly.

- [ ] **Step 3: Build the app target.**

Run the build. Expected: the app target (`EditorModel` + `Core`) compiles. Test target may still fail (old test doubles) — fixed in Task 4.

- [ ] **Step 4: Commit.**

```bash
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift
git commit -m "refactor(editor): thread throwaway PlaybackSessionID through existing playback calls"
```

---

## Task 4: Migrate the test doubles to the new signatures; full suite green

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorAuditionTests.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorFineTuneTests.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorTests.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/RootPage/RootTests.swift`

**Interfaces:**
- Consumes: Task 1 client shape.
- Produces: a compiling, green test suite proving PR 1 changed no behavior.

This is the regression net for PR 1: the live actor is hardware-backed and not unit-tested (per the file's own note, "Not unit tested (real audio hardware); covered by manual verification"), so the existing model-level suite passing against the new client shape is what proves behavior is unchanged.

- [ ] **Step 1: Update `play` overrides from 3 to 4 ignored args.**

Every `$0.audioPlayer.play = { _, _, _ in ... }` becomes `{ _, _, _, _ in ... }`. Where a test binds the range (e.g. `{ _, range, _ in recorded.setValue(range) }`), add the trailing ignored session: `{ _, range, _, _ in recorded.setValue(range) }`.

- [ ] **Step 2: Update the `recordingPlay` helper in `EditorAuditionTests.swift` (~line 77).**

Add the 4th parameter (session) and ignore it; the recorded 3-tuple `(URL, Range<Int>, Int)` stays the same so downstream asserts are untouched. Read the current helper and add `_ session: PlaybackSessionID` to its closure signature.

- [ ] **Step 3: Update `stop` overrides to take the optional session.**

Every `$0.audioPlayer.stop = { ... }` becomes `$0.audioPlayer.stop = { _ in ... }`.

- [ ] **Step 4: Add `pause`/`resume` overrides only where a test needs them.**

PR 1 doesn't call `pause`/`resume` from the model, so no test needs them yet. If any suite constructs a full `AudioPlayerClient(...)` literal (grep confirms none currently do — all use `$0.audioPlayer.x =` partial overrides), it would need the new closures; otherwise leave `testValue`'s defaults.

- [ ] **Step 5: Update `PlaybackPosition(...)` constructions in tests.**

Grep the test targets for `PlaybackPosition(`. Every construction now needs a `sessionID:`. Where the test streams positions into `observePlayback` (e.g. `EditorAuditionTests` ~line 275 `positions = { stream }`), give each `PlaybackPosition` a `sessionID: PlaybackSessionID()` (the model ignores it in PR 1):

```swift
PlaybackPosition(sessionID: PlaybackSessionID(), sample: 1000, isPlaying: true)
```

- [ ] **Step 6: Run the full test suite.**

Run the `QuickInterviewEditor` test suite (confirm the exact command). Expected: **all tests pass**, unchanged from before PR 1. If any test now fails on behavior (not compilation), STOP — that means the "no behavior change" invariant was violated; investigate before proceeding.

- [ ] **Step 7: Run `make lint` / `make format` (or the repo's configured SwiftLint + swift-format).**

Expected: no new warnings.

- [ ] **Step 8: Commit.**

```bash
git add QuickInterviewEditor/QuickInterviewEditorTests
git commit -m "test(audio): migrate playback test doubles to session-tagged AudioPlayerClient"
```

---

## Task 5: Manual audio verification + PR

**Files:** none (verification + PR).

- [ ] **Step 1: Run the app and verify unchanged play/stop.**

Launch the app (per the `run` workflow / repo instructions), import or open a fixture project, and confirm:
- A saved slice's Play still plays and its Stop still stops.
- Fine-tune preview still plays the draft range.
- Boundary audition (`[`/`]`/Space and the ▶ In / Out ▶ buttons) still works.
- The waveform playhead still follows audio and clears on stop.

Expected: identical to `main` — PR 1 is invisible to the user.

- [ ] **Step 2: Sanity-check pause/resume at the client level (temporary harness, not committed).**

Because no UI calls `pause`/`resume` yet, verify them with a throwaway harness or an lldb/manual check: start a `play(url, range, rate, session)`, call `pause(session)` mid-playback, confirm audio stops and the returned sample is within the range and near where you paused; call `resume(session)`, confirm audio continues from that point; `stop(session)` ends it. Remove the harness before committing (do not leave scratch code in the tree).

- [ ] **Step 3: Open the PR.**

Push the branch and open a PR against `main`. Title: `feat(audio): session-tagged AudioPlayerClient with real pause/resume (transport PR 1)`. Body: link the design doc, note "no user-visible change; substrate for the playback transport," and list the manual verification performed.

- [ ] **Step 4: Run the PR review workflow.**

Follow the repo's PR workflow (`/fix-review`, and the Codex adversarial review per the machine's pipeline since this touches real audio/concurrency logic).

---

## Self-Review (completed by plan author)

- **Spec coverage:** This plan implements PR-decomposition item 1 only ("Add session-tagged `AudioPlayerClient` API with real pause/resume; keep old behavior adapted internally"). The transport state (item 2+), cursor rendering, selection-snap, panel, shortcuts, ruler, and keyboard are explicitly **out of scope** here and land in later PRs. ✓
- **Placeholder scan:** No TBD/TODO; every code step has concrete code. The two "read the current file first" notes (recordingPlay helper, exact line numbers) are precision guards, not missing content — the change to make is fully specified. ✓
- **Type consistency:** `PlaybackSessionID`, `PlaybackPosition.sessionID`, and the 5-closure `AudioPlayerClient` (`play` 4-arg, `pause -> Int?`, `resume`, `stop(_:)`, `positions`) are used identically in Tasks 1–5. ✓
- **TDD note:** The live actor is hardware-backed and not unit-testable (project-documented); PR 1's automated safety net is the existing model-level suite passing against the migrated client shape (Task 4), plus manual audio verification (Task 5). This is a deliberate, documented deviation from strict red-green, consistent with the repo's existing convention for this file.
