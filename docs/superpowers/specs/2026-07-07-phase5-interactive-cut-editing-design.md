# Design: Phase 5 — Interactive cut editing ("drag the cuts")

**Status:** approved (brainstorm); ready for implementation plan
**Date:** 2026-07-07
**Depends on:** `plans/roadmap-macos-app.md` (Phase 5 + decision 4), `plans/STATUS.md`,
the Phase 4 waveform design (`docs/superpowers/specs/2026-07-07-phase4-waveform-sync-design.md`),
`ux-prototype/README.md` (the Selection / fine-tune panel with two magnified boundary insets),
and `CLAUDE.md`.
**Architecture reviewed with Codex** (consult, session `019f3e58`).

## Goal

Let the user adjust a slice's cut points precisely on the waveform: two magnified
boundary insets ("Cut in" = slice start, "Cut out" = slice end), each with a
draggable cut line + ±10 ms nudges, **magnetically snapping to the silence regions
the engine detected**, with **live red** when a cut has no silent gap, and
**undo/redo** over slice edits. Cut points become **sample-native** (no longer tied
to word edges). Built on a **single canonical AIFF** so a dragged cut lands exactly
where the engine renders.

## Product decisions (settled in brainstorming — build to these)

1. **Canonical AIFF first**, as a small precursor PR (roadmap decision 4).
2. **Select-then-edit**; cut points are sample-native; snippet/wordIDs re-derived for
   display. One slice active at a time.
3. The prototype's **two-inset fine-tune pane is the precise-drag surface**, extended
   with magnetic snap-to-silence, safe-zone shading, and live red.
4. **Undo/redo over all slice-list mutations** (add/delete/rename/reorder + each
   committed cut-edit), one gesture-coalesced entry per action; single stack over
   `slices`.
5. **No new engine revalidation on export** (YAGNI): `render` already validates ranges
   and filters markers; Swift owns live warnings from the cached silences.

---

# PR 1 — Canonical AIFF foundation

**One canonical PCM AIFF at plan rate backs playback, waveform, and render**, so
every coordinate is a canonical sample and the Phase-4 playhead-vs-pyramid drift
(three independent native→plan resamples) closes.

### Engine (`logic_markers/cli.py`)

`plan` **already** writes `<work-dir>/<stem>.plan.aiff` via
`convert_to_aiff(source, aiff_path, sample_rate)` (cli.py:302-303) — it is discarded
when the work dir is cleaned up. Changes:

- `plan`: keep that AIFF; derive `source.sampleRate` / `channels` / `durationSamples`
  in `edit-plan.json` from the **canonical AIFF bytes** (verify its `COMM` rate equals
  the requested plan rate; fail loud on mismatch). The plan JSON already goes to stdout;
  the AIFF's path is conveyed to Swift by the work-dir contract (below), not a new JSON
  field the app parses out of stdout — but the plan step must leave the file on disk.
- `render`: **stop reconverting.** Today it does `convert_to_aiff(source, render.aiff,
  req_rate)` (cli.py:362-363). When the request's audio input is the canonical AIFF at
  `req_rate`, verify its `COMM` rate + frame count and slice it directly. (If keeping the
  original source as render input, the trust problem is not fixed — so render must take
  the canonical file.)

### Swift

- `LiveEngine.transcribe`: it currently `defer`s deletion of the work dir. Before that
  deletion, **copy `<stem>.plan.aiff` into an app-owned cache**, then delete the engine
  scratch dir. Cache path:
  `Caches/Quick Interview Editor/Canonical/<jobID>/canonical.aiff` — derived data, large,
  rebuildable (Caches, not Application Support). Lifecycle: created during transcription,
  owned by the song tab/editor, deleted on tab close; **prune stale canonical dirs at app
  launch**.
- New value passed on completion:
  ```swift
  struct TranscriptionResult: Equatable, Sendable {
    var editPlan: EditPlan
    var canonicalAudioURL: URL
  }
  enum EngineEvent { case progress(EngineProgress); case completed(TranscriptionResult) }
  ```
