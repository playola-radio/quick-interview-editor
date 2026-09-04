# Stretch the crossfades — implementation plan

Scope: **length only** (edge-drag → `Crossfade.lengthSamples`). Center-offset,
curve bending, ⌃⌥X reset, and the numeric inspector stay deferred (later slices
of the locked PR 5 plan). Edits must be identical in the main editor and the
Edit Slice modal (one shared document, one commit funnel).

## Stage 1: Clamp helper on EditedTimeline
**Goal**: `EditedTimeline.maxCrossfadeLength(forSeamID:)` — the largest length a
seam can take given its neighbors (mirrors the init's sequential clamp).
**Tests**: isolated seam, asymmetric handles, adjacent seams sharing an island,
unknown id → nil.
**Status**: Complete

## Stage 2: EditorModel stretch API
**Goal**: `crossfadeStretchBegan(id:)`, geometry-free
`crossfadeStretched(toLength:)` (clamps to `maxCrossfadeLength`), and
`crossfadeStretchEnded()` (one `updateCrossfade` commit → one undo entry). Live
draft previews the bowtie via `seamOverlays`; no per-tick document mutation.
**Tests**: clamp to handle, floor at 0, one undo entry per drag, draft preview
width, cross-surface identity (modal stretch == main-editor stretch).
**Status**: Complete (cross-surface identity test deferred to Stage 4)

## Stage 3: Main-editor view wiring
**Goal**: bowtie edge handle layer in `WaveformLaneView` (clone
`WaveformEdgeHandleLayer`, hit-test the seam's two edges), drives the model.
**Status**: Complete — `SeamStretchHandleLayer` (above marquee, below the
selection-edge layer) hit-tests every bowtie's leading/trailing edge from the
`SeamOverlay` spans and drives `crossfadeStretchBegan/ed/Ended`; `CrossfadeEdge`
promoted to a top-level domain enum. `WaveformView` forwards the callbacks.

## Stage 4: Edit Slice modal parity
**Goal**: forward the stretch through the parent `EditorModel.updateCrossfade`
funnel (mirror `onRestore`); wire the same handle layer into `EditSliceView`.
**Status**: Deferred (commit `7490e52`) — `EditSliceModel` still mirrors the
stretch interaction and its model-level tests stay green, but the drag handles
are withheld on the sheet: the sheet edits and clamps a crossfade on the
*global* edited timeline, while a slice plays and exports on its own
*windowed* timeline, where a boundary-straddling crossfade collapses to a hard
cut. Dragging a boundary bowtie in the sheet could therefore author a fade the
slice renders as a hard cut — what you edit would not be what you hear or
export. `seamOverlays` withholds the drag handles (the bowtie still draws) on
the sheet until the slice-local seam projection lands in a follow-on PR; the
stretch machinery and its tests remain in place for that work.

## Codex adversarial review (round 2) — triage

- **F5 modal dead-zone (FIXED).** The modal passed `highlightRange` but wired no
  edge-drag callbacks, so the topmost no-op `WaveformEdgeHandleLayer` intercepted
  a 6pt zone around the slice boundary and shadowed the seam-stretch handles
  beneath — a seam edge near the slice boundary couldn't be stretched, breaking
  main/modal parity. Fix: `WaveformLaneView.supportsEdgeDrag` (default on; the
  modal sets it off) so the edge layer is only mounted where it can act.
- **F3 seam-edge click swallowed (FIXED).** `waveformClicked` deliberately
  selects a seam on a plain click ("Logic selects a crossfade on click"), but the
  new `SeamStretchHandleLayer` claimed the mouse-down in the bowtie-edge zones and
  a sub-threshold click did nothing — so clicking a crossfade edge no longer
  selected the seam. Fix: on a non-drag `mouseUp`, forward the click to the same
  `onBodyClick` closure the marquee layer uses, restoring click-to-select.
- **Scroll/zoom over a bowtie-edge zone (LOW, deferred).** Like the existing
  selection-edge handle layer, `SeamStretchHandleLayer` doesn't implement
  `scrollWheel`, so a pan/zoom gesture landing exactly in a 6pt edge zone is
  dropped. Pattern-consistent with the shipped `WaveformEdgeHandleLayer`; the
  affected band is tiny. Deferred, not introduced by this feature in kind.
- **F1 preview center-anchor vs commit join-anchor (design scope).** View-only
  preview can't reflow downstream content live (rebuilding the timeline per
  `mouseDragged` is the reentrancy crash we deliberately avoid), so the committed
  fade re-anchors on release. Inherent to the view-only-preview architecture.
  Manual-verify: watch for a handle "snap" on mouse-up at high zoom.
- **F2 modal render clamp / F4 hard-cut stretches left-only / F6 sequential
  clamp shrinks the neighbor** — pre-existing engine/geometry behavior, not
  introduced by edge-drag; out of the "length only" scope.

## Follow-up: grab cursor + live reflow (two user asks)

1. **Grab cursor over the bowtie edge (Item ①).** Cursor resolution goes to the
   *frontmost* view under the pointer, so a cursor installed on a lower layer is
   shadowed by any full-frame layer above it — which is exactly why the first
   attempt (a `.cursorUpdate` tracking area on `SeamStretchHandleLayer`) never
   fired in the main editor: the full-frame `WaveformEdgeHandleLayer` sits above
   it. Fix: a single dedicated `WaveformResizeCursorLayer` mounted as the TOPMOST
   band overlay. It is hit-through (`hitTest` always returns nil, so every drag
   still falls to the layers beneath) and owns the resize cursor for *all*
   draggable edges — both selection edges and bowtie edges (x's handed in via
   `resizeCursorEdgeXs()`), using `.cursorUpdate` + `.mouseEnteredAndExited`
   tracking areas. Cursor management was removed from both lower layers
   (`resetCursorRects` on the selection-edge layer, the `.cursorUpdate` areas on
   the seam layer), so there is one cursor owner and no cursor-rect/cursorUpdate
   mixing. Always mounted, so it also covers the slice sheet. GUI-only — needs
   visual confirmation.
2. **No reposition on release (Item ②).** The stretch now reflows the collapsed
   waveform live: `crossfadeStretched(toLength:)` pushes a preview `EditedTimeline`
   (built exactly as the commit builds it) into the adapter via
   `EditedWaveformAdapter.previewStretch` and shifts the viewport by −ΔL/2, so the
   seam grows symmetrically about its start-of-drag screen center, downstream
   content slides continuously during the drag, and the commit is a visual no-op
   (the old leftward jump on mouse-up is gone). Drag input reads geometry frozen
   at `crossfadeStretchBegan` (viewport + center) so the live reflow can't feed
   back on itself. Near the left edge, where the viewport can't shift further left,
   growth degrades to trailing-edge-pinned but the release still repositions
   nothing. Tests: `draggingReflowsTheCollapsedTimelineLive`,
   `committingAStretchLeavesTheWaveformWhereThePreviewHadIt`,
   `theGrabbedEdgeStaysUnderTheCursorAsTheTimelineReflows`.
   **Scope note:** implemented for the **main editor** only. The Edit Slice sheet
   keeps its center-anchored view-only preview (its adapter is pinned to the
   slice's sub-range, so the reflow + −ΔL/2 comp need extra care there). The
   *committed* edit is still identical across both surfaces (one `updateCrossfade`
   funnel); only the modal's transient drag visual still re-anchors on release. A
   parity pass for the modal is a deliberate later slice.

## Codex adversarial review (round 3, live-reflow follow-up) — triage

- **Commit skipped timeline reconciliation (HIGH, FIXED).** The live preview
  installed into `editedWaveform.timeline` the exact timeline the commit would
  produce, so `syncEditedTimeline`'s equality guard short-circuited on mouse-up —
  skipping playback/cursor/transport-origin remap, the `timelineChanged` zoom
  re-clamp, and `editSlice?.syncTimeline`. The visual no-op was also a *semantic*
  no-op: free playback could keep scheduling from the pre-stretch removal set, and
  zoom could stay too wide for the shorter timeline (blank trailing space). Fix:
  `crossfadeStretchEnded` rewinds the adapter to the pre-drag committed timeline
  (`editedWaveform.timeline = editedTimeline`) before committing, forcing a real
  diff so the reconciliation body runs; the previewed viewport was already clamped
  into the shorter axis, so it doesn't move (no jump). Also fixes the round-3
  MEDIUM zoom-clamp finding (same root). Regression:
  `committingAStretchRunsTimelineReconciliation`.
- **Lost `mouseUp` leaves adapter/document diverged (MEDIUM, deferred).** Since the
  draft now mutates the adapter (not just the overlay), a drag interrupted by view
  teardown could strand the preview timeline. Pattern-consistent with the shipped
  selection-edge drag (drag state cleared only on mouseUp); no new cancel path
  added. Follow-up: a `dismantleNSView`/cancel hook for both drag layers.
- **Undo/redo mid-drag keeps the same seam id (LOW, deferred).** `syncEditedTimeline`
  only drops the draft when the removal *disappears*; a same-id range/length change
  mid-drag isn't treated as stale. Requires keyboard undo while physically holding a
  mouse drag — very low probability. Follow-up: guard undo/redo on an active draft.
- **Left-boundary clamp / odd-delta off-by-one / stationary-pointer cursor (LOW).**
  Already-documented cosmetic degradations (see Item ② note above); commit stays
  correct in every case. No action.

## Stage 5: Audition on release (bounded seam audition)
**Goal**: play a bounded edited region around the seam on mouse-up (new
`.editedRange` transport case), so preview == export.
**Status**: Deferred — out of the approved "length only" scope. The user can
already hear the stretched fade via Play/Space; a bounded seam audition is a
later PR-5 slice.
