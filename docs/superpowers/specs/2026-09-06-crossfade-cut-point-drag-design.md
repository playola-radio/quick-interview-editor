# Crossfade cut-point drag — design

**Status:** Approved (design), pending spec review
**Date:** 2026-09-06
**Related:** `2026-08-18-remove-section-crossfade-design.md` (the remove-section +
crossfade feature this extends), `2026-08-19-freeform-waveform-selection-design.md`

## Problem

Deleting a segment creates a `TimelineRemoval`: a removed source-sample range
`[cL, cR)` plus a `Crossfade` that blends the two surviving pieces so the splice
isn't an audible click. Today the only post-hoc adjustment is the symmetric
**bowtie-stretch** gesture, which changes the crossfade *length*.

Users need to fine-tune **where each side of the join lands** — independently —
so they can catch or dodge a breath/word on the left vs. the right of the cut.
That means moving the left cut point (`cL`) and the right cut point (`cR`)
independently, **without changing the crossfade length**.

## Audio model (ground truth)

For a removal `[cL, cR)` with effective crossfade length `L`, playback during
the fade blends the **tail of the kept-left** audio with the **head of the
kept-right** audio. The fade does **not** reach into the removed span:

```
left kept:   ... < cL
removed:     [cL, cR)          ← not used by the fade
right kept:  cR ...

for k in 0..<L:
  out = source[cL - L + k] * fadeOut[k]   // last L samples before the left cut
  in  = source[cR + k]     * fadeIn[k]    // first L samples after the right cut
  sample = out + in
```

`AudioEditRenderPlan` strips those `L` tail/head samples from the normal segment
items so every edited sample is covered exactly once; live audition and export
both go through `AudioEditRenderPlan` + `CrossfadeRenderer.blend`, so they stay
aligned ("preview == export").

Note: `TimelineSeam.sourceCut` is only `cL` (`removedRange.lowerBound`). The
right cut `cR` exists only as `removedRange.upperBound`, reached by following the
seam's `id` back to its `TimelineRemoval`. There is no two-cut seam type.

## Decision: move `removedRange` bounds, not `centerOffsetSamples`

Moving a cut point is modeled as **editing one bound of
`TimelineRemoval.removedRange`, with the crossfade length pinned.** Concretely:

- **Left cut earlier** (`cL` ↓): more left audio removed; `leftTail` shifts
  earlier; the fade starts earlier on the edited axis; edited duration shrinks.
- **Left cut later** (`cL` ↑): previously-removed audio before the old `cL` is
  revealed; the fade starts later; edited duration grows.
- **Right cut later** (`cR` ↑): more right audio removed; `rightHead` shifts
  later; edited duration shrinks.
- **Right cut earlier** (`cR` ↓): previously-removed audio before the old `cR`
  is revealed; edited duration grows.

This is the only representation that matches the user's mental model ("the left
delete point moves earlier; the crossfade begins earlier because of the change
beneath it") **and** keeps preview/export honest with the existing pipeline.

**`Crossfade.centerOffsetSamples` is explicitly NOT used here.** It is a stored
-but-inert field intended for asymmetric fade *shape*; the renderer/export/preview
do not read it today. Using it would create UI state that neither plays nor
exports. It stays inert; this feature does not touch it.

**Renderer impact: none.** Because the fade material is derived from
`removedRange`, changing `cL`/`cR` changes the played/exported samples with **no
change to `CrossfadeRenderer` or `EditedTimeline`'s fade math.**

### Worked example

`cL = 100000`, `cR = 150000`, `L = 880` (20 ms @ 44.1 kHz). User ⌥-drags the
left waveform inward → `cL` becomes `98000`. Fade now blends `[97120, 98000)`
(out) with `[150000, 150880)` (in): the right side is untouched, the left side
fades from 2000 samples earlier, everything after the join shifts 2000 samples
earlier, length stays exactly `880`.

## Interaction

### Select the crossfade first (reuses `selectedSeamID`)

The existing `selectedSeamID` mechanism is the disambiguation for "which
crossfade" (e.g. between two adjacent removals). Clicking a bowtie already
selects it, deliberately does **not** move the playhead, and is mutually
exclusive with the freeform range selection. Because seam selection is inert to
transport, **play/pause and ruler click-to-move-playhead keep working** while
the user auditions the edit repeatedly — those live on separate layers this
feature never touches.

### ⌥-drag the outside waveform (arms cut-point move)

- New AppKit overlay layer exposes two **narrow hit zones adjacent to the
  selected bowtie**: a left zone immediately before `editedCrossfadeStart`, a
  right zone immediately after `editedCrossfadeStart + L`. Not the whole
  waveform.
- The layer claims **only ⌥-modified hits**. It sits **above**
  `SeamStretchHandleLayer` in the overlay stack, so ⌥ near the bowtie moves a
  cut point while a plain drag on the bowtie edge still stretches length.
- **Auto-select-then-drag in one motion** (matches the stretch handle): a
  ⌥-drag that begins in an outside zone selects that seam if needed, then drags.
  Works identically when the seam is already selected.
- The `.option` modifier is read **once at mouse-down / hit acquisition** (like
  the Shift-marquee), so releasing ⌥ mid-drag does not retarget the gesture.
- Left zone drags `cL`; right zone drags `cR`.

### Nudge ±10 ms (keyboard)

