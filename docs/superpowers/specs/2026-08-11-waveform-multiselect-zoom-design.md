# Waveform multi-select + Logic-parity zoom/navigation — design

**Date:** 2026-08-11
**Branch:** `briankeane/waveform-multiselect-zoom`
**Status:** Approved — ready for implementation plan

## Goal

Bring Logic Pro navigation muscle-memory to the editor: extend the word
selection by Shift-click (instead of only dragging), zoom the waveform with the
mouse wheel, and make Logic's zoom keys work on the waveform. All interface
choices mirror Logic Pro (now a standing rule in `CLAUDE.md`).

This is **PR 1 of a 2-PR stack**. PR 2 (a movable main-timeline playhead +
transport keys: Space / Return / `,` / `.`) stacks on top of this branch and is
out of scope here. PR 1 must not box PR 2 in.

## Logic-parity mapping (verified against Logic Pro defaults)

| Interaction | Logic convention | This app |
|---|---|---|
| Extend selection | Shift-click extends the contiguous selection | Shift-click a word (transcript or waveform): anchor stays, focus moves |
| Horizontal zoom (wheel) | ⌥⌘ + scroll | **⌘ + scroll/swipe** on the waveform, anchored at the pointer (single-⌘ chosen for Magic-Mouse reliability — see note below) |
| Horizontal scroll/pan (wheel) | ⌘ + scroll | **plain scroll/swipe** pans (our lane has no vertical dimension) |
| Zoom out/in by step | ⌘← / ⌘→ | ⌘← / ⌘→ zoom the waveform out/in (recenters on viewport middle) |
| Zoom to fit | `Z` toggles fit-selection / fit-all, and back | `Z` fits selection if any else whole file; pressing again restores prior zoom+scroll |

## Architecture

The app is strict MV: `@MainActor @Observable` models hold all state and logic;
views are dumb. Two structural pieces are added; **all decision logic lives in
the models**, and the new AppKit surfaces only translate raw events into model
method calls.

### 1. Editor-scoped key monitor (keyboard)

A small `NSViewRepresentable` bridge placed in the Editor view installs a
**window-scoped local key monitor** (`NSEvent.addLocalMonitorForEvents(.keyDown)`)
and forwards recognized shortcuts to `EditorModel.editorKeyDown(_:)`.

- Rejected alternatives (per Codex consult): scene `.commands`/`CommandMenu`
  and hidden `.keyboardShortcut` buttons (menu/key-equivalent systems, fire while
  editing text unless carefully disabled, awkward to gate from a nested
  `@FocusState`); a focusable `NSView.keyDown` (must own first responder, fights
  the rename field and text system); SwiftUI `.onKeyPress` (focus-driven,
  macOS 14+).
- Monitor rules: handle only `.keyDown`; handle only `event.window === view.window`;
  consume only our known shortcuts (return `nil`), otherwise return `event`
  unchanged; **suppress entirely when a text-entry field is first responder**.
- Remove the monitor in `deinit`.
- **Editor-global, not focus-gated to the waveform** — the keys work whenever the
  Editor is visible, matching Logic. The transcript is non-editable /
  non-selectable, so ⌘←/⌘→/Z don't collide there.

