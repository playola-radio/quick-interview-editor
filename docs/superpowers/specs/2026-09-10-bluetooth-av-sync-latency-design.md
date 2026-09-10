# Bluetooth A/V-Sync: Playhead Latency Compensation

**Date:** 2026-09-10
**Status:** Design — awaiting approval
**Author:** Brian Keane (with Claude + Codex architecture review)

## Problem

Over Bluetooth headphones the moving playhead runs visibly *ahead* of the
sound the user hears. Bluetooth A2DP adds ~120–300 ms of codec + transmission +
earbud-buffer latency that lives downstream of everything the app controls. We
cannot make the audio arrive sooner.

Today the playhead is driven entirely off the audio engine's **render**
position (`AudioPlayerClient.swift` `emitPosition()`, ~line 630):

```swift
framesPlayed = Int(max(0, playerTime.sampleTime))   // frames the engine has rendered
sample = positionSample(forFramesPlayed: framesPlayed)
broadcast(PlaybackPosition(sessionID:, sample:, isPlaying: true))
```

That render count is ahead of audio-at-the-ear by the full output latency. No
latency compensation exists anywhere in the app.

## Goal

Delay the **visual** playhead so it lines up with what the user actually hears:
subtract an output-latency offset from the render-frame count before mapping to
a plan/edited sample. When the user hears a word, the playhead sits on it.

Edits and explicit clip boundaries stay sample-accurate because they derive from
engine timestamps and selection math, **not** from where the playhead is drawn.
Only the *displayed* position (and the "what I just heard" intent) shifts.

### Non-goals

