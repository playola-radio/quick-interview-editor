# Audition edits — design

**Date:** 2026-08-11
**Status:** Approved design, ready for implementation plan
**Feature:** Hear whether a cut lands cleanly, with keyboard shortcuts, driven from
whatever region is currently drawn on the waveform.

---

## Problem

The editor cuts a long interview into chunks. Each chunk has an **in-point**
(`startSample`) and an **out-point** (`endSample`). Before committing, a pro Logic
editor wants to *hear* that a cut is clean:

- **Out-cut:** does the audio stop cleanly at the out-point? → play a short pre-roll
  and stop dead on the boundary.
- **In-cut:** does the audio start cleanly at the in-point? → drop in at the boundary
  and keep playing forward.

Today the app has playback primitives (slice play, fine-tune preview) but no way to
audition a boundary, and almost no keyboard layer.

---

## Scope

**In scope**

- Two boundary auditions + a stop/replay gesture, triggered by keyboard and by
  on-waveform buttons.
- Always-visible discoverability: the shortcut keys are shown on the buttons whenever
  a region is displayed; a "Space to stop" hint appears while auditioning.
- Works on whatever region is drawn on the waveform (committed slice, fine-tune draft,
  or pending transcript selection).

**Out of scope (deferred)**

- A separate "through-cut" audition (pre-roll *through* the boundary and past it).
- Silence-zone ("safe cut") warnings on the audition affordances — the data exists
  (`editPlan.silences`) but is not surfaced here.
