# Slice Detail Edit Modal — Design

**Date:** 2026-08-18
**Branch:** `briankeane/slice-detail-edit-panel`
**Status:** Approved direction (Option B), pending plan

## Problem

The boundary fine-tune pane (`FineTuneView` + `FineTuneModel`) was pulled from the
UI because it mounted **inline** in the main editor's left column and popped in/out
on selection, reflowing the main waveform + transcript ("jumping all over the
place"). The model, geometry, and all cut-editing logic still exist in the tree —
only the mounting was removed (commits `f5e29bc`, `a6cfa82`).

We want boundary editing back **without** the main surface ever moving.

## Decision

Re-add it as a **focused slice-detail modal** (a SwiftUI `.sheet`), not as an
in-panel widget. A sheet isolates layout by construction — the main editor is
frozen behind it and cannot reflow. This also matches Logic Pro's idiom (a region
opens a focused editor, distinct from the arrangement) and gives room for the full
context the narrow 302px right panel cannot. (Rejected: insets in the right panel —
relocates the jumpiness into the panel and is cramped; popover/disclosure/drawer —
same reflow or too small for precision work. Second opinion via Codex concurred.)

## User-confirmed behavior

1. **Contents:** an **overview** (slice-only waveform + slice-only transcript, same
   top-transcript / bottom-waveform layout as the main window) **plus** the two
   zoomed edge insets ("Cut in ▸" / "◂ Cut out") — the insets are the drag/nudge
   surface, exactly as before.
2. **Opening:** **both** double-click a slice card **and** a dedicated "Edit" button
   on each slice card in the Slices panel.
3. **Overview waveform scope:** exactly the slice range, edge-to-edge. Out-of-bounds
   context is the insets' job (each is a fixed ±0.5 s window around its boundary).
4. **Playback:** full transport inside the modal — play / pause / stop / click-to-seek,
   scoped to the slice.

## Architecture

New page trio, colocated per project convention:

```
Views/Pages/Editor/EditSlice/
├── EditSliceModel.swift   # @Observable model — owns the edit session
├── EditSliceView.swift    # the sheet — visuals only
└── EditSliceTests.swift   # Swift Testing suite
```

### `EditSliceModel` (new)

`@MainActor @Observable`, inherits `ViewModel`, and `Identifiable` so it can back
`.sheet(item:)` (the model instance *is* the sheet identity, mirroring the existing
`SettingsModel` key-entry sheet pattern).

Owns:
- `let sliceID: Slice.ID` and the slice's opening range.
- **Its own `FineTuneModel`** instance, constructed with the plan's `sampleRate`,
  `durationSamples`, `silences`. On init it calls
  `fineTune.begin(target: .slice(sliceID), range: slice.startSample..<slice.endSample)`.
  All drag/nudge/snap/safe-zone/warning logic is reused as-is; the modal does not
  reimplement any of it. It forwards `cutInDragged` / `cutOutDragged` /
  `cutInNudged` / `cutOutNudged` to the `FineTuneModel`.
- **Overview waveform columns:** the slice range rendered edge-to-edge via the
  existing `WaveformModel.columns(in:pixelWidth:)` (the same primitive the insets
  use). This does **not** touch the main viewport's zoom/scroll — it's a pure
  windowed render. The window is the committed slice range, fixed for the session;
  the live draft cut lines draw as overlays where they fall.
- **Inset columns:** `fineTune.cutInWindow` / `cutOutWindow` fed to
  `columns(in:pixelWidth: fineTune.insetWidthPixels)` (identical to
  `EditorModel.cutInColumns` / `cutOutColumns`, which we mirror).
- **Scoped transcript:** a `TranscriptPageModel` built from a **filtered `EditPlan`**
  containing only the slice's words (`editPlan.words` filtered by `slice.wordIDs`),
  reusing `TranscriptPageView` / `TranscriptTextView` unchanged. Sample coordinates
  and `Word.ID`s stay **global** (we filter, we do not remap) — so identity maps
  straight back to the real slice. The scoped transcript is **read-oriented**
  context: it shows the slice's words and the current-word highlight during
  playback. It is built **once at open** from the committed slice and does **not**
  reflow per drag frame (see "Boundary changes and word set" below).
- **Transport delegation:** the modal drives the app's **one global transport**, not
  a private player. It calls back into `EditorModel` via injected closures (the same
  dependency-injection style as `CutSuggestionsPageModel.onAcceptSlice`):
  - `onPlayDraft: (Range<Int>) async -> Void` → `EditorModel.beginTransportPlayback(range:context: .sliceEdit)`
  - `onPause`, `onStop`, `onSeek: (Int) async -> Void`
  - a way to read the live playhead sample + phase (pass `EditorModel`'s
    `transportPhase` / cursor through, or a small observed projection).
  Reusing the existing session/superseding/token machinery avoids duplicating the
  fragile global-player logic. Opening the modal supersedes any main playback (one
  player), which is the desired behavior.
