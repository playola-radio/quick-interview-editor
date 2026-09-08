# Transcript Resize Handles — Design

**Status:** Approved (design shape), pending spec review
**Date:** 2026-09-07
**Ship as:** one PR (built in dependency-ordered commits)

## Goal

In the transcript, let the user resize three item types by dragging their
start/end edge:

1. The current text selection
2. Cut suggestions (pending only)
3. Clips (slices)

Hovering near an item's start or end edge shows the `<>`
(`NSCursor.resizeLeftRight`) cursor. Click+drag that edge across words to
grow/shrink the item. The edge snaps to **whole-word** boundaries.

## Locked product decisions

- **D1 — Snap granularity:** whole-word. The edge hops word-by-word as the
  pointer moves across words; it never lands mid-word.
- **D2 — Edge priority on overlap:** Selection > Clip > Suggestion. When two
  items' edges fall under the same point, the higher-priority one grabs.
- **D3 — Suggestion resize is undoable:** resizing a suggestion mutates
  `documentCutSuggestions` through `mutateDocument`, recorded as one undo entry,
  same as clip resize.
- **Q2 — Affordance:** cursor change only, no drawn grip (matches the waveform).

## Non-goals

- No sample-level resize in the transcript (that stays on the waveform).
- No resize of accepted/rejected suggestions (accepted ones are clips; rejected
  ones aren't drawn as active bands).
- No new visible handle glyph.

## Architecture

MV pattern preserved: **the view holds no logic.** `EditorModel` owns the
resize state machine and all mutation; `TranscriptPageModel` carries only
gesture plumbing; the `Coordinator` (which owns the TextKit stack) produces
edge geometry; a new transparent AppKit overlay hosts cursor + hit-testing.

### Component: `TranscriptResizeHandleOverlayView: NSView`

- Added in `TranscriptTextView.makeNSView` as a **subview of
  `HitTestingTextView`** (the document view). Being inside the document view, it
  scrolls with the text — no per-scroll geometry recompute.
- `frame = textView.bounds`, autoresizes width+height.
- Owns **one broad `NSTrackingArea`** over its bounds with
  `[.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow]`. On
  `cursorUpdate`/`mouseMoved` it runs the shared `handle(at:)` resolver: hit →
  `NSCursor.resizeLeftRight.set()`, miss → `NSCursor.arrow.set()`. One area, not
  one-per-edge, so dynamic layout can't desync the tracking areas.
- `hitTest(_:)` returns `self` **only** when the point falls in an edge zone;
  returns `nil` everywhere else, so word-click / shift-extend / drag-to-select on
  the `HitTestingTextView` beneath keep working. The resize zone deliberately
  "steals" drags inside its tight 6pt band — that is the whole feature.
- Drag lifecycle: `mouseDown` resolves the handle (else returns nil hit and lets
  the text view own it); a 6pt drag threshold before a resize actually begins;
  `mouseDragged` forwards the document-local point; `mouseUp` ends it.
- `viewWillMove(toWindow:)` with `newWindow == nil` mid-drag → cancel (mirrors
  `SeamStretchHandleLayer` / `crossfadeStretchCancelled`).

This mirrors the waveform's proven split (`WaveformResizeCursorLayer` +
`WaveformEdgeHandleLayer` + `SeamStretchHandleLayer`), cursor on the topmost
view so AppKit's frontmost-view cursor resolution can't be shadowed.

### Geometry (owned by `Coordinator`)

For each resizable item the coordinator computes start/end edge rects:

- Take the item's **true first and last word in transcript position order**
  (not ID order); a wrapped multi-line container gets a start handle only on its
  real first word and an end handle only on its real last word — wrap-open edges
  are visual continuations, not semantic edges.
- word `NSRange` (from `TranscriptDocument.wordRanges`) → glyph range →
  `layoutManager.boundingRect(forGlyphRange:in:)` → add `textContainerInset` →
  inflate ±6pt horizontally, full line height vertically.

Recompute zones only on: text change, font-size change, container-width/layout
change, `highlightedWordIDs` change, band/container change, or active-draft
change. (Plain scrolling needs no recompute.)

Published zone type:

```swift
struct TranscriptResizeHandleZone: Equatable {
  var item: TranscriptResizeItemIdentity
  var edge: TranscriptResizeEdge
  var rect: CGRect
  var priority: Int          // selection 3, clip 2, suggestion 1
}

enum TranscriptResizeItemIdentity: Equatable {
  case selection
  case clip(Slice.ID)
  case suggestion(CutSuggestion.ID)
}

enum TranscriptResizeEdge: Equatable { case start, end }
```

`handle(at:)` = zones whose `rect.contains(point)`, sorted by `priority` desc,
tie-broken by nearest edge-x, then deterministic identity order.

### Semantic vs drawn data (important)

Interaction uses **semantic item ranges**, not the drawn `clipBands`.
`clipBands` strips suggestion words already claimed by a clip (correct for
painting), which would make a partly-covered suggestion un-resizable. So
`EditorModel` exposes a separate `transcriptResizeItems: [TranscriptResizeItem]`
(identity, ordered `wordIDs`, kind/priority, committed word range, optional
drafted word range) pushed into `TranscriptPageModel` like `clipBands` — used
for handles/geometry. Drawing keeps using `clipBands`.

### Model ownership

`TranscriptPageModel` (gesture plumbing only):

