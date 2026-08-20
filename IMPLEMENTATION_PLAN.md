# PR 4 — Seam selection + Restore Removed Audio

Branch: `briankeane/crossfade-live-transport` (continues the crossfade completion feature).
Plan source: `docs/superpowers/plans/2026-08-20-remove-section-crossfade-completion.md` §PR 4.

## Locked design (decision 6)

- `selectedSeamID: TimelineRemoval.ID?` on `EditorModel`, mutually exclusive with `audioSelection`.
- Click bowtie selects; ⌫ restores the selected removal; context menu + inspector button
  "Restore Removed Audio"; Escape deselects.
- All document mutation through `mutateDocument` (undo + sidecar + playback reconcile for free).
- Playback reconciliation for a restore rides the existing `syncEditedTimeline` source-anchor remap.
- View stays logic-free: hit-testing + all copy live on the model.

## Stages

### Stage 1: Seam selection state + mutual exclusion — DONE-when tests green

- `selectedSeamID`; `selectSeam(_:)` / `seamClicked(_:)`; `deselectSeam()`.
- Mutual exclusion: range writes clear the seam; selecting a seam clears the range.
- `syncEditedTimeline` drops a `selectedSeamID` whose removal no longer exists (undo/redo/restore);
  an off-screen seam whose removal still exists is preserved.

### Stage 2: Restore + updateCrossfade model API

- `restoreRemoval(id:)`, `restoreRemovalTapped()` (selected), `updateCrossfade(id:_:)` — all
  through `mutateDocument`. Undoable + persisted.

### Stage 3: Hit-testing + selected overlay

- `seamID(atX:)`; integrate into `waveformClicked`; `seamContextMenuItems(atX:)`.
- `SeamOverlay { id, span, isSelected }`; `seamOverlays`; selected visual in `SeamBowtieOverlay`.

### Stage 4: Delete-key arbitration + Escape

- `EditorKey.escape`; `editorKeyDown` arbitration (seam → restore; else remove-section path; else false).

### Stage 5: Playback reconciliation regression test

- Restore mid free-playback → cursor stays on the same SOURCE moment; stale playlist stops.

### Stage 6: View wiring

- MarkClipBar "Restore Removed Audio" button (model-decided visibility/enablement).
- `WaveformView`/`WaveformLaneView` seam overlays + AppKit context menu via `menu(for:)`.

### Stage 7: Green + format/lint + Codex review/challenge + PR + /fix-review

## Status — Stages 1–7 (in progress)
- 27 tests in `EditorSeamSelectionTests` + 2 escape-key tests in `EditorKeyMonitorTests`; full
  suite 956 tests pass. `make format-check` + `make lint` clean.
- Codex review fix (commit d76c7b6): hard-cut (zero-length) seams now render a zero-width bowtie
  marker so they stay selectable/restorable rather than becoming an invisible dead-end.
- Codex challenge remediation (commit 3be0839):
  - `seamID(atX:)` resolves to the nearest bowtie center among overlapping widened targets, so
    abutting/close seams no longer let the earlier one shadow the later. Regression test added.
  - Edge-handle layer forwards `menu(for:)` to a shared `waveformContextMenu` builder, so a
    right-click on a bowtie hugging a selection edge stays restorable.
  - `selectSeam` documents leaving fine-tune reconciliation to the centralized `syncEditSession`
    (matches `selectSourceRange`; avoids the unsaved-slice hazard).
- Stage 7 remaining: Codex challenge re-run (fixes were non-trivial), manual verify, PR, /fix-review.

## Interface parity note
Logic: clicking a crossfade selects it (no playhead move); Delete on a selected crossfade removes
the fade. "Restore removed audio" has no direct Logic counterpart (Logic has no destructive
region-removal-with-restore); modeled as a deliberate app concept.