- **Commit / cancel:**
  - `saveTapped()` → calls injected `onCommit: (Slice.ID, Range<Int>) -> Void`, then
    requests dismissal. `EditorModel.onCommit` reuses its existing commit logic:
    `mutateSlices { $0[id:] = updatedSlice(slice, to: draft) }`, which recomputes
    `wordIDs` via `wordIDs(overlapping:words:)` and pushes one undo entry.
  - `cancelTapped()` → drop the draft (no mutation), request dismissal.
  - Save is enabled only when `fineTune.hasUnsavedChange`.

### `EditSliceView` (new)

Pure visuals. Vertical layout mirroring the main window:
- Title / slice name at top.
- Scoped `TranscriptPageView` (read-oriented).
- Divider.
- Overview `WaveformView`-style band for the slice (edge-to-edge) with playhead +
  draft cut-line overlays.
- The two zoomed edge insets (reuse `FineTuneView`, or its `BoundaryInset`
  sub-views) — the drag/nudge surface, with the existing ±10 ms buttons, red cut
  line, silence safe-zone shading, tight-cut reddening.
- Transport controls (play/pause/stop) + Save / Cancel.

Zero logic in the view — every string, flag, and derived value comes from
`EditSliceModel` (which largely re-exposes `FineTuneModel`'s existing display text:
`cutInLabel`, `helperText`, `commitLabel`, `cancelLabel`, time readouts, etc.).

### `EditorModel` integration (small additions)

- `var editSlice: EditSliceModel?` — nil = closed; set non-nil = present the sheet.
- `func editSliceTapped(_ id: Slice.ID)` — builds an `EditSliceModel` for the slice,
  wires the `onCommit` / transport closures, assigns `editSlice`. Guard against
  opening while a dormant `fineTune` session has an unsaved change (there is none in
  normal flow now, but keep the invariant).
- Factor the existing slice-commit body (lines ~1173-1178, `updatedSlice` +
  `mutateSlices` + undo) into a reusable `commitSliceEdit(id:, range:)` the modal's
  `onCommit` calls. The inline `commitEditTapped` path can call the same helper.
- Add a `.sliceEdit` case to `TransportContext` (so slice rows don't false-highlight
  while the modal previews), parallel to `.draftPreview`.

### `SlicesPanelView` / `SliceCard` (small additions)

- Re-add an **"Edit"** button to each slice card → `model.editSliceTapped(id)`.
  (The old "Edit cuts" button was removed in `a6cfa82`; this restores an entry
  point, now pointing at the modal.)
- Add a **double-click** gesture on the card → same `editSliceTapped(id)`.
- `.sheet(item: $model.editSlice) { EditSliceView(model: $0) }` on the editor view
  (or the panel), following the established `.sheet(item:)` precedent.

## Boundary changes and word set (deliberate simplification)

While dragging, the **draft range** changes but the scoped transcript's word set is
**not** re-derived per frame — it stays the committed slice's words for the life of
the session. Rationale:
- Per-frame rebuild of the `TranscriptDocument` would be expensive and visually
  jumpy, and mutating an `@Observable` every `mouseDragged` risks SwiftUI reentrancy
  (see the project's "drag = view-only preview" learning).
- The authoritative `wordIDs` recompute already happens on **Save**, inside
  `updatedSlice` via `wordIDs(overlapping:)`. So the saved slice always has the
  correct word set for its final range; the in-session transcript is context only.

The overview waveform likewise uses a **fixed** committed-range window for the
session (matching `FineTuneModel`'s fixed-window invariant); draft cut lines move
within it, and the zoomed insets provide the out-of-bounds view.

## Testing

Model-only (view holds no logic), Swift Testing, `expectNoDifference`, `@Shared`
declared locally per test, engine mocked via fixtures — no subprocess/audio.

- Opening builds a session on the slice's committed range; `fineTune.target` ==
  `.slice(id)`, draft == committed.
- Drag / nudge mutate the draft only; `slices` untouched until Save.
- `saveTapped` invokes `onCommit` with the draft range exactly once; `cancelTapped`
  does not.
- Save enabled only when `hasUnsavedChange`.
- `EditorModel.editSliceTapped` presents the sheet (sets `editSlice`), and
  `commitSliceEdit(id:range:)` recomputes `wordIDs` + pushes one undo entry (assert
  via `expectDifference` on `slices` / undo depth).
- Transport closures are invoked with the draft range (inject spies; no real player).
- Scoped transcript contains exactly the slice's words.

## Out of scope (YAGNI for v1)

- Editing a slice's word set directly in the modal (add/remove words) — boundaries
  only; word set follows the range on Save.
- Multi-slice editing / navigating between slices inside one modal.
- Re-enabling the old inline pending-selection fine-tune path (the modal is for
  existing slices; new slices are still created from a transcript selection).

## Files

**New:** `EditSliceModel.swift`, `EditSliceView.swift`, `EditSliceTests.swift`
(under `Views/Pages/Editor/EditSlice/`).
**Edited:** `EditorModel.swift` (present/commit/transport wiring, `TransportContext`
case), `SlicesPanelView.swift` (Edit button + double-click), the editor view that
owns the sheet. XcodeGen project regen for the new files.
**Reused unchanged:** `FineTuneModel`, `FineTuneGeometry`, `FineTuneView` /
`BoundaryInset`, `WaveformModel.columns(in:pixelWidth:)`, `TranscriptPageView` /
`TranscriptTextView` / `TranscriptPageModel`, the transport stack.