- Transcript auto-follow during an audition (waveform playhead moves; transcript
  follow stays slice-only, matching today's behavior).
- A unified `PlaybackOwner` enum rewrite of *existing* slice/preview playback (see
  "Playback ownership" — we coordinate the three owners through one path instead).

---

## Source of truth: which region gets auditioned

The region **drawn on the waveform** is `EditorModel.activeEditingRange`
(`EditorModel.swift:117`):

```
activeEditingRange = fineTune.draftRange ?? activeOrSelectedRange
activeOrSelectedRange = transcript.selectedSampleRange ?? activeSliceRange
```

This is the property that feeds `waveformHighlightSpan` (`EditorModel.swift:183`), so
it already tracks a fine-tune drag live, a selected slice, or a pending selection.

**Do not use `highlightedSampleRange`** (`EditorModel.swift:172`) — that is transcript
selection only, and auditioning off it would silently no-op for active slices and
fine-tune drafts.

Name for the audition's read of this value: **the audition region**. When
`activeEditingRange == nil`, or the range is empty/invalid (`lowerBound >= upperBound`),
there is no audition region: the buttons are disabled and the key actions no-op.

---

## Behavior

Let `region = activeEditingRange`, `rate = editPlan.source.sampleRate`,
`total = editPlan.source.durationSamples`, and
`preRoll = Int(auditionPreRollSeconds * Double(rate))` with
`auditionPreRollSeconds = 2.0`.

### Out-cut audition — key `]`

Play `[max(0, region.upperBound - preRoll), region.upperBound)`, then **stop exactly at
the out-point**. The pre-roll is deliberately allowed to start *before* the region's own
start (clamped only at 0) — for a short clip you still want a couple seconds of run-up to
judge the outgoing cut.

### In-cut audition — key `[`

Play `[region.lowerBound, total)` — drop in at the in-point and play forward until the
user stops or the file ends. (Described as "play until stop or end-of-file," not truly
infinite.)

### Space — stop / replay

- If **any** editor-owned playback is active (slice, preview, or audition) → **stop**.
- Else replay the **last audition** the user triggered this session (`.cutIn`/`.cutOut`).
- Else (no audition yet) → in-cut audition.

This matches a Logic user's "space replays what I was just listening to" reflex and
avoids the surprise of space always meaning in-cut right after an out-cut audition.

### Re-pressing `[` or `]`

Always (re)starts that audition from the top (supersedes whatever was playing). `[`/`]`
never toggle-stop; **space** is the stop. Simple and predictable.

---

## Playback ownership (race safety)

Playback is a single global player (`AudioPlayerClient`), so only one thing plays at a
time. Today two owners coordinate it, each guarding stale async completions:

- `playingSliceID: Slice.ID?` (slice panel play) — id-check guard.
- `isPreviewingDraft` + `previewGeneration` (fine-tune preview) — generation guard.
- `observePlayback()` only moves the playhead when `playingSliceID != nil || isPreviewingDraft`.

We add a **third owner** for auditions, following the *exact* established
generation-token idiom, plus **one coordination point** so the three never fight over
the player (this is Codex's "single reconciliation path," achieved without rewriting the
existing two owners):

```swift
enum AuditionMode: Equatable { case cutIn, cutOut }

var audition: AuditionMode?                 // observable; nil when no audition is playing
private var lastAudition: AuditionMode?      // sticky within the session, for Space-replay
@ObservationIgnored private var auditionGeneration = 0
```

**One helper takes exclusive ownership** (called at the start of every play path —
slice, preview, and both auditions):

```swift
private func beginExclusivePlayback() {
  playingSliceID = nil
  endTranscriptFollow()
  previewGeneration &+= 1
  isPreviewingDraft = false
  auditionGeneration &+= 1
  audition = nil
}
```

Each start then sets *its own* owner and reads *its own* fresh generation/id after
calling the helper. `playSliceTapped` and `previewEditTapped` gain one call to this
helper at their top (replacing their ad-hoc `playingSliceID = nil` / generation bumps),
so starting a slice or preview cancels an audition and vice-versa. Behavior of the
existing two paths is preserved; their tests are updated only where the internal reset
moved into the helper.

**Audition start** (shared by in and out):

```swift
private func startAudition(_ mode: AuditionMode, range: Range<Int>) async {
  guard !range.isEmpty else { return }
  beginExclusivePlayback()            // bumps auditionGeneration → cancels any in-flight audition
  let generation = auditionGeneration // the helper's bump is this start's token; don't bump again
  audition = mode
  lastAudition = mode
  do {
    try await audioPlayer.play(canonicalAudioURL, range, editPlan.source.sampleRate)
  } catch {
    reportIssue(error)
  }
  if auditionGeneration == generation { audition = nil }   // only the latest clears
}
```

**`observePlayback()` gate** extends to include auditions so the waveform playhead moves
while auditioning:

```swift
guard playingSliceID != nil || isPreviewingDraft || audition != nil else { … clear … }
```

The transcript-follow line stays slice-only (`isPlaying: … && playingSliceID != nil`) —
auditions move the waveform playhead but do not drive transcript scroll in v1.

---

## Model API (all logic lives here; the view decides nothing)

```swift
// MARK: - Audition (constants + derived display)
let auditionPreRollSeconds = 2.0
var canAudition: Bool                       // activeEditingRange is a non-empty range
let auditionInButtonLabel  = "▶ In  ["
let auditionOutButtonLabel = "]  Out ▶"
var isAuditioningIn: Bool  { audition == .cutIn }
var isAuditioningOut: Bool { audition == .cutOut }
var auditionStatusText: String?             // "Auditioning in-cut — Space to stop", else nil

// MARK: - User Actions
func auditionInTapped() async               // key [ and left button
func auditionOutTapped() async              // key ] and right button
func auditionSpaceTapped() async            // spacebar: stop / replay-last / in-cut
```

`auditionInTapped` / `auditionOutTapped` compute their range from `activeEditingRange`
(guarding nil/empty) and call `startAudition`. `auditionSpaceTapped` checks
`playingSliceID != nil || isPreviewingDraft || audition != nil` → stop; else replays
`lastAudition ?? .cutIn`.

---

## Keyboard handling

Bare `[`, `]`, and space cannot use the existing hidden-`Button`+`.keyboardShortcut`
pattern (too global, not focus-aware) or a `Commands` menu (wrong for bare transport
keys). **Slice renaming is a real `TextField`** (`SlicesPanelView.swift:76`), so these
keys must not fire while a text field is being edited.

**Approach:** a scoped `NSEvent` local key-down monitor, installed by a tiny
`NSViewRepresentable` mounted in `EditorView` (added on `makeNSView`, removed on
`dismantleNSView`, so it is live only while the editor is on screen).

The monitor **bails (returns the event unhandled) when a text field is being edited** —
i.e. the key window's `firstResponder` is an editable `NSText`/`NSTextView` (the field
editor backing a `TextField`). The transcript is a *non-editable* `NSTextView`
(`isEditable == false`), so it does not block auditions.

When not editing text, map and consume (return `nil`):

| key    | keyCode | action                |
|--------|---------|-----------------------|
| `[`    | 33      | `auditionInTapped()`  |
| `]`    | 30      | `auditionOutTapped()` |
| space  | 49      | `auditionSpaceTapped()` |

