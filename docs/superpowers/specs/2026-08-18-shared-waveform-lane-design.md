# Shared Waveform Lane — Design

**Date:** 2026-08-18
**Follows:** the slice-detail edit modal (PR #47, `docs/superpowers/specs/2026-08-18-slice-detail-edit-modal-design.md`)
**Status:** Approved direction; Codex-reviewed. Intended as its own PR, executed in a fresh context.

## Problem

The slice-detail modal (PR #47) shows a **static, non-interactive** slice waveform (an
edge-to-edge silhouette). The user wants the modal's waveform to behave **exactly like
the main editor's**: zoom (⌘+scroll, and the zoom buttons), scroll/pan, and a **clickable
ruler strip above the lane** that moves the playhead (click-to-move) — each window with its
**own independent viewport** (zooming/scrolling the modal must not move the main lane).

The right way to get "exactly the same" is to **extract one reusable waveform component**
used by both windows, rather than reimplementing interactions in the modal.

## Current architecture (verified)

- **`WaveformModel`** (`Views/Pages/Editor/WaveformModel.swift`) is already a self-contained
  geometry engine: `samplesPerPixel`, `visibleStartSample`, `viewportWidth`; `zoomByFactor(_:anchoredAtX:)`,
  `panByPixels`, `zoomInTapped`/`zoomOutTapped`, `zoomFitToggled(selection:)`, `scrolled(toStartSample:)`,
  `columns(in:pixelWidth:)`/`visibleColumns()`, `xToSample`/`sampleToX`, `span(for:)`, `playheadX(for:)`,
  `viewportResized(width:)`, plus display text (`caption`, `zoomInLabel`…) and state
  (`canZoomIn`/`canZoomOut`, `showsLoading`/`showsEmpty`, `hasUsableGeometry`). It loads a decoded
  min/max pyramid `Waveform` (a `Sendable, Equatable` value struct — `Core/WaveformClient.swift:14`)
  **once** via `load(url:planSampleRate:durationSamples:)` (expensive full-file AVAssetReader decode).
  The decoded `Waveform` is stored as `var waveform: Waveform?` but is **not injectable** today
  (`load()` is the only populate path).
- **The view layer is fully bound to `EditorModel`.** `WaveformView` and its ~7 subviews
  (`WaveformCanvas`, `WaveformPlayhead`, `WaveformRulerView` + `RulerPlayhead` +
  `WaveformRulerInteractionLayer`, `WaveformInteractionLayer`, `AuditionEdgeButtons`) all take
  `EditorModel` and reach geometry via `model.waveform`. The `EditorModel` coupling points:
  - `playheadX` (`EditorModel.swift:285`) = `waveform.playheadX(for: playheadSample)`
  - `waveformHighlightSpan` (`:281`) = `activeEditingRange.flatMap(waveform.span(for:))`,
    where `activeEditingRange` (`:190`) = `fineTune.draftRange ?? activeOrSelectedRange`
  - `rulerMovedPlayhead(toX:)` (`:1100`) — ruler click/drag: stop transport + set `playheadSample` + bump `cursorMoveGeneration`
  - `waveformClicked(atX:extending:)` (`:445`) — **body click selects a WORD** (`wordID(atSample:)` → transcript), not a raw cursor
  - `waveformAreaSelectBegan/Changed/Ended(...)` (`:468/:485/:499`) — Logic-style **marquee** → transcript selection + an **auto-scroll timer**
  - `waveformScrolled(deltaX:deltaY:hasPreciseDeltas:optionDown:commandDown:atX:)` (`:634`) — a thin dispatcher: ⌘ ⇒ `waveform.zoomByFactor`, else ⇒ `waveform.panByPixels`, using static `scrollZoomFactor`/`scrollPanPixels` (`:1567`/`:1574`) + constants `pointsPerScrollLine`/`pixelsPerZoomDouble`
  - `editorKeyDown(EditorKey)` (`:650`) — ⌘←/⌘→/Z → `waveform.zoom*`/`zoomFitToggled`; wired via `EditorKeyMonitor` mounted at `EditorView` level (guards `window.isKeyWindow`)
  - audition (6 members): `canAudition`, `auditionStatusText`, `auditionInButtonLabel`/`OutButtonLabel`, `isAuditioningIn`/`Out`, `auditionInTapped()`/`auditionOutTapped()`
- **The modal** (`EditSliceModel`) already has its **own** independent `playheadSample: Int?`
  (fed only while `transportContext == .sliceEdit`) and already reuses the parent's decoded pyramid
  via a `columnsProvider` closure. Its current waveform (`SliceOverviewWaveform` in `EditSliceView.swift`)
  is a static silhouette with a tap-to-seek gesture — no zoom/scroll/ruler.

## Decision — extract `WaveformLaneView` (Codex-reviewed)

A new reusable **`WaveformLaneView`** = the **ruler strip + waveform body + all zoom/scroll/pan/click
interaction**, backed **only** by a `WaveformModel` plus a small injected surface. **No `EditorModel`
reference.** Because the lane *holds* the `WaveformModel`, it reads all geometry/display/zoom-state
directly (`caption`, `canZoomIn`, `visibleColumns()`, `playheadX(for:)`, `span(for:)`, `showsLoading`…)
and performs pure-geometry mutations directly (`zoomInTapped`, `scrolled(...)`). The owner injects
only what carries *meaning*:

```
WaveformLaneView(
  waveform: WaveformModel,            // geometry engine (owned per-window)
  playheadSample: Int?,               // lane computes x via waveform.playheadX(for:)
  highlightRange: Range<Int>?,        // lane computes span via waveform.span(for:)
  onRulerMove: (CGFloat) -> Void,     // raw view-x (Phase 1: EditorModel.rulerMovedPlayhead)
  onBodyClick: (CGFloat, Bool) -> Void,      // raw x, extending
  onAreaSelectBegan: (CGFloat, Bool) -> Void,
  onAreaSelectChanged: (CGFloat) -> Void,
  onAreaSelectEnded: (CGFloat) -> Void,
  auditionOverlay: (WaveformSpan) -> some View   // main editor fills; modal returns EmptyView
)
```

- **Geometry-only interactions talk to `WaveformModel` directly** inside the lane's AppKit layers:
  scroll/pan/zoom (`waveform.scrolled(...)`), zoom buttons (`waveform.zoomInTapped()`), x↔sample.
  **Raw view-x is forwarded** for the semantic callbacks (ruler-move, body-click, marquee) so
  the owner keeps exact x→sample→meaning control (this preserves the main editor's word-select
  and marquee-with-auto-scroll semantics unchanged).
- **The header stays outside the lane.** Each window supplies its own controls (main editor:
  transport panel + caption + zoom buttons + audition status; modal: its transport row + zoom buttons).
- **Audition stays editor-specific** via the `auditionOverlay` slot — the main editor passes
  `AuditionEdgeButtons`; the modal passes `EmptyView` (it has its own boundary insets).
- **Zoom keys (⌘←/⌘→/Z) stay at the window level**, not in the lane. The main editor keeps its
  `EditorKeyMonitor`. The modal **defers** a sheet-scoped key monitor for v1 (Codex flagged
  double-monitor/`isKeyWindow` risk under sheets); ⌘+scroll + zoom buttons cover zoom in the modal.

### Move the scroll dispatch onto `WaveformModel`

`waveformScrolled` + `scrollZoomFactor`/`scrollPanPixels` + `pointsPerScrollLine`/`pixelsPerZoomDouble`
are pure geometry (they only call `waveform.zoomByFactor`/`panByPixels`). Move them onto `WaveformModel`
as `func scrolled(deltaX:deltaY:hasPreciseDeltas:optionDown:commandDown:atX:)`. `EditorModel.waveformScrolled`
delegates to it (kept so existing tests/callers are unaffected). Both interaction layers then call
`waveform.scrolled(...)` directly.

### Pyramid sharing — `adopt`

Add an injectable path so a **second** `WaveformModel` (the modal's) reuses the parent's already-decoded
`Waveform` with **zero re-decode**:

```
func adopt(_ waveform: Waveform, sampleRate: Int, totalSamples: Int)
```

It sets `waveform`, `sampleRate`, `totalSamples`, `isLoading = false`, and (if `viewportWidth > 0`)
fits/clamps the viewport. `Waveform`'s arrays are COW value data, so this is cheap and the two models'
**viewport state stays fully independent** (only the immutable decoded value is shared).

**Adoption timing (Codex's key correctness point):** never let the sheet call `load()` (that re-decodes).
- `editSliceTapped`: if the parent `waveform.waveform` is already decoded, `adopt` it into the new
  `EditSliceModel.waveform` immediately.
- `EditorModel.loadWaveform()`: after the parent finishes decoding, `adopt` into any currently-open
  `editSlice` (covers "modal opened before the decode finished").

### Modal viewport — whole file, zoomed to the slice with padding

The modal's `WaveformModel` adopts the **whole-file** pyramid and initializes its viewport **zoomed to the
slice range with padding** (so you can zoom/scroll out to see just before/after the cut) — **not**
hard-clamped to the slice. Highlight range = `fineTune.draftRange ?? committedRange` (the draft cut).

### Interactive ruler ⇒ seek must work during playback

Once the modal's ruler is click-to-move, `onSeek`/ruler-move must actually reposition audibly during
playback (today's `onSeek` only moves the cursor and is overwritten by the next tick — Codex: "will feel
broken once the ruler is interactive"). Ruler/body click in the modal moves the modal cursor and, if
playing, stops/re-anchors playback (v1: stop-and-reposition, matching the main editor's ruler behavior).

### Folded-in tweaks (same layout pass)

- **Near-full-window modal** — expand the `.sheet` frame toward the window (the extraction reshapes the
  modal's waveform section anyway; size it once).
- **1.0× speed on open, restored on close** — the modal edits at normal speed for accurate trimming
  without clobbering the main editor's chosen speed. Save the shared `playbackRate` on `editSliceTapped`,
  set 1.0, restore on dismiss.

## Staging (Codex's low-risk order)

1. **Phase 1 — pure refactor, zero behavior change.** Move scroll dispatch onto `WaveformModel`; extract
   `WaveformLaneView`; rewire the **main** editor's `WaveformView` to a thin wrapper (header + lane) whose
   lane callbacks are **adapters that call today's `EditorModel` methods verbatim** (raw x). The full existing
   suite (~660 tests) must stay green — this is the safety gate proving the main editor is unchanged.
2. **Phase 2 — modal gets the real lane.** Add `EditSliceModel.waveform` (adopt parent pyramid, zoom-to-slice+padding),
   replace `SliceOverviewWaveform` with `WaveformLaneView`, add slice-scoped ruler/body-click callbacks, make
   seek work during playback, plus the near-full-window frame and 1.0× speed.

## Non-goals (v1)

- Sheet-scoped ⌘←/⌘→/Z key monitor for the modal (deferred; ⌘+scroll + buttons suffice).
- Marquee word-selection inside the modal (the modal edits boundaries, not word selections) — the modal's
  body click moves the cursor; it does not select words or marquee.
- Audition buttons in the modal.

## Testing

Model-level, Swift Testing, `expectNoDifference`, `Fixtures.editPlan()`, no `Task.sleep`; tests in
`QuickInterviewEditorTests/…`. Phase 1's guarantee is the **existing** suite staying green (behavior-preserving
refactor) plus a `WaveformModel.scrolled` unit test. Phase 2 adds `WaveformModel.adopt` tests (shares pyramid,
independent viewport), and `EditSliceModel` tests for the scoped waveform (zoom-to-slice init, ruler-move moves
the modal cursor, highlight tracks the draft, seek during playback repositions).

## Risks (Codex-ranked) & mitigations

1. **Breaking marquee/word-select semantics** → Phase 1 keeps the exact `EditorModel` methods behind adapters
   (raw x forwarded); the auto-scroll timer stays in `EditorModel`; the existing suite is the gate.
2. **Re-decode from incomplete adoption timing** → the two-point adoption rule above; never call `load()` from the sheet.
3. **Double key-monitor under sheets** → deferred entirely in v1.
4. **Moving transport-stop/cursor-generation out of `EditorModel`** → it stays; the lane forwards x, the owner owns meaning.
5. **Audition dragging editor UI into the lane** → kept out via the optional `auditionOverlay` slot.