- Reducing the real acoustic latency (impossible; it's in the BT link/earbuds).
- Frame-exact accuracy across a live playback-speed change (see Decision 1 — we
  accept a brief transient error; deferred refinement documented below).
- Seamless playback recovery across a disruptive output-device route change
  (v1 stops playback cleanly; see Route changes).
- A click/flash calibration preview mode (deferred; see Decision 2).

## Decisions (approved)

- **Decision 1 — rate-change accuracy: simple formula.** Use the steady-rate
  formula and accept a brief cursor hiccup in the ~second right after the user
  changes playback speed. A timestamped frame-position history ring buffer would
  make it exact across speed changes; deferred as future work.
- **Decision 2 — manual-offset UX: slider + live playback.** The user judges the
  offset by ear against real playback. No click/flash preview mode in v1.

## Approach

### 1. Automatic estimate: `outputPresentationLatency`

Read `node.outputPresentationLatency` (AVAudioNode — Apple defines it as the
maximum downstream render-pipeline latency for that node). This is preferred
over hand-summing CoreAudio device properties (`kAudioDevicePropertyLatency` +
safety offset + stream latency + buffer), which risks double-counting.

This is an **estimate**, not sound-at-the-ear: it captures much of the BT delay
(CoreAudio does report Bluetooth latency — confirmed by VLC's CoreAudio-based
BT-sync fix) but is not guaranteed complete for every headset/codec. Built-in /
wired is *smaller, not zero* (the `AVAudioUnitTimePitch` node adds processing
delay). The manual offset below covers the remainder.

Re-read the estimate after: engine start, playback-rate change, and output
route change.

### 2. Manual per-device offset (signed)

A signed per-device correction (the user can nudge **Earlier or Later**), keyed
by the CoreAudio output-device UID. Stored as `[String: Double]` (UID → ms) in
**one** `@Shared(.fileStorage)` JSON file in Application Support, default `[:]`.
Seconds internally, milliseconds in the UI.

Effective delay:

```swift
effectiveSeconds = max(0, automaticSeconds + manualSeconds)   // manual may be negative; total floors at 0
```

A missing UID entry means 0 (never reuse another device's value). Reject
non-finite manual values.

### 3. Offset math (Decision 1 — simple formula)

`playerTime.sampleTime` counts native **input** frames (pre-`timePitch.rate`);
latency is a wall-clock **output** delay. To back the playhead off by
`effectiveSeconds` of wall clock:

```swift
offsetFrames   = effectiveSeconds * nativeSampleRate * timePitch.rate
audibleFrames  = max(0, Double(framesPlayed) - offsetFrames)          // clamp BEFORE mapping
presentationSample = positionSample(forFramesPlayed: Int(audibleFrames))
```

Clamping before `positionSample(...)` preserves both the source-range and
edited-playlist mappings and their existing ceiling clamps, and keeps the first
`effectiveSeconds` of playback from driving the sample below the range start.

Example: 200 ms @ 48 kHz @ 2× → subtract 19,200 input frames.

### 4. Render vs. presentation split (correctness fix)

**The playhead is not purely visual today.** `EditorModel.observePlayback()`
(~line 1398) writes the streamed sample into the **persistent cursor**, and
`pause()` separately snapshots the *uncompensated* render position. If we
compensate only the live stream, pause would jump the cursor forward.

Fix: produce **both** a `renderSample` (raw) and a `presentationSample`
(compensated) through the position pipeline, and choose consumers explicitly:

- **Playhead follow, persisted cursor, pause resting position, and "mark what I
  just heard":** use `presentationSample`.
- **Existing explicit clip boundaries / selection math:** unchanged (raw engine
  timestamps — not sourced from the playhead).

Concretely: `PlaybackPosition` carries both samples; `emitPosition()` and
`pause()`'s resting-sample computation both apply the same offset so live-follow
and paused cursor agree (no jump). `renderSample` is retained for debugging/tests
and any future raw consumer.

### 5. Output-device identity & change detection

New `Sendable` dependency client (graph/latency reads stay **inside**
`LivePlayerBox` — do not pass an `AVAudioEngine` through a client):

```swift
struct OutputDevice: Equatable, Sendable {
  var id: UInt32      // runtime only — never persisted
  var uid: String     // persistent key (kAudioDevicePropertyDeviceUID)
  var name: String    // display (kAudioObjectPropertyName)
}

struct AudioOutputClient: Sendable {
  var current: @Sendable () async throws -> OutputDevice?
  var changes: @Sendable () -> AsyncStream<Void>   // fires on default-output change
}
```

- `liveValue` owns the HAL reads + `AudioObjectAddPropertyListenerBlock` on
  `kAudioHardwarePropertyDefaultOutputDevice` (register before the first
  snapshot; serialize callbacks; remove on teardown).
- `testValue` reports unexpected reads and provides an inert stream; tests
  override with controlled values/events.

Persist by UID only; never the numeric `AudioDeviceID`, never the name.

### 6. Route changes (v1)

Also observe `.AVAudioEngineConfigurationChange` scoped to the engine. A format
change **stops and uninitializes** the engine, so updating the offset alone does
not recover playback. v1 behavior: **stop playback cleanly on a disruptive route
change and require the user to press Play again**, then resolve the new device's
effective delay. Seamless reschedule-and-resume is deferred.

When resolving the running graph's device mid-transition, verify the output
unit's current device rather than pairing a new default-device UID with the old
graph's latency.

### 7. Settings UI

Mirror the existing `ClipBoundarySettingsModel` / `ClipBoundarySettingsView`
trio (slider + `@Shared` + clamping + reset). Show:

- Current output device name (from `AudioOutputClient.current`).
- The auto-detected estimate (read-only, ms) for transparency.
- A signed **Earlier ↔ Later** control (slider or stepper, ms) that writes the
  current device's entry in the shared `[UID: ms]` map via `withLock`.

Model owns all display text and derived values; the view holds no logic
(matches the app's MV rules).

## Data flow

```
outputPresentationLatency (auto, LivePlayerBox)
        +  manual[deviceUID]  (@Shared fileStorage, signed ms)
        =  effectiveSeconds (>= 0)
             │
emitPosition(): framesPlayed - effectiveSeconds·nativeRate·rate  (clamp >=0)
             │
   PlaybackPosition{ renderSample, presentationSample }
             │  (AsyncStream)
EditorModel.observePlayback() -> cursor / highlight / pause resting  [presentationSample]
```

## Testing

Extract the compensation + per-device lookup into **pure functions** and test
with no device/audio:

- Offset math across rates 0.5× / 1× / 2× / 3× and differing native-vs-plan rates.
- Startup lower-clamp (no negative sample) and existing upper ceiling clamp.
- Edited-timeline mapping across seams with compensation applied.
- Per-device lookup: missing UID → 0, negative correction, non-finite rejected,
  device switch picks up the new UID's value.
- `presentationSample` shifts while explicit clip boundaries stay unchanged; no
  forward jump between live-follow and paused cursor.

Use `AudioOutputClient.testValue` overrides + `@Shared(value: [:])` declared
locally per test for the offset map. No `Task.sleep`; use immediate test doubles.

Hardware validation (manual, out of band): compare built-in vs Bluetooth against
a known click/visual event. Unit tests prove the arithmetic, not the accuracy of
the OS-reported latency.

## Deferred / future work

- Frame-position-history ring buffer for exact sync across mid-window speed
  changes (Decision 1).
- Click/flash calibration preview mode (Decision 2).
- Seamless playback recovery across disruptive route changes (currently stop +
  require Play).

## Key files

- `QuickInterviewEditor/QuickInterviewEditor/Core/AudioPlayerClient.swift` —
  `LivePlayerBox`, `emitPosition()` (~630), `positionSample(forFramesPlayed:)`
  (~643), `pause()` resting sample (~521), `PlaybackPosition` (~196),
  `stopNode()` (~654).
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` —
  `observePlayback()` (~1398), `placeCursor(atSource:)` (~344).
- New: `Core/AudioOutputClient.swift`, `State/OutputLatencyOffsetKey.swift`,
  `Views/Pages/Settings/…` latency-offset controls (mirror
  `ClipBoundarySettingsModel`/`View`).
- `State/ProjectStore.swift` (fileStorage pattern) and
  `State/ClipBoundaryOffsetKeys.swift` (Settings-key pattern) as references.