Actions are `@MainActor async`; the monitor dispatches `Task { await model.…() }`.

---

## Discoverability UI

All content/state from the model; the view only positions and styles.

- **Edge buttons on the waveform.** Overlaid on the highlighted span in `WaveformView`:
  a left button (`auditionInButtonLabel`, "▶ In  [") at the span's start edge, a right
  button (`auditionOutButtonLabel`, "]  Out ▶") at the span's end edge. Clicking calls
  the same model action as the key. The keys are therefore **always visible** whenever a
  region is displayed — the user learns them by seeing them. The active button reflects
  `isAuditioningIn` / `isAuditioningOut`.
  - **Narrow/offscreen span:** when the highlighted span is too small to hold both
    buttons without overlap, the view clamps their positions so they sit side-by-side
    with a small gap (pinned to the visible span), rather than overlapping. This is pure
    geometry; labels/enabled/active state still come from the model.
- **Status while auditioning.** `auditionStatusText` shows near the waveform
  ("Auditioning out-cut — Space to stop"), nil when idle. The highlighted region may
  tint while auditioning (view styling keyed off `isAuditioningIn/Out`).
- **Disabled state.** When `canAudition == false`, buttons render disabled (or hidden)
  and keys no-op.

---

## Edge cases

- **No region** (`activeEditingRange == nil`): buttons disabled/hidden; keys no-op.
- **Empty/invalid range** (`lowerBound >= upperBound`): treated as no region.
- **Out pre-roll** clamps its lower bound at 0 (may legitimately begin before the region
  start).
- **In-cut** upper bound is `durationSamples`; guarded so `start < total`.
- **Pathologically long files:** `AVAudioPlayerNode.scheduleSegment` uses
  `AVAudioFrameCount` (`UInt32`); the existing player already does the frame conversion.
  Interview lengths are far under the limit; no extra handling beyond current behavior.
- **Switching regions mid-audition:** the current audition keeps playing until it
  finishes or is superseded by the next `[`/`]`/space; starting a new one supersedes
  cleanly via `beginExclusivePlayback` + generation guard.

---

## Testing (Swift Testing, model only)

Mock `AudioPlayerClient` via `withDependencies { $0.audioPlayer = … }` with a double that
records each `play(url, range, sampleRate)` and lets the test control when `play`
returns (a stored continuation), mirroring how the existing slice/preview playback
supersession is exercised. Value comparisons use `expectNoDifference`.

Cases:

1. **Out range:** `auditionOutTapped` plays `[max(0, end - preRoll), end)`; pre-roll
   clamps at 0 for an early out-point.
2. **In range:** `auditionInTapped` plays `[start, durationSamples)`.
3. **No/empty region:** neither action calls `play`; `canAudition == false`.
4. **Space — playing:** with an audition (or slice/preview) active, space stops it
   (`audition == nil`, `audioPlayer.stop` called).
5. **Space — idle with history:** replays `lastAudition` (out after an out, in after an in).
6. **Space — idle no history:** in-cut.
7. **Supersession both ways:** starting an audition clears `playingSliceID` /
   `isPreviewingDraft`; starting a slice/preview clears `audition`.
8. **Stale-completion guard:** an older audition task completing does not clear a newer
   owner's state (generation check).
9. **`observePlayback` during audition:** a position tick moves `waveform.playheadSample`
   while `audition != nil`, and clears it when idle.
10. **Re-press restarts:** pressing `]` while out-cut plays supersedes and replays out.

The `NSEvent` monitor / `NSViewRepresentable` is a dumb bridge (no logic) and is not unit
tested, consistent with the app's treatment of the live audio engine path.

---

## Files touched (anticipated)

- `Views/Pages/Editor/EditorModel.swift` — audition state, three actions,
  `beginExclusivePlayback`, `startAudition`, extended `observePlayback` gate, refactor
  `playSliceTapped`/`previewEditTapped` to the helper, display props.
- `Views/Pages/Editor/EditorTests.swift` (or the editor's test suite) — cases above +
  updates where the internal reset moved into the helper.
- `Views/Pages/Editor/WaveformView.swift` — edge-button overlay + clamping geometry.
- `Views/Pages/Editor/EditorView.swift` — mount the key-monitor representable; status line.
- New: a small `NSViewRepresentable` key-monitor (e.g. `Views/Reusable Components/`).
