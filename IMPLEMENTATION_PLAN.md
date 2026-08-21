# Item ① — Edit Slice modal ⇄ main timeline parity (remove / crossfade / restore)

**Architecture (locked, Codex-confirmed): Option A.** The modal renders the slice on a
COLLAPSED (edited) lane using its OWN `EditedWaveformAdapter` that shares the parent's
source pyramid and the parent's GLOBAL `EditedTimeline` (kept in sync). Coordinates stay
GLOBAL throughout, so the modal reuses the parent's remove/restore/canRemove/normalize with
zero offset math. The one shared-adapter change is a `navigableEditedRange` viewport pin
(modeled on `WaveformModel.navigableRange`) that confines fit/zoom/scroll/columns to the
slice's edited extent.

Locked behavior (user): boundary trims keep deferred Save/Cancel; **removals apply
immediately and are ⌘Z-undoable**; Cancel reverts only the trim, not removals. A marquee
crossing an existing removal produces ONE larger merged removal.

**Merge semantics (corrected after Codex consult, user chose full parity):** `TimelineRemovals.normalize`
does NOT merge — it rejects overlaps. The merge is an explicit funnel `removeSourceRange(_:)` on
`EditorModel`: given a SOURCE range, it absorbs every existing removal the range overlaps into ONE
union removal `min(lower)..<max(upper)`, carrying the default crossfade (absorbed crossfades were
internal to still-removed audio, no longer audible). **Both** the main timeline and the modal route
Remove through this one funnel, so cross-seam behavior is identical (user: "the modal is just a
truncated version of the full wave; editing main edits the clip"). `canRemove` therefore no longer
rejects cross-seam — it only rejects empty ranges. Known edge (manual-verify): a marquee that STARTS
inside a crossfade overlap zone can map both endpoints to one side of the seam and not absorb it;
the common case (endpoints in kept audio either side of the seam) merges correctly.

Do NOT touch the Python engine.

---

## Stage 1: `navigableEditedRange` viewport pin on `EditedWaveformAdapter`
**Goal**: The shared adapter can be confined to a sub-range of the edited axis; nil pin =
whole edited timeline (main editor unchanged).
**Changes**: `EditedWaveformAdapter.swift` — add `navigableEditedRange: Range<Int>?` +
private `navigableRange` computed getter + `setNavigableEditedRange(_:)`. Replace
`axis: 0..<editedDurationSamples` with `axis: navigableRange` in every viewport helper
(fit/min/clamp/zoom/zoomByFactor/zoomToFitEdited/zoom(by:)/clampedStart). Gate
`hasUsableGeometry` and the zoom/fit/clamp guards on `!navigableRange.isEmpty`. Clamp
`visibleColumns` pixel reads and `xToEditedSample` to `navigableRange`. Clamp
`zoomToFitEdited`'s requested range to `navigableRange`. `zoomToFitAllEdited` starts at
`navigableRange.lowerBound`. `setNavigableEditedRange` clears `fitRestore` + re-clamps.
**Success**: existing `EditedWaveformAdapterTests` all pass unchanged (nil pin == today).
New tests: pin clamps fit/scroll/zoom to the sub-range; empty pin ⇒ `hasUsableGeometry`
false; changing the pin clears `fitRestore`.
**Status**: Complete — 24/24 `EditedWaveformAdapterTests` pass (4 new), full suite green.

## Stage 2: Modal owns a collapsed `editedWaveform` adapter
**Goal**: The modal's lane renders the collapsed slice, not the source-pure waveform.
**Changes**: `EditSliceModel.swift` — add `let editedWaveform: EditedWaveformAdapter`
(`source: waveform`, timeline seeded by parent), pin to the slice's edited span; keep
`waveform` (source-pure) for the fine-tune insets/amplitude. Re-point zoom in/out/fit and
`playheadX`/highlight/geometry helpers to `editedWaveform`. Cursor stored as GLOBAL source
sample; rendered via `timeline.sourceToEdited`. `EditSliceView.swift` — mount the lane on
`model.editedWaveform`; amplitude button stays on `model.waveform`.
**Success**: modal shows the collapsed slice with any existing removals visible; zoom/scroll
confined to the slice; insets unchanged. Model tests for the new geometry/cursor mapping.
**Status**: Complete — modal lane now renders `editedWaveform` (source-pinned to the slice);
32 `EditSliceTests` pass; full suite 1019 green.

## Stage 3: Parent ⇄ modal timeline sync
**Goal**: A removal/undo/redo on either surface reflects on the other immediately.
**Changes**: `EditorModel.editSliceTapped` seeds `child.editedWaveform.timeline` + pin.
`syncEditedTimeline()` fans the new timeline + recomputed pin + `timelineChanged()` into an
open `editSlice?.editedWaveform`. Draft-trim changes recompute the pin locally in the modal.
**Success**: open modal, remove on main timeline ⇒ modal updates; remove in modal ⇒ main
updates; undo reflects in both. Tests via `withDependencies`.
**Status**: Complete — `EditorModel.editSliceTapped` seeds `child.syncTimeline(editedTimeline)`
on open; `syncEditedTimeline` fans every removal/undo/redo into `editSlice?.syncTimeline`,
which sets the shared timeline and re-pins to the slice's new edited extent. `syncTimeline`
re-clamps the lane (a removal inside the slice collapses its span → fit re-clamps) and the
source-anchored cursor remaps live. 3 new tests (2 `EditSliceTests` sync/cursor, 1
`EditorEditSlicePresentationTests` parent-removal-fans-in + undo); full suite 1022 green.
(Remove-in-modal ⇒ main is Stage 4, when the modal grows marquee/remove handlers.)

## Stage 4: Modal marquee → remove / crossfade / restore (routed to parent)
**Goal**: Marquee-select + Remove + Restore inside the modal, one undo step, synced.
**Changes**: `EditSliceView` — wire `onAreaSelect*`, `seams`, `onContextMenu` (were inert).
`EditSliceModel` — modal-local marquee selection state + handlers (mirror parent, clamp to
`overviewWindow`), `seamOverlays`/`seamID(atX:)` from the shared timeline, and
`onRemoveSection(Range<Int>) async`/`onRestore(TimelineRemoval.ID)` callbacks. Wire in
`editSliceTapped` to the parent's `removeSourceRange`/`restoreRemoval` funnel.
Merge-larger-removal is the shared `removeSourceRange` funnel (Stage 4a).

**Stage 4a (main-editor parity, DONE first): extract the merge funnel.** `canRemove` allows
cross-seam (rejects only empty). New `removeSourceRange(_:)` absorbs overlapped removals into one
union removal (default crossfade). `removeSelectedSectionTapped` routes through it. Rewrite
`EditorRemovalTests.canRemoveRejectsCrossSeamAndEmptySelections` → allows cross-seam; add a
merge-behavior test.
**Success**: modal marquee across an existing removal ⇒ one merged removal; Restore on a seam
reopens it; each is a single ⌘Z. Tests.
**Status**: Complete. Stage 4a: `canRemove` allows cross-seam; `removeSourceRange` merge funnel;
`removeSelectedSectionTapped` routes through it; `EditorRemovalTests` 31 pass (rewrote the
cross-seam test + added a union-merge/undo test). Stage 4b: `EditSliceModel` grew marquee state +
handlers (`waveformAreaSelectBegan/Changed/Ended`, `updateMarqueeSelection`, `clampedToWindow`),
`removeSelectionTapped`, `seamOverlays`/`seamID(atX:)`/`waveformContextMenuItems(atX:)`,
`selectSeam`, and `onRemoveSection`/`onRestore` callbacks. `EditSliceView` wires `onAreaSelect*`,
`seams`, `onContextMenu`, and a Remove button. `EditorModel.editSliceTapped` points the callbacks at
`removeSourceRange`/`restoreRemoval`. 9 new `EditSliceTests` (41 total) + 1 integration test in
`EditorEditSlicePresentationTests` (modal marquee across a seam ⇒ one merged removal, single ⌘Z,
Restore reopens). All green.

## Stage 5: Modal playback matches the collapsed view
**Goal**: Play in the modal previews the edited (collapsed) audio, so what you hear matches
what you see.
**Changes**: route modal `onPlay` through the slice render plan (respecting removals) instead
of raw `.sourceRange`. Confirm the `.sliceEdit` transport context + cursor mapping hold.
**Success**: with a removal inside the slice, modal Play skips the removed span. Tests.
**Status**: Complete. The modal's `onPlay` now begins `.slice(range)` (was `.sourceRange`), routing
through the existing slice-local render-plan path (`resolvedTransportPlayback`/`SlicePlaybackPlaylist`)
that skips removals and blends seams — degrading to the plain source range when no removal intersects.
2 new `EditorSlicePlaybackTests` (modal play crossing a removal previews the render plan; a
removal-free slice keeps the raw source range). All green.

## Stage 6: Codex adversarial review + polish
Codex review + challenge on the full diff; fix findings; `make format-check`, `make lint`,
`make test-fast`; commit incrementally.
**Status**: Complete.
- Codex `review`: two P1s, both verified against the code and fixed —
  (1) ⌘Z/⌘⇧Z were un-undoable from inside the sheet (the main editor's shortcut lives on a
  non-key window) → `SliceEditKeyMonitor` now classifies ⌘Z/⌘⇧Z and forwards to
  `EditSliceModel.undo/redoTapped` → parent `onUndo/onRedo`; (2) `pinnedEditedRange` bracketed
  the overview window with swapped endpoint biases, dropping the crossfade tail or inverting to
  a whole-project fallback → new `EditedTimeline.editedFootprint(ofSource:)` (kept-segment union)
  replaces it.
- Codex `challenge` (round 1): no new P1. Fixed 3 of its 4 findings:
  (P2) ⌘Z undoing a slice's own creation left an orphaned sheet → `reconcilePlayback` closes
  `editSlice` when its slice is gone; (P2) undo ignored an unsaved modal draft →
  `hasUncommittedSliceEdit` now also gates on `editSlice?.fineTune.hasUnsavedChange`, blocking
  ⌘Z under a live modal draft exactly as a docked draft does; (P3) `span(forSource:)` used the
  same endpoint bracketing → routed through `editedFootprint` so the highlight keeps the
  crossfade tail. Regression tests added for all three.
- Codex `challenge` (round 2, on the applied fixes): no new P1. Two follow-ups, both fixed:
  (P2) the orphan-close only caught a DELETED slice — undoing a saved BOUNDARY edit left the
  slice alive but reverted while the modal's committed range (seeded once at open) went stale, so
  a later Save would recommit it → the close guard now also fires when the surviving slice's range
  no longer matches `editSlice.fineTune.committedRange` (`editSliceRangeIsStale`); a modal removal
  never trips it (it doesn't touch the slice's own bounds). (P3) `zoomToFitSource` still bracketed
  via `editedRange(forSource:)`, so `Z` fit a narrower range than the footprint highlight → that
  private helper now routes through `editedFootprint` too. Regression test added for the
  boundary-edit-undo close.
- Deferred (out of Item ①/③ scope): the challenge's remaining P2 — live slice audition does not
  yet apply the export-side 15 ms boundary `DeclickFade` (`AudioPlayerClient` plays raw
  `.sourceRange`), so audition can still click where the exported AIFF won't. This is the
  pre-existing "wire DeclickFade into live audition" follow-up; export parity for the rendered
  file is unaffected. Tracked separately.
- Full suite 1048 green (+4: 3 undo-edge tests, 1 crossfade-footprint span test); format-check
  and lint clean.
