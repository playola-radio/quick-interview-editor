# Cmd-click multi-word selection + multi-delete — design

**Date:** 2026-10-15
**Status:** Approved in chat; awaiting written-spec review
**Supersedes:** the "No non-contiguous multi-word selection is introduced" line in
`2026-08-04-transcript-textkit-zoom-scroll-design.md`; extends the gesture table in
`2026-09-08-transcript-group-selection-design.md`.

## 1. Goal

Let the user Cmd-click several non-adjacent words in the transcript (e.g. every
"uh"), then press ⌫ to remove them all at once — one crossfade per removed piece,
one undo step.

## 2. Locked decisions

| # | Decision |
|---|----------|
| 1 | Gesture is **Cmd-click in the transcript only**. No Cmd-drag, no waveform additive gesture. Ctrl-click is macOS right-click, so it is not used. |
| 2 | Cmd-click is **add-only**. Cmd-clicking an already-selected word is a no-op. |
| 3 | An existing contiguous `.range` (drag / Shift-click) is kept as one piece; Cmd-clicked words are added as further pieces. |
| 4 | From `.none`, `.object` (clip/suggestion) or `.seam`, Cmd-click discards the old selection and starts a single-word `.range`. It never implicitly includes an object's whole range. |
| 5 | Cmd-click on a **fully removed** (struck-through) word is a no-op. A partially removed word is selectable. |
| 6 | Plain click, drag, and any waveform selection replace the selection exactly as today. **Shift-click** collapses to single-range and extends from the primary piece's anchor. Command wins over Shift when both are held. |
| 7 | Cmd-double-click never opens a clip/draft; Cmd-drag does nothing (no drag selection starts). |
| 8 | ⌫ removes every piece in **one** `mutateDocument` / history entry. Abutting or overlapping pieces merge first; each resulting disjoint piece becomes one `TimelineRemoval` with the default crossfade (20 ms equal-power). |
| 9 | Existing removals are absorbed with today's strict-overlap rule (as in `removeSourceRange`); untouched removals keep their IDs and crossfade settings. |
| 10 | Undo restores the audio and leaves the selection cleared — same as today's single-range delete. |
| 11 | While >1 piece is selected, only removal is available (⌫ and the Remove Section control). Mark as Clip / open, fine-tune, audition, edge drag, resize, and nudge are unavailable. |
| 12 | Waveform highlights every piece; edge handles and audition buttons appear only for a single range. |

**Logic parity note:** Logic toggles region selection with Shift-click, but Shift
already means "extend contiguous selection" here; Cmd-click is the macOS-standard
(Finder/Mail) discontiguous add. Deliberate divergence.

## 3. Architecture

### 3.1 Selection state

Add a case to `Models/EditorSelection.swift`:

```swift
case ranges(MultiRangeSelection)

struct MultiRangeSelection: Equatable, Sendable {
  var primary: Range<Int>        // the piece the anchor belongs to
  var anchor: Int
  var additional: [Range<Int>]   // sorted, disjoint, non-abutting with primary
  var allRanges: [Range<Int>]    // computed: sorted union
}
```

- Ranges are **source samples** (what removals use; word IDs are not guaranteed unique).
- Invariant: `.ranges` always holds ≥ 2 disjoint, non-abutting pieces. Any operation
  that would leave one piece demotes to `.range(primary, anchor:)`.
- `freeformRange` (and so `audioSelection`, `selectedSourceRange`,
  `pendingRemovalSourceRange`, fine-tune sync, edge drag, nudge, audition) stays
  **single-range-only** — returns `nil` for `.ranges`, so those features disable
  without per-feature code.
- New computed `selectedRanges: [Range<Int>]` — `[r]` for `.range`, `allRanges` for
  `.ranges`, `[]` otherwise. Used by delete, transcript highlight, and waveform highlight.
- `activeEditingRange` must not fall back to the active slice / fine-tune draft while
  `.ranges` is selected.
- Every exhaustive `switch` over `EditorSelection` handles the new case explicitly
  (`reconcileSelection`, `deleteSelectionTapped`, `applyHistory`, etc.).

