# Unified Playback Transport — Design

**Date:** 2026-08-12
**Status:** Approved (design); implementation pending
**Author:** Brian + Claude (architecture consulted via Codex)

## Problem

The editor has no unified playback control. Audio is only triggered by scattered
per-object controls, each an independent "playback owner":

- a Play/Stop button on each saved slice (`SlicesPanelView`),
- a fine-tune preview toggle (`FineTuneView`),
- boundary audition buttons + `Space`/`[`/`]` keys (`WaveformView`, `AuditionKeyMonitor`).

There is no persistent, visible playhead cursor, no "play from here" concept, and
no Pause. `WaveformModel.playheadSample` is nil when stopped and only follows the
audio; it is not a cursor you can place.

## Goal

A single, always-visible **Play / Pause / Stop** transport that governs *all*
playback, driving one persistent playhead in the existing waveform.

### Requirements (from the user)

1. A persistent, visible playhead cursor in the existing waveform — visible even when stopped.
2. **Play** starts from wherever the playhead currently is.
3. When a selection is made, the playhead automatically snaps to the **start** of the selection.
4. If a selection is active when playing, playback **ends at the selection's end**. With no selection, playback runs from the playhead to end-of-audio (until Stop/Pause).
5. **Pause** holds the playhead exactly in place; Play resumes from there.
6. **Stop** returns the playhead to exactly where Play was last started (the origin).
7. Unifies all playback. The existing per-object buttons become **convenience shortcuts**: they select the right clip/suggestion, move the playhead into place, and start the one transport. One playhead, one Pause/Stop everywhere.
8. A thin **Logic-style ruler strip** above the waveform; click/drag moves the playhead. The waveform body keeps its current word/region selection behavior.
9. Match Logic Pro conventions. **Space = Play/Stop** (Logic's default; verified against Apple docs). Pause is button-only. Stop returns the playhead to the origin.

## Architecture

### One transport, owned by `EditorModel`

`EditorModel` remains the sole playback driver. Replace the three separate owners
(`playingSliceID`, `isPreviewingDraft`, `audition` and their `previewGeneration` /
`auditionGeneration` tokens) with a single `TransportState`:

```swift
struct PlaybackSessionID: Hashable, Sendable { var rawValue: UUID }

enum TransportPhase: Equatable {
  case stopped
  case playing(PlaybackSessionID)
  case paused(PlaybackSessionID)
}

enum TransportContext: Equatable {
  case free                      // scrubbing the whole interview
  case slice(Slice.ID)           // convenience: a saved slice
  case draftPreview              // convenience: fine-tune preview
  case audition(AuditionMode)    // convenience: boundary audition
}

struct TransportState: Equatable {
  var phase: TransportPhase = .stopped
  var playheadSample = 0         // the persistent, always-visible cursor
  var originSample: Int?         // where Play last started; Stop returns here
  var range: Range<Int>?         // what is currently playing
  var context: TransportContext = .free
}
```

`EditorModel` gains:

```swift
var transport = TransportState()
@ObservationIgnored private var transportGeneration = 0   // stale-guard, retained concept
```

`activeSliceID` (edit-target state) stays — it is not playback state.

### `WaveformModel` becomes pure geometry

Remove playback state from `WaveformModel`. It exposes only coordinate/hit-testing
helpers (`sampleToX`, `xToSample`, `clampedSample`, `playheadX(for:)`). The visible
cursor is always `EditorModel.transport.playheadSample`; `WaveformPlayhead` renders
from that.

### Engine change: real pause/resume + session-tagged positions

The current `AudioPlayerClient` only plays a range and stops. Emulating pause as
"stop + remember the last 30 Hz tick" is inexact (up to ~33 ms of drift, and the
final `isPlaying:false` tick races the cursor). Instead, extend the client to wrap
`AVAudioPlayerNode.pause()`/`.play()` and tag every position with the session that
produced it:

```swift
struct PlaybackPosition { var sessionID: PlaybackSessionID; var sample: Int; var isPlaying: Bool }

struct AudioPlayerClient: Sendable {
  var play:      @Sendable (URL, Range<Int>, Int, PlaybackSessionID) async throws -> Void
  var pause:     @Sendable (PlaybackSessionID) async -> Int?    // returns exact resting sample
  var resume:    @Sendable (PlaybackSessionID) async -> Void
  var stop:      @Sendable (PlaybackSessionID?) async -> Void
  var positions: @Sendable () -> AsyncStream<PlaybackPosition>
}
```

`pause` reads the node's `playerTime` synchronously on the audio actor and returns
the exact plan sample, so the frozen cursor is accurate.

### State machine

- **stopped** — cursor is editable (ruler, selection-snap, click). Play starts at `playheadSample`.
- **playing(session)** — audio is source of truth, but ticks apply *only* when `position.sessionID == session`.
- **paused(session)** — cursor frozen at the sample returned by `pause(session)`. Play calls `resume(session)`.

Transitions:

- **Play (from stopped):** `originSample = playheadSample`; `range = playheadSample ..< end` where `end = transcript.selectedSampleRange?.upperBound ?? editPlan.source.durationSamples`; guard `start < end`; new `PlaybackSessionID`; `phase = .playing`; `await audioPlayer.play(url, range, sampleRate, session)`.
- **Play (from paused):** `resume(session)`; `phase = .playing`.
- **Pause:** `sample = await audioPlayer.pause(session)`; `playheadSample = sample`; `phase = .paused`.
- **Stop:** `await audioPlayer.stop(session)`; `playheadSample = originSample ?? playheadSample`; `phase = .stopped`.
- **Natural completion:** the `play` call returns; leave the cursor at the range end; `phase = .stopped`. Do **not** reset to origin.

### Requirement → data-flow mapping

1. Persistent cursor: `WaveformPlayhead` reads `model.transport.playheadSample`.
2. Play from cursor: `transportPlayPauseTapped()` / `transportPlayTapped()` builds the range from the cursor.
3. Selection snap: `transcriptSelectionChanged(old:new:)` sets `playheadSample = new.lowerBound`. Wired via `.onChange(of: transcript.selectedSampleRange)` in `EditorView` (transcript selection lives in `TranscriptPageModel`, not `EditorModel`).
4. Selection bounds end: active selection supplies the range upper bound; else end-of-audio.
5. Pause freezes: real `pause()` returns the exact sample; `playheadSample` set to it.
6. Stop returns to origin: `playheadSample = originSample`.
7. Convenience shortcuts: slice/preview/audition actions set `context`, set the selection/range and cursor, then call the unified transport play. No independent owners.
8. Ruler: `WaveformRulerView` (own `NSViewRepresentable` interaction layer) above the body; click/drag → `model.rulerMovedPlayhead(toX:)` → `transport.playheadSample`.
9. Keyboard: `Space` = Play/Stop toggle; `[`/`]` route through transport/audition. A single key monitor replaces the split between `EditorKeyMonitor` and `AuditionKeyMonitor`.

## Decisions (A–F rulings)

- **A. Extend `AudioPlayerClient` with real pause/resume + session-tagged positions.** Emulated pause is visibly and sometimes logically wrong.
- **B. Transport state lives in `EditorModel`; `WaveformModel` is geometry only.** The three owners collapse into `TransportContext`.
- **C. `transport.playheadSample` is the single source of truth.** Ticks update it only in `.playing(session)` and only when the tick's `sessionID` matches. Final/false ticks never write the resting cursor.
- **D. Ruler movement does not clear the selection.** Selection change snaps the cursor to the selection start. If a selection changes mid-playback, stop and move the cursor (no silent seek in v1). If a selection is active and the cursor is at/after the selection end, Play is a no-op.
- **E. Ruler is a SwiftUI strip with its own interaction layer, sibling to the body.** Reuse `xToSample`/`sampleToX`. No drag-to-scrub while playing in v1 (drag during playback = stop + move).
- **F. Remove per-slice Stop.** The slice button becomes a Play shortcut; the global transport owns Pause/Stop. Row "playing" highlight stays; local Stop controls do not.

## Riskiest bugs (and how the design prevents them)

- **Stale/final position tick clobbers the resting cursor** → session IDs + phase gating; `EditorModel` (not the stream) decides the resting cursor.
- **Pause sample drift** → `pause()` reads `playerTime` synchronously on the audio actor and returns the exact plan sample.
- **Stop tick resetting to old start** → stop ticks never write the cursor; Stop sets `playheadSample = originSample`.
- **Selection changes bypassing `EditorModel`** → `.onChange(of:)` reconciliation hook in `EditorView`.
- **Space key conflict** → merge the two key monitors so Space routes through the transport.

## PR decomposition (dependency order)

Each PR is independently shippable, small enough to review, and gets a fresh
context with a self-contained brief (per the multi-PR workflow).

1. **Engine API:** add session-tagged `play`, real `pause`/`resume`, session on `PlaybackPosition`; adapt live/test/preview values. No behavior change for existing callers.
2. **Transport state:** introduce `TransportState` in `EditorModel`; migrate `observePlayback()` to session-gated cursor updates. Existing per-object entry points now go through it internally.
3. **Persistent cursor:** render `WaveformPlayhead` from `transport.playheadSample`; `WaveformModel` reduced to geometry.
4. **Selection-snap:** `transcriptSelectionChanged` + `.onChange` wiring + tests.
5. **Transport panel:** Play/Pause/Stop buttons + labels (view binds to model-computed labels/enabled flags).
6. **Slice shortcuts:** convert slice Play buttons to transport shortcuts; remove per-slice Stop.
7. **Preview + audition shortcuts:** route fine-tune preview and boundary audition through the transport.
8. **Ruler strip:** `WaveformRulerView` + click/drag cursor movement.
9. **Unified keyboard:** single key monitor; `Space` = Play/Stop; `[`/`]` through transport.

## Testing

- All behavior tested on `EditorModel` (Swift Testing, `expectNoDifference`), with
  `AudioPlayerClient` overridden via `withDependencies`. `@Shared(.editPlan)`
  declared locally per test.
- Transport state-machine tests: play-from-cursor, pause freezes sample,
  resume continues, stop returns to origin, natural completion leaves cursor at end.
- Session-gating tests: a stale tick from a superseded session must not move the cursor.
- Selection-snap tests: selection change moves the cursor to the selection start.
- Convenience-shortcut tests: slice/preview/audition set context + cursor + range
  and start the transport.
- No `Task.sleep`; use test doubles that resolve immediately and controlled clocks.

## Out of scope (v1)

- Drag-to-scrub audio while playing (Logic "catch").
- Logic's double-Stop (first Stop → last start, second Stop → project start). v1 Stop
  always returns to the single origin.
- Loop/cycle playback.