- `EditorModel` carries `let canonicalAudioURL: URL` and uses it for **`loadWaveform`,
  `playSliceTapped`, and `renderRequest`** (replacing `sourceURL` for audio I/O; the
  original `sourceURL` stays only for the export filename stem).
- `render` request's `sourceURL` becomes the canonical URL.

**No drag UI in this PR.** Success = the same canonical file path is used by waveform,
playback, and render; playhead sits exactly on the pyramid.

### PR 1 tests

- Engine: `plan` emits source metadata from the canonical AIFF; the canonical AIFF exists
  and its rate matches; `render` slices a canonical AIFF without reconversion; range/marker
  behavior unchanged (existing pytest still green).
- Swift: `EngineClient.transcribe` completion carries a `canonicalAudioURL`; `EditorModel`
  passes the canonical URL to `waveform.load`, `audioPlayer.play`, and the render request
  (assert via recording test doubles; no audio/subprocess).

---

# PR 2 — Undo/redo over existing slice mutations

Ships value on its own and de-risks the stack before drag lands.

- Generic value type:
  ```swift
  struct UndoStack<State: Equatable> {
    private(set) var undo: [State] = []
    private(set) var redo: [State] = []
    var limit = 30
    mutating func record(before old: State, after new: State)  // no-op if old == new; clears redo
    mutating func undo(current: State) -> State?
    mutating func redo(current: State) -> State?
  }
  ```
- `EditorModel` holds `var sliceUndo = UndoStack<IdentifiedArrayOf<Slice>>()`. **Every**
  slice mutation routes through one helper:
  ```swift
  func mutateSlices(_ body: (inout IdentifiedArrayOf<Slice>) -> Void) {
    let old = slices; body(&slices); sliceUndo.record(before: old, after: slices)
  }
  ```
  `addSliceTapped` / `deleteSlice` / `renameSlice` / `moveSlices` are rewritten through it.
- `undoTapped` / `redoTapped` restore snapshots; `canUndo` / `canRedo` drive the buttons.
- **Undo stores only `slices`** — never `activeSliceID`, draft state, zoom, selection,
  export phase, or playback. After undo/redo, **reconcile**: if `activeSliceID` (see PR 3)
  no longer exists, clear it and any fine-tune target; stop playback if a now-absent slice
  was playing.
- Redo is cleared on any new `record`; further edits after an undo truncate the redo branch.

### PR 2 tests

- `UndoStack`: record/undo/redo round-trips; no-op record when unchanged; redo cleared on
  new record; `limit` eviction.
- `EditorModel`: add→undo removes it; delete→undo restores; rename/reorder→undo; redo after
  undo; reconcile a deleted active/playing slice after undo.

---

# PR 3 — Fine-tune drag editing

### Pure helpers (unit-tested first, no UI)

- `nearestSilenceEdge(sample:thresholdSamples:silences:) -> Int?` — nearest
  `silence.startSample` / `silence.endSample` within threshold (compared in **samples**,
  not ms).
- `sliceWarnings(...)` (existing) drives red — **clean when the cut sample lies anywhere
  inside a silence interval**, inclusive, as today.
- `wordIDs(overlapping range: Range<Int>, words:) -> [Word.ID]` — a word is **in** the
  slice if its **midpoint** falls in `[start, end)` (least-surprising vs pure-overlap /
  fully-contained). `snippet(for:words:)` re-derives the quoted snippet.
- `clampedBoundary(...)` enforcing `0 ≤ start < end ≤ durationSamples` and a minimum slice
  duration.

### `FineTuneModel` (`@Observable` child of `EditorModel`, sibling to `WaveformModel`)

Owns, in canonical samples:

- `var target: Target?` where `enum Target { case pendingSelection; case slice(Slice.ID) }`
- `var draftRange: Range<Int>?`
- per-boundary inset geometry: fixed samples-per-pixel ±0.5 s window (blank/clipped outside
  the file — do **not** rescale per boundary), inset-x ↔ sample transforms
