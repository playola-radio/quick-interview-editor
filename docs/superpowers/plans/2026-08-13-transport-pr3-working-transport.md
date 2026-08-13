# Transport PR 3 — the working playback transport — Plan

**Spec:** `docs/superpowers/specs/2026-08-12-playback-transport-design.md`
**Branch:** `briankeane/transport-pr3-working-transport` (off `main`; PRs 1 & 2 merged)
**Architect:** Codex consult (session `019ff7ca…`), ruling: **Option B — lean transport now**, defer the full `TransportState`/`TransportContext` collapse to PR 4.

## Goal (the first *visible* PR)

1. Persistent, visible playhead cursor in the waveform — **visible even when stopped**.
2. Always-visible **Play / Pause / Stop** panel.
3. Play starts from the cursor; selection active → ends at selection end; else → end-of-audio.
4. Pause freezes the cursor (`audioPlayer.pause(session)` returns the sample); Play resumes.
5. Stop returns the cursor to `originSample`. Natural end leaves it where audio stopped.
6. Selection snaps the cursor to the selection start (`onChange` in `EditorView`).
7. Space = Play/Stop (Logic parity).

**Deferred:** slice/preview/audition → transport shortcuts + remove per-slice Stop = PR 4. Ruler = PR 5.

## New state in `EditorModel`

```swift
enum TransportPhase: Equatable {
  case stopped
  case playing(PlaybackSessionID)
  case paused(PlaybackSessionID)
  var session: PlaybackSessionID? { … }
}

var transportPhase: TransportPhase = .stopped
var playheadSample = 0                 // THE persistent cursor (was WaveformModel.playheadSample: Int?)
var transportOriginSample: Int?
@ObservationIgnored private var transportRange: Range<Int>?
```

- Keep `currentPlaybackSession` as the single session-ownership slot for ALL owners.
- `currentPlaybackSession` = session ownership; `transportPhase` = interview-transport UI phase. Keep that boundary until PR 4.
- `playheadSample` lives in `EditorModel`. `WaveformModel` becomes geometry-only (drop its `playheadSample`); `WaveformView` renders the cursor X from `model.playheadSample` (always shown).

## observePlayback (no more cursor clearing)

```swift
guard hasPlaybackOwner else { continue }          // owner flags OR transportPhase active
guard position.sessionID == currentPlaybackSession else { continue }
if position.isPlaying {
  playheadSample = position.sample
  transcript.playheadChanged(sample: position.sample, isPlaying: playingSliceID != nil)
} else {
  if playingSliceID != nil { endTranscriptFollow() }
}
```

The old "not owning → clear playhead" and "false tick → playhead = nil" behavior is removed: the cursor persists.

## Phase machine

- **Play (from stopped):** build `range = playheadSample ..< (selectionEnd ?? durationSamples)`, clamp/guard non-empty; `beginExclusivePlayback()`; mint session; `currentPlaybackSession = session`; `transportOriginSample = playheadSample`; `transportRange = range`; `transportPhase = .playing(session)`; `await audioPlayer.play(url, range, rate, session)`. That await stays suspended across pause/resume until stop/supersede/finish.
- **Pause:** `guard case .playing(session)`; `sample = await audioPlayer.pause(session)`; re-guard `currentPlaybackSession == session`; `playheadSample = sample`; `transportPhase = .paused(session)`.
- **Resume:** `guard case .paused(session)`; `await audioPlayer.resume(session)`; re-guard; `transportPhase = .playing(session)`.
- **Stop:** capture session+origin; set `playheadSample = origin` immediately; `transportPhase = .stopped`; clear `currentPlaybackSession`/`transportRange`/`transportOriginSample`; `await stopOwnedPlayback(session)`.
- **Natural end:** when the suspended `play()` returns and `currentPlaybackSession == session`, set `playheadSample = range.upperBound`, then clear phase/session/range/origin. (Stop paths already nil the session, so natural-end cleanup won't run after Stop.)

## Selection snap

`EditorView.onChange(of: model.transcript.selectedSampleRange)` → async model method. If any owned playback is active, **stop it first**, then snap `playheadSample = newRange.lowerBound`. Never move the cursor mid-play while audio continues.

## Coexistence

`beginExclusivePlayback()` also clears the transport owner (`transportPhase = .stopped`, `transportOriginSample = nil`, `transportRange = nil`) but **must NOT reset `playheadSample`**. Slice/preview/audition Play supersedes the transport (and vice versa) through the existing session mechanism.

## Riskiest bugs (guard against)

- False stop tick overwriting Stop-to-origin → ignore false ticks for cursor writes.
- Suspended transport `play()` completing after Stop and running natural-end cleanup → guard `currentPlaybackSession == session`.
- Pause returning after supersession → re-guard session after the await.
- `beginExclusivePlayback()` clearing the cursor → it must not.
- Selection change mid-play yanking the cursor while audio continues → stop first, then snap.

## Stages (each = compile-clean commit, tests, then next)

1. **Persistent cursor.** Add `TransportPhase` + `playheadSample`/`transportOriginSample`/`transportRange` to `EditorModel`; move the cursor off `WaveformModel`; `WaveformView` renders from `model.playheadSample` (always visible); rework `observePlayback` to update-not-clear. Adapt tests. (No panel yet; cursor sits at 0, still follows audio during existing playback.)
2. **Transport + panel.** `transportPlayTapped`/`Pause`/`Stop` (+ playPauseTapped for Space), the phase machine, origin/range, play-from-cursor, pause-freeze, stop-to-origin, natural-end. `TransportPanelView` (model-computed labels/enabled). Tests for the state machine.
3. **Selection-snap + Space key.** `onChange` wiring + `transportSelectionChanged`; `Space` = Play/Stop through the key monitor. Tests.

Then: Codex review + challenge, `make format-check`/`lint`/`test` green, PR (base `main`), `/fix-review`.
