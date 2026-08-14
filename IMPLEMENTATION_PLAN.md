# Transcript clip-blocks — implementation plan

Reuse the tested clip model layer; build the inline block renderer. pfw skills invoked:
pfw-observable-models, pfw-modern-swiftui, pfw-testing, pfw-custom-dump.

## Stage 1: Model layer (fixes + block render data + block boundary actions)
**Goal**: EditorModel exposes block render data + absolute-word boundary actions; §7 fixes applied.
**Files**: FineTuneModel.swift (BoundarySnap.none → .exact), EditorModel.swift, new
Models/ClipBlockPresentation.swift, EditorClipBoundaryTests.swift (+ new tests).
**Success**: xcodebuild test green; new tests cover drag-to-word, click-inside pull, sync.
**Status**: Complete (641 tests + 8 new, green; lint + format clean; committed d39de9c)

### §7 fixes
- ⏎ un-rejects a rejected manual clip (`approveCurrentClip` `.manualSlice`).
- Approving an edited suggestion carries the live draft into the minted slice (guard `slices[id:]`).
- `selectClip` disarms point-and-add + clears live-draft link on clip change.
- `nextSliceNumber` seeds from the highest existing "Slice N".
- Rename `FineTuneModel.BoundarySnap.none` → `.exact`.

### New actions
- `clipBoundaryDragBegan(_:side:)` / `clipBoundaryDragged(toWordID:)` / `clipBoundaryDragEnded()` /
  `clipBoundaryDragCancelled()` — nearest-word edge drag, one undo entry (reuses funnel).
- `clipInteriorClicked(_:wordID:)` — select-if-not-current, else `pullClipBoundary` (nearer edge).
- `visibleClipBlocks` + `currentClipFooter`.

## Stage 2: Block renderer + view chrome
**Goal**: Inline blocks in the one TextKit NSTextView; rail/filters/clips-only/footer; wire actions.
**Files**: TranscriptTextView.swift, new ClipBlockLayoutManager.swift, TranscriptPageView.swift,
new ClipBlockUI.swift, TranscriptPageModel.swift (hover/drag adornment), EditorView.swift.
**Success**: xcodebuild test green; make lint + make format-check clean.
**Status**: Complete (641 tests green 6.4s; lint + format clean; committed 0d3ec5e)

## Stage 3: Codex review + challenge on the diff; fix findings; report.
**Status**: Not Started

## Stage 4: Decouple the block edge-drag from the model (fix lag + crash)
**Goal**: A block edge-drag is a pure view-only band preview during the drag (no model mutation, no
`applyBlocks`, no full-editor re-render); the edit commits to the model exactly once on mouse-up as
a single undo entry.
**Root cause**: every `mouseDragged` called `clipBoundaryDragged` → `fineTune.set{Start,End}`, a
per-move `@Observable` mutation that synchronously re-entered SwiftUI (`updateNSView` → `apply` +
`applyBlocks` + waveform/insets/cards) *while still inside the NSTextView's `mouseDragged`*. That
re-entrant `NSTextStorage` editing + layout during AppKit event dispatch is the crash/beachball; the
whole-editor re-render every word is the lag.
**Design**:
- EditorModel: remove `clipBoundaryDragBegan/Dragged/Ended/Cancelled` + `boundaryDragSide`/
  `boundaryDragStartRange`; add ONE atomic `commitClipBoundary(_:side:toWordID:)` that runs the
  existing begin → move → commit funnel as a single undo entry. Expose `canBeginBoundaryEdit` as a
  pure (non-mutating) query. Keyboard path (`moveCurrentClipBoundary`) + grip path unchanged.
- TranscriptTextView: on drag begin record clip id + fixed word (END → clip's first word fixed,
  START → last). Each move resolves `nearestWordID` and repaints a preview band by assigning
  `blockLayoutManager.blocks` directly (+ scoped white foreground on the previewed run) — no model
  call. Mouse-up calls `commitClipBoundary` once; Esc drops the preview with no commit.
- TranscriptBlockActions / EditorView: swap the 4 drag closures for `boundaryCommit` +
  `canBeginBoundaryEdit`.
**Tests** (EditorClipBoundaryTests): a view-only drag makes no model change until release; release
records exactly one undo entry; Esc (no commit) records none; commit refused when an unsaved edit is
held elsewhere.
**Success**: xcodebuild test green; make lint + make format-check clean.
**Codex review + challenge** (adversarial): fixed — bounds-clamp every preview range (band +
foreground) against the live storage extent; restored the mid-drag keyboard/nav guard via an
`@ObservationIgnored isBlockEdgeDragging` begin/end flag (no per-move coupling) so a ⌥-arrow or nav
key pressed mid-drag can't split the one undo entry; defensive `lastDraggedWordID` reset on mouse-down.
**Status**: Complete (646 tests green; lint + format clean)