- snap lookup + ±10 ms nudge math (ms→samples once, documented rounding: `.rounded()` for
  nudge deltas, floor for x→sample, clamp after snap)
- draft warnings (`tightStart` / `tightEnd`) and safe-zone spans (full silence interval
  clipped to the inset window)

It **never mutates `slices`.** It produces a draft; `EditorModel` commits.

### `EditorModel` glue

- New `var activeSliceID: Slice.ID?` (distinct from `playingSliceID`). Clicking a slice
  card or its waveform region makes it active and opens the pane bound to `.slice(id)`;
  a live transcript selection binds the pane to `.pendingSelection`.
- `var activeEditingRange: Range<Int>? { fineTune.draftRange ?? activeOrSelectedRange }` —
  the main Phase-4 waveform overlay reads this, so it tracks the in-progress drag; the
  waveform doesn't know whether the range is pending, slice-backed, or dragging.
- **Edit session (gesture coalescing):** `beginEdit` snapshots; drag updates only
  `fineTune.draftRange`; `commitEdit` applies **one** `mutateSlices` (one undo entry) and
  re-derives `wordIDs`/`snippet`; `cancelEdit` drops the draft. A drag = one entry; nudges
  are discrete unless inside an explicit session. Never infer coalescing from timing.
- Active-slice deletion mid-edit clears `activeSliceID`, the fine-tune target, and the draft.

### Behavior defaults

- **Export is disabled while an existing slice has an uncommitted draft** (commit or cancel
  first).
- Slices-panel **Play uses the committed range**; the fine-tune pane has its own **"preview
  edit"** that plays `draftRange`.

### Views (dumb)

Two inset cards (Cut in / Cut out): waveform slice from the model's columns, draggable cut
line, safe-zone shading, red state, ±10 ms buttons, preview-edit, commit/cancel — all copy
and geometry from the model; the view forwards gestures and pixels only.

### PR 3 tests

- Snap/range/word helpers: nearest edge within/outside threshold; clean-inside-silence vs
  snapped-edge distinction; midpoint word membership; clamp + min duration; ms→sample
  rounding.
- `FineTuneModel`: drafting from a pending selection and from an active slice; nudge and
  drag update `draftRange`; live warnings; safe-zone spans; outside-file inset windows.
- `EditorModel`: `commitEdit` = one undo entry with re-derived wordIDs/snippet; `cancelEdit`
  restores; active-slice deletion clears draft; export disabled during draft; preview-edit
  plays `draftRange`.
- All with synthetic plan + silences; no audio/subprocess.

---

## Traps (from the Codex consult — do not rediscover)

- **Snap edge vs red-inside are different predicates, on purpose.** Magnet → nearest silence
  edge; red → `sliceWarnings` (clean anywhere inside silence). If red meant "not snapped to
  an edge," users would see false danger inside safe silence.
- **Integer samples throughout.** Convert ms→samples once; compare snap threshold in samples.
- **Inset windows:** fixed samples-per-pixel; clip outside-file regions rather than rescaling.
- **Word membership** must be redefined (midpoint) — old `wordIDs` go stale under arbitrary
  cuts.
- **Per-frame drag never touches `slices`** — only `draftRange`; commit once.
- **Active-slice lifecycle:** ID-based; clear target/draft on delete; survives rename/reorder.
- **Playback while mid-drag:** committed range for panel Play, `draftRange` for preview-edit —
  pick one per surface; don't leave it ambiguous.
- **Canonical rate mismatch:** if the source's native rate differs, everything still agrees
  *because* all samples/buckets/frames/cuts are canonical samples — which is the whole point
  of PR 1. Verify canonical readback and fail loud on disagreement.

## Out of scope / deferred

Disk-cached pyramids + RMS band, global transport, multi-select editing, cross-slice
adjacency/no-overlap enforcement, `@Shared` promotion, and any engine revalidation. Phase 6
(distribution hardening: finish notarization, Sparkle, model-manager UX, licensing) is
separate.