```swift
var transcriptResizeItems: [TranscriptResizeItem]        // pushed in
var onTranscriptResizeBegan:  ((TranscriptResizeItemIdentity, TranscriptResizeEdge) -> Void)?
var onTranscriptResizeDragged: ((Word.ID) -> Void)?      // target word under pointer
var onTranscriptResizeEnded:   (() -> Void)?
var onTranscriptResizeCancelled: (() -> Void)?
```

`EditorModel` (state machine + mutation). One shared draft, behavior branched by
identity:

```swift
struct TranscriptResizeDraft: Equatable {
  var identity: TranscriptResizeItemIdentity
  var edge: TranscriptResizeEdge
  var originalWordIDs: [Word.ID]
  var draftedWordIDs: [Word.ID]
}
var transcriptResizeDraft: TranscriptResizeDraft?    // non-nil only during a drag
```

- **Selection** → Pattern A: update `audioSelection` to the exact whole-word
  source range every drag tick. Consistent with the transcript's existing
  drag-to-select, which already live-mutates `audioSelection`; a selection
  change only repaints highlight color and does not rebreak lines, so it is safe
  under the repo's "no reflow-triggering mutation mid-drag" rule.
- **Clip / Suggestion** → Pattern B: update only `transcriptResizeDraft` during
  the drag, preview the moved container in the transcript, and commit **once**
  on `mouseUp` through `mutateDocument` (single undo entry). Draft is dropped on
  cancel.

### Word-snap math

Mouse point → UTF-16 offset (existing TextKit hit test, but for a drag allow x
outside the line's used rect to resolve to the first/last word on that line) →
`Word.ID` via `TranscriptDocument.wordID(atUTF16Offset:)` → transcript **position
index**. Then clamp against the opposite edge:

- start edge: target ∈ `0...oppositeIndex` → words `target...opposite`
- end edge:   target ∈ `oppositeIndex...lastIndex` → words `opposite...target`

Minimum one word falls out of allowing equality but not crossing. Sample range
derives from the drafted words' first `startSample` / last `endSample`; skip the
tick if a bound is missing/invalid. Resolve by **position**, carry IDs (word IDs
are not guaranteed unique). Likely extract a small `WordBoundaryResolver` value
type (current `sourceRange(ofWord:)`-style helpers are private in `EditorModel`).

### Suggestion mutation (new)

Add `updatedSuggestion(_ suggestion:CutSuggestion, toWordIDs:) -> CutSuggestion`,
mirroring `updatedSlice`. It sets `wordIDs`, `startSample`, `endSample`,
`startSec`, `endSec`, `durationSec` **from the exact drafted words** — not
re-derived by audio overlap (overlap would pull in neighbors and make the edge
hop, contradicting D1). Commit:

```swift
mutateDocument { $0.cutSuggestions[id: id] = updatedSuggestion(s, toWordIDs: drafted) }
```

Only `.pending` suggestions are resizable.

### Clip mutation (existing path)

On end: derive sample range from drafted words →
`mutateSlices { $0[id: id] = updatedSlice(slice, to: range) }`; no-op if
unchanged.

## Error / edge handling

- Missing/invalid sample bounds on a drafted word → ignore that drag tick.
- Drag torn down mid-flight (tab switch, view removal) → cancel draft, restore.
- Empty selection / no items → no zones, overlay is inert (all `hitTest` → nil).
- Duplicate word IDs → position-first resolution keeps the target unambiguous
  for geometry; mutation carries the resolved contiguous run.

## Testing

Model-level (Swift Testing, `expectNoDifference`), no AppKit, no audio:

- Word-math: priority/order, min-one-word, no-cross, start vs end clamping.
- Selection resize updates `audioSelection` to exact word range (Pattern A).
- Clip resize: draft during drag leaves `slices` untouched; one commit on end;
  no-op when unchanged; single undo entry.
- Suggestion resize: `updatedSuggestion` sample/sec fields derived from words;
  only pending resizable; single undo entry; undo restores.
- Teardown cancellation drops the draft and restores committed state.
- Semantic-vs-drawn: a suggestion partly covered by a clip still exposes its full
  resize range.

Geometry/overlay (AppKit) verified manually per the roadmap's renderer pattern;
keep logic in testable model helpers so the AppKit layer stays a dumb forwarder.

## PR / commit order (single branch)

1. Semantic resize-item read models + `WordBoundaryResolver` word-math (pure, TDD).
2. Coordinator edge-zone geometry + cursor only (no mutation).
3. Overlay hit-test + drag lifecycle wired to no-op callbacks (proves it steals
   only edge-zone drags).
4. Selection resize (Pattern A).
5. Clip resize (Pattern B).
6. Suggestion resize (`updatedSuggestion` + Pattern B).
7. Teardown cancellation + regression tests.

If the cumulative diff outgrows a comfortably-reviewable single PR, split at the
selection/clip boundary and say so.

## Risks (ranked)

1. **Cursor ownership** — cursor must live on the topmost overlay or it fails
   intermittently (the waveform already hit this). Mitigation: overlay owns it.
2. **Reflow during drag** — committing a clip/suggestion per `mouseDragged`
   rebuilds containers and moves the target under the pointer. Mitigation:
   draft-only during drag, commit once.
3. **Semantic vs drawn suggestions** — using occluded `clipBands` as the
   interaction source makes covered suggestions un-resizable. Mitigation:
   separate `transcriptResizeItems`.
4. **Word-ID ambiguity** — IDs not guaranteed unique. Mitigation: resolve by
   transcript position, then carry IDs.
5. **Stealing existing drags** — resize zone overlaps drag-to-select. Mitigation:
   tight 6pt zone, `hitTest` → nil outside it.