**Text-entry suppression** is checked at the AppKit first-responder level, not
SwiftUI `@FocusState` (which won't reliably gate an app-level monitor):

```swift
private func isTextEntryActive(in window: NSWindow?) -> Bool {
  guard let responder = window?.firstResponder else { return false }
  if let tv = responder as? NSTextView, tv.isFieldEditor { return true }
  if responder is NSTextField { return true }
  return false
}
```

The only real text-entry field in the editor today is the slice-rename
`TextField` in `SlicesPanelView`. Suppressing editor-global keys there (and in
any future search/filter field) is the intended behavior.

### 2. Waveform AppKit interaction layer (mouse)

The waveform's mouse interaction moves from SwiftUI gestures
(`.onTapGesture` / `DragGesture` in `WaveformView`) to a **transparent AppKit
`NSView` interaction layer** overlaid on the existing `Canvas`. The `Canvas`
stays purely a renderer. The interaction view owns `scrollWheel(with:)` and
`mouseDown/mouseDragged/mouseUp` and forwards primitive facts to the model.

- Rejected alternatives (per Codex): a transparent overlay implementing only
  `scrollWheel` (breaks the taps/drags underneath); a local scroll monitor
  (same window-scoping/leak problems as a key monitor, wrong tool for a
  view-local gesture).
- The interaction view **consumes** handled scroll by not calling
  `super.scrollWheel(with:)`, so an enclosing `ScrollView` never double-scrolls.
- Pointer location for cursor-anchored zoom:
  `convert(event.locationInWindow, from: nil).x`.

### Delta normalization

Trackpad precise deltas are in pixels (`hasPreciseScrollingDeltas == true`);
mouse-wheel line deltas are not. Normalize in the **model**, not view plumbing
(e.g. ~40 px/line for line-based wheels). The NSView passes
`hasPreciseDeltas` through; the model decides.

## Model API

Views and the two AppKit surfaces only call these; everything testable.

**`WaveformModel`**
```swift
func panByPixels(_ deltaX: CGFloat)
func zoomByFactor(_ factor: Double, anchoredAtX positionX: CGFloat)
func zoomStepIn()
func zoomStepOut()
func zoomToFitAll()
func zoomToFit(_ range: Range<Int>)
func zoomFitToggled(selection: Range<Int>?)   // Z: fit ⇄ restore prior
```

**`EditorModel`**
```swift
func waveformClicked(atX positionX: CGFloat, extending: Bool)
func waveformScrolled(deltaX: CGFloat, deltaY: CGFloat,
                      hasPreciseDeltas: Bool,
                      modifiers: EventModifiers, atX positionX: CGFloat)
func editorKeyDown(_ key: EditorKey) -> Bool   // returns true if consumed
```
`EditorModel` decides command meaning (waveform click crosses waveform geometry
and transcript selection semantics) and, for `Z`, calls
`waveform.zoomFitToggled(selection: transcript.selectedSampleRange)`.

`EditorKey` is a small enum of the recognized shortcuts (`.zoomIn`, `.zoomOut`,
`.zoomFit`) so PR 2 can add cases (transport) without reworking routing.

**`TranscriptPageModel`**
```swift
func wordClicked(_ id: Word.ID, extending: Bool)
func transcriptClicked(atUTF16Offset offset: Int, extending: Bool)
```
Drag stays non-shift for PR 1. Both the transcript (point → UTF16 → word) and the
waveform (x → sample → word) funnel into the **one** `wordClicked(_:extending:)`
method — no duplicated shift logic.

## Behavior details

### Selection extend (`extending: Bool`)
- `false`: current click behavior (select / toggle-clear the single word).
- `true` + valid anchor: keep anchor, set focus to clicked word.
- `true` + no valid selection: plain select clicked word.
- `true` + same word: remains a one-word selection (does **not** toggle-clear).
- Empty transcript / missing word id: no-op.
- Stale/deleted anchor: fall back to plain select.

### Cursor-anchored zoom
```swift
let sampleUnderCursor = Double(visibleStartSample) + Double(mouseX) * oldSamplesPerPixel
samplesPerPixel = clampedSamplesPerPixel(oldSamplesPerPixel * factor)
visibleStartSample = clampedStart(
  Int((sampleUnderCursor - Double(mouseX) * samplesPerPixel).rounded()))
```
`factor = pow(zoomStep, normalizedDelta / ticksPerStep)`. Recompute from the
current invariant each event and clamp, so there's no drift accumulation. The
delta sign that maps to zoom-in is picked empirically (don't scatter NSEvent
sign semantics across call sites).

### Z toggle
Pressing `Z` stores the current `(samplesPerPixel, visibleStartSample)`, then
fits (selection range if non-nil, else whole file). Pressing `Z` again restores
the stored pair. Any manual zoom/pan/⌘-arrow between presses invalidates the
stored state so the next `Z` fits fresh rather than restoring stale state.

## Latent bug to fix (found during design)

`TranscriptPageModel.hasSelection` returns true when `selectionAnchorID != nil`,
but the derived `selectedWords` can be empty if the anchor/focus ids have gone
stale. Make `hasSelection` (and selection-derived values) validate that the
anchor/focus still resolve to words, so downstream (slice-add, summary) never
acts on an empty selection it believes is non-empty. Add a regression test.

## Testing

Pure model tests — no `NSEvent`, no audio, no subprocess; Swift Testing with
`expectNoDifference`/`expectDifference`:

- **Selection:** extend keeps anchor + moves focus; no-prior-selection extend =
  plain select; same-word extend stays one word; stale anchor → plain select;
  empty transcript no-op.
- **Zoom:** `zoomByFactor(anchoredAtX:)` keeps the sample under `x` fixed across
  zoom in and out; clamps at `minSamplesPerPixel` and the fit limit.
- **Pan:** `panByPixels` clamps at both ends.
- **Z toggle:** fit-selection then restore round-trips the exact prior pair;
  fit-all when no selection; manual zoom between presses invalidates restore.
- **Delta normalization:** line-wheel vs precise-trackpad produce comparable
  zoom/pan magnitudes.
- **`hasSelection`** regression: false when anchor is set but ids are stale.

AppKit surfaces (key monitor, interaction view) are thin translators and are not
unit-tested; their logic is exercised through the model methods they call.

## PR split (stacked)

- **PR 1 (this branch):** everything above.
- **PR 2 (stacked on PR 1's branch):** movable main-timeline playhead +
  transport keys. Adds `EditorKey` cases and model methods only; no rework of
  PR 1's routing or geometry. `scrollWheel`/key code stays ignorant of the
  playhead in PR 1.