### 3.2 Gesture plumbing

- `TranscriptClick` gains `additive: Bool` (Command held at mouse-down).
- `HitTestingTextView` reads `.command` on mouse-down; while held, no drag gesture
  begins. `mouseUp` forwards `additive`. `TranscriptResizeHandleOverlayView` forwards
  Command as well as Shift.
- `EditorModel.transcriptClicked(_:)` branches on `additive` **before** the
  double-click / `clickCapture` logic: clears `clickCapture`, never calls
  `openCapturedTranscriptClick`, and calls a new `addWordToSelection(_:)`.
- `addWordToSelection` resolves the clicked word's sample range, applies rules 2–5,
  normalizes (merge abutting/overlapping with any existing piece), and writes the
  selection through the existing `selectSourceRange` path for `.range`, or sets
  `.ranges` directly with `SelectionOrigin.transcript` semantics.

### 3.3 Delete

Refactor `removeSourceRange(_:)` into `removeSourceRanges(_ ranges: [Range<Int>])`;
`removeSourceRange` becomes a one-element wrapper (keeps the Edit Slice
`onRemoveSection` caller unchanged).

Normalization inside one `mutateDocument(label:)` closure:

1. Clamp to source bounds; drop empty ranges.
2. Sort; merge overlapping or abutting ranges.
3. Absorb existing removals that strictly overlap any range; repeat until stable
   (one removal can bridge two pieces).
4. Remove absorbed removal IDs; append one fresh `TimelineRemoval` per final piece
   with the default crossfade.

Label: `"Remove Section"` for one piece, `"Remove Sections"` for several.
`deleteSelectionTapped` routes `.ranges` → `removeSourceRanges(selection.selectedRanges)`;
the post-mutation teardown (`transcript.clearSelectionTapped()`, `fineTune.clear()`,
`reconcilePlayback()`) is unchanged. `canRemoveSelectedSection` is true for `.ranges`.

### 3.4 Rendering

- **Transcript:** `selectedWordIDs` becomes the union of words overlapping each of
  `selectedRanges`. `TranscriptDocument.selectionRuns` already draws disjoint runs.
- **Waveform:** `WaveformLaneView` takes `highlightRanges: [Range<Int>]` plus
  `interactiveHighlightRange: Range<Int>?`. `WaveformHighlight` draws every span;
  edge handles and audition overlay key off `interactiveHighlightRange` only (nil for
  multi). Callers: `WaveformView`, `EditSliceView` (single-range, passes `[r]` + `r`).
  All of this is model-derived; the view only draws.

## 4. Out of scope

Cmd-drag, Cmd-click toggle-off, waveform additive selection, multi-selection in the
Edit Slice modal, restoring the multi-selection on undo, per-piece crossfade editing
before delete.

## 5. Testing

Model tests (Swift Testing + `expectNoDifference`), colocated with existing suites:

- **Selection:** Cmd-click from `.none` / `.range` / `.ranges` / `.object` / `.seam`;
  existing range kept as primary; re-click no-op; removed-word no-op; abutting words
  merge (and demote to `.range` when only one piece results); plain click, Shift-click,
  drag, waveform click collapse; Cmd+Shift acts additive; Cmd-double-click does not
  open; Cmd prevents drag start; resize overlay forwards Command.
- **Gating:** for `.ranges`, `canAddSlice`, `canOpenSelection`, fine-tune, audition,
  edge-edit, nudge are unavailable; `canRemoveSelectedSection` true;
  `activeEditingRange` does not show the active slice.
- **Delete:** N disjoint pieces → N removals with default crossfade; transitive
  absorption through an existing removal; untouched removals keep ID + crossfade;
  one history entry; undo restores all audio with selection cleared; redo re-applies;
  blocked while exporting.
- **Rendering data:** `selectedWordIDs` covers every piece; waveform highlight ranges
  list every piece and the interactive range is nil.
- **Regression:** full existing suites for selection, group selection, area select,
  seam selection, transcript selection/page, removal, selection history, editor
  history, waveform, and export-removal.

One PR.