Reuses the existing `nudgeMs = 10.0`, mirroring the current selection-nudge
convention (unshifted = start edge, shifted = end edge):

| Keys        | Effect               |
|-------------|----------------------|
| `⌥←` / `⌥→` | left cut earlier / later  |
| `⌥⇧←` / `⌥⇧→` | right cut earlier / later |

`⌥`/`⌥⇧` + arrows are currently unclaimed by `EditorKeyMonitor`. Seam-nudge
arbitration must run **before** the existing `nudgeSelection` fallback (which
targets the freeform range and no-ops when a seam is selected). No hidden
"focused edge" state in v1 — unshifted/shifted = left/right is discoverable and
matches the range-nudge model.

## Implementation shape

Mirror the proven stretch-drag pattern — draft → view-only preview → single
commit — but with **new** pieces so cut-point editing does not tangle with
length-stretch.

### New draft (transient view state)

```swift
struct CrossfadeCutPointDraft: Equatable {
  var id: TimelineRemoval.ID
  var edge: RemovalBoundary            // .lower (cL) / .upper (cR)
  var committedRange: Range<Int>
  var draftedRange: Range<Int>
  var frozenCrossfadeLength: Int       // EFFECTIVE length, frozen at drag begin
  var frozenPreviousCrossfadeLength: Int
  var frozenNextCrossfadeLength: Int
  var committedEditedCrossfadeStart: Int
  var frozenVisibleStart: Int          // frozen viewport geometry
  var frozenSamplesPerPixel: Double
  var dragStartX: CGFloat
}
```

### New model methods (on `EditorModel`)

```swift
func crossfadeCutPointDragBegan(id:edge:atX:)
func crossfadeCutPointDragged(toX:)
func crossfadeCutPointDragEnded()
func crossfadeCutPointDragCancelled()
```

- `Dragged` maps x → source sample (using **frozen** geometry), clamps, updates
  the draft, and repaints via the edited-waveform preview path — **document
  untouched mid-drag**.
- `DragEnded` commits once.

### New commit funnel (document mutation)

```swift
func updateRemovalRange(id:removedRange:freezingCrossfadeLength:)
```

- Preserves the removal `id`. **Does NOT** route through `removeSourceRange`
  (which merges + mints a new UUID and would break selection/undo/restore
  identity).
- Guarded against `isExporting`, same as `updateCrossfade` / `removeSourceRange`.
- Writes the frozen effective length into the crossfade so a later handle change
  can't silently re-grow the fade.

### Clamps (computed from committed, normalized `EditedTimeline` at drag begin)

```
r = removals[i]; [cL, cR) = r.removedRange
F = seams[i].crossfadeLength                       // effective length, frozen
prevUpper = i>0 ? removals[i-1].removedRange.upperBound : 0
nextLower = i+1<count ? removals[i+1].removedRange.lowerBound : sourceDuration
prevF = i>0 ? seams[i-1].crossfadeLength : 0
nextF = i+1<count ? seams[i+1].crossfadeLength : 0

newCL = clamp(proposedCL, lower: prevUpper + prevF + F, upper: cR - 1)
newCR = clamp(proposedCR, lower: cL + 1,                upper: nextLower - F - nextF)
```

Preserves: non-empty removal, no overlap with neighbor removals, enough
handle for the selected fade on each side, and enough shared kept material so
adjacent fades don't collapse.

## Correctness traps (must-address)

- `TimelineSeam.sourceCut` is only `cL`; never infer `cR` from it.
- `centerOffsetSamples` stays inert; do not repurpose it here.
- **Preserve `TimelineRemoval.id`** on a bound-move (selection/undo/restore
  identity).
- **Freeze effective fade length**, not the stored `lengthSamples` (a stored
  overlong length can re-expand when handle becomes available).
- Clamp against adjacent **effective** fades, not just raw source bounds.
- Never allow zero-length or inverted `removedRange` — validation drops it and
  the selected seam vanishes.
- Rewind `editedWaveform.timeline = editedTimeline` before commit (same as
  stretch) so `syncEditedTimeline` doesn't equality-skip reconciliation.
- Use frozen viewport geometry for drag math; live `xToSourceSample` feeds back
  as the preview timeline reflows.
- Stop playback at drag begin (the edited axis changes under the transport).
- Keep export blocked during mutation.

## Testing

Model-level (Swift Testing, mock deps, bundled fixtures — no audio/subprocess):

- Left drag with `cL` decreasing / increasing → `removedRange` updates, length
  unchanged, id preserved, edited duration shifts as specified.
- Right drag symmetric.
- Clamp: cannot cross the other cut; cannot overlap / starve a neighbor removal;
  respects `prevF`/`nextF`.
- Effective-length freeze: an overlong stored `lengthSamples` does not re-grow.
- Nudge: `⌥←/→` moves `cL`; `⌥⇧←/→` moves `cR`; ±10 ms; arbitration runs before
  `nudgeSelection`; no-op with no seam selected.
- Undo/redo/restore keeps the selected seam (id stable).
- Preview draft never mutates the document; cancel restores committed range.
- Commit blocked while exporting.

## Out of scope

- Asymmetric fade *shape* (`centerOffsetSamples` DSP) — stays deferred.
- Moving the whole join (both cuts together) — different feature.
- Any `CrossfadeRenderer` / `EditedTimeline` fade-math change (none needed).
