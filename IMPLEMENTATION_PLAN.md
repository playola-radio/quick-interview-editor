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
- `syncEditedTimeline` drops a `selectedSeamID` whose seam no longer renders (undo/redo/restore).

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

### Stage 7: Green + format/lint + Codex review/challenge + PR + /fix-review.

## Status — Stages 1–6 COMPLETE
- 24 tests in `EditorSeamSelectionTests` + 2 escape-key tests in `EditorKeyMonitorTests`; full
  suite 952 tests pass. `make format-check` + `make lint` clean.
- Stage 7: pending Codex review/challenge, PR, /fix-review.

## Interface parity note
Logic: clicking a crossfade selects it (no playhead move); Delete on a selected crossfade removes
the fade. "Restore removed audio" has no direct Logic counterpart (Logic has no destructive
region-removal-with-restore); modeled as a deliberate app concept.
