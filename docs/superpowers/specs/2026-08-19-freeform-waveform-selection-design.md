# Freeform waveform selection — design

**Date:** 2026-08-19
**Status:** Design approved (pending spec review) → writing-plans next
**Feature:** Invert the selection source of truth so a freeform sample range in
the waveform *is* the selection. Words become a pure affordance — an entry point
into waveform coordinates on input, and a derived readout on output — never
selection state.

**Merged-baseline note (2026-08-19):** validated against `main` at #51 (remove
section + crossfade) **and #52 (Logic-style vertical amplitude zoom)**. #52 is
orthogonal to this feature: it is a separate toolbar control
(`WaveformAmplitudeZoomButton`, its own click-hold-drag area) that scales the
waveform *vertically* via `WaveformModel.amplitudeScale`; it does **not** touch
the `WaveformInteractionLayer` (marquee/click) where this PR's selection
edge-handles will live, so there is no gesture collision. The only carry-over:
`WaveformLaneDriving` gained an `amplitudeScale` member — any new lane-driver
conformance added here must include it. No architecture change from #52.

---

## 1. Problem

Today the waveform has **no** sample-accurate selection. Selection is 100%
word-based and the **transcript is the source of truth**:

- `waveformClicked(atX:)` → `wordID(atSample:)` → `transcript.selectWord(id)`
- marquee (`waveformAreaSelect*`) → `marqueeAnchorFocus()` resolves to **word
  IDs** (words whose *midpoint* falls in the dragged sample range) →
  `transcript.selectWords(anchorID:focusID:)`
- Everything downstream reads `transcript.selectedSampleRange` (the span of the
  selected **words**): Remove Section range, Mark-as-Clip, playhead commit,
  transcript strikethrough (`removedWordIDs`), reveal / auto-scroll,
  zoom-to-fit, transport snap.

So a marquee **snaps** the highlight to whole-word edges. The user cannot delete
a single word or a sub-word fragment. Forced-alignment word boundaries are off
by 10–20 ms because of coarticulation (people blur words together). The 10 ms
pre-commit nudge shipped in the remove-section PR (`FineTuneModel`, `snap:
false`) is the *only* sample-accurate edit path today, and it is a stopgap on
the pending removal.

**Goal:** the waveform sample range is the single truth; the transcript is a
convenience layer over it in both directions.

---

## 2. Locked product decisions

1. **Invert the source of truth.** A freeform `Range<Int>` in **source samples**
   becomes THE selection. Text-view word selection no longer *is* the selection;
   selecting words there only **seeds** a waveform highlight (the span of those
   words), which is then freely editable in the waveform.
2. **Edit gesture.** Drag the highlight's left/right **edge handles** to any
   sample; the 10 ms nudge keys (`←/→`, `⇧←/⇧→`) are the fine layer; a fresh
   marquee starts a new selection. Reuse the **boundary math**, not the whole
   `FineTuneModel` (see §5).
3. **Strikethrough is the "negative."** A word is struck through **iff its entire
   `[start, end)` source range is contained in a removal's removed range.** Any
   surviving audio of a word → **not** struck (still partly heard).
4. **Mark-as-Clip membership is the dual "positive."** A word is **in** a clip
   **iff any of its audio overlaps** the clip range. Same predicate ("is this
   word still heard?"), opposite directions.

These are settled. The rest of this document is *how*.

---

## 3. Architecture

### 3.1 The single source of truth

Add to `EditorModel` (plain `@Observable`, **not** `@Shared`, **not**
undoable — selection is ephemeral UI state):

```swift
// MARK: - Selection (source samples — the single source of truth)
var audioSelection: Range<Int>?          // nil = nothing selected
var selectionAnchorSample: Int?          // fixed edge during a marquee/extend
var selectionEditingEdge: SelectionEdge? // .start / .end while edge-dragging
```

`mutateDocument` (the undo funnel over `EditorDocumentState { slices;
timelineRemovals }`) stays reserved for **committed** slices/removals. Selection
never enters the undo stack.

**Why not `@Shared(.selection)`:** selection is not document state, not sidecar
state, and must not be mutated behind `EditorModel`'s back by another model. It
is transient view state that dies with the editor. `@Shared` is for the loaded
plan, slices, and removals — things that persist and cross views.

### 3.2 Minimal interface on `EditorModel`

```swift
func clearSelection()

// Text entry point: word span → source range → audioSelection.
func selectWords(anchorID: Word.ID, focusID: Word.ID)
func selectWord(_ id: Word.ID, extending: Bool)

// Direct source-range set (waveform click / programmatic reveal).
func selectSourceRange(_ range: Range<Int>, snapPlayhead: Bool)

// Marquee in the waveform (freeform).
func marqueeSelectionBegan(atX: CGFloat, extending: Bool)
func marqueeSelectionChanged(toX: CGFloat)
func marqueeSelectionEnded(toX: CGFloat)

// Edge-drag + nudge (freeform, snap off).
func selectionEdgeDragBegan(_ edge: SelectionEdge)
func selectionEdgeDragged(_ edge: SelectionEdge, toX: CGFloat)
func selectionNudged(_ edge: SelectionEdge, byMs: Double)
```

Everything downstream reads `audioSelection` (via a `selectedSourceRange`
facade during migration — see §6), never `transcript.selectedSampleRange`.

### 3.3 The transcript: input gesture + derived readout, never truth

- **Input:** a text click/drag emits word IDs to `EditorModel`, which converts
  the word span to a source range and sets `audioSelection`. After that,
  waveform edge-drags mutate only `audioSelection`.
- **Output (derived from `audioSelection` / removals / clips):**

  | Display | Predicate |
  |---|---|
  | selection highlight (text) | word range **overlaps** `audioSelection` |
  | strikethrough | word range **fully contained** in a removal |
  | clip membership | word range **overlaps** the clip |

  Off-by-one, explicit:
  - contained: `removal.lowerBound <= word.start && word.end <= removal.upperBound`
  - overlap: `word.start < range.upperBound && word.end > range.lowerBound`

**No snapping the range back to word edges — ever.** That would defeat the
feature. A 30 ms sub-word selection may visually tint the *whole* containing
word in the text; that is acceptable because the waveform highlight is the real
selection. Character-level text striping is intentionally out of scope:
forced alignment gives per-*word* timings only, so there is no reliable
sample→character map.

`TranscriptPageModel` stops owning selection truth:
`selectionAnchorID`, `selectedSampleRange`, `orderedSelectedWordIDs`, and
`selectedWordIDSet` are demoted. Any anchor/focus it keeps is *internal to a text
drag gesture only*; the committed result is pushed to `EditorModel`. Rendering
inputs (`removedWordIDs`, selection highlight set, clip bands) are pushed **in**
from `EditorModel` as derived sets rather than computed from internal selection.

### 3.4 Coordinates: source is canonical, always

`audioSelection` is stored in **source samples**. The edited-axis adapter
(`EditedWaveformAdapter`) only converts at the boundary:

- **input:** `editedWaveform.xToSourceSample(x)` (view-x → source)
- **render:** `editedWaveform.laneSpan(forSource:)` /
  `sourceSampleToX(_:bias:)` (source → edited view span)

Selection is **never** stored in edited/collapsed coordinates. `WaveformModel`
stays source-pure (the slice-edit modal reads its source columns); the adapter
remains the only edited-axis surface.

### 3.5 Edge-drag math: extract `BoundaryRangeEditor`

Extract the pure boundary mechanics currently living inside `FineTuneModel`
(`moveStart`/`moveEnd` with clamping to file bounds and a min-duration floor)
into a small, value-type helper both call sites share:

```swift
struct BoundaryRangeEditor {
  var fileDurationSamples: Int
  var sampleRate: Int
  var minDurationSamples: Int

  func moveStart(of range: Range<Int>, to sample: Int, snap: Bool) -> Range<Int>
  func moveEnd(of range: Range<Int>, to sample: Int, snap: Bool) -> Range<Int>
  func nudgeStart(of range: Range<Int>, byMs: Double) -> Range<Int>
  func nudgeEnd(of range: Range<Int>, byMs: Double) -> Range<Int>
}
```

Primary selection uses `snap: false` for handle drags and nudges.
`FineTuneModel` keeps its session/target/magnetism/audition-preview semantics
for the slice-edit modal but delegates the raw edge math to the same helper.

---

## 4. User-facing behavior

- **Marquee in the waveform:** selects exactly the dragged `[start, end)` in
  source samples. No snap. Auto-scroll past the viewport edge still works
  (moves the *edited* viewport, range read back in source).
- **Click a word / drag across words in the transcript:** seeds `audioSelection`
  with the covered words' source span; you then adjust it freely in the
  waveform.
- **Edge handles:** grab the left or right edge of the highlight, drag to any
  sample. `←/→` nudge the active edge by 10 ms; `⇧←/⇧→` the other edge (matching
  the shipped nudge convention).
- **Remove Section:** removes exactly `audioSelection`. A word is struck only
  when fully removed; partially-cut words render normally.
- **Mark as Clip:** clip spans exactly `audioSelection`; its `wordIDs` are
  derived by **overlap at commit time** (not inherited from any transcript
  selection).

---

## 5. `FineTuneModel` decision (refinement of locked decision #2)

**Do not promote `FineTuneModel` to the primary selection editor.** It carries
target/session/committed-draft/preview/audition semantics that are wrong for an
always-visible primary selection — the same stale-session machinery that caused
the Task 9 "permanently stuck selection" bug. Instead, extract the boundary math
(§3.5) and let both the primary selection and the slice-edit modal use it. This
honors the intent of decision #2 ("don't rebuild edge-drag from scratch") by
reusing the *mechanics*, while keeping the session state machine out of the
primary path.

---

## 6. Migration (incremental, facade-first — no big-bang)

Each step compiles and keeps tests green.

1. **Add `EditorModel.audioSelection`** and a read facade
   `var selectedSourceRange: Range<Int>? { audioSelection }`, initially **seeded
   from** `transcript.selectedSampleRange` in the existing selection `onChange`.
   Nothing reads the facade yet.
2. **Switch readers to the facade** one cluster at a time, still backed by the
   seed: `activeOrSelectedRange`, `activeEditingRange`, `canAddSlice`,
   `addSliceTapped`, `pendingRemovalSourceRange` / `canRemoveSelectedSection` /
   `removeSelectedSectionTapped`, `zoomWaveformToSelection`,
   `transportSelectionChanged`.
3. **Flip the waveform writers:** `waveformClicked` and the marquee
   (`waveformAreaSelect*`) write `audioSelection` directly (freeform) instead of
   resolving to word IDs. Marquee no longer routes through `marqueeAnchorFocus()`
   word resolution.
4. **Flip the transcript to emit intents:** text click/drag calls
   `EditorModel.selectWords(...)` / `selectWord(...)`, which set `audioSelection`.
   Stop seeding from `transcript.selectedSampleRange`.
5. **Add edge-drag + nudge on the primary selection** using `BoundaryRangeEditor`
   (`selectionEdgeDrag*`, `selectionNudged`); wire the handles in
   `WaveformLaneView` and the keys in `EditorKeyMonitor`.
6. **Derive transcript rendering from `audioSelection`:** push derived sets
   (`removedWordIDs`, selection-highlight set, clip bands) into
   `TranscriptPageModel`; stop it computing selection truth internally.
7. **Demote/delete** `transcript.selectedSampleRange`, `orderedSelectedWordIDs`,
   and `selectionAnchorID` from editor logic. Repurpose `revealSelection()` into
   `revealSourceRange(_:)` — scroll to the first word overlapping the range.

Steps map to plan tasks in the writing-plans phase; a task is one reviewable,
green commit.

---

## 7. Known rules & edge cases (bake into tests)

- **New removals still can't overlap an existing removal** — reuse today's
  `canRemove(sourceRange:)` gate. Selection *display* may span across a removed
  region, but a destructive commit that overlaps an existing removal is blocked
  (same as today).
- **Selection over a collapsed seam:** `xToSourceSample` is discontinuous near a
  removal (the edited axis skips the removed span). An edge-drag can jump from
  pre-cut to post-cut source. This is expected; cover it with tests. A nicer UI
  affordance is a follow-up, not this PR.
- **Two-way sync loops:** only `EditorModel.audioSelection` is authoritative.
  The transcript emits intents and renders derived state; it never observes and
  rewrites the selection. This is the single rule that prevents feedback loops.
- **Clip `wordIDs`** are overlap-derived at commit time, not inherited.
- **Undo:** selection changes never undo; only slice/removal commits do (through
  `mutateDocument`). **Decided deferral (2026-08-19):** pre-commit selection-edit
  undo (⌘Z to step back one edge-drag/nudge/marquee *before* committing) is out of
  scope for this PR. The committed Remove/Mark-as-Clip is already undoable, which
  is the real safety net; putting ephemeral selection into the document stack would
  conflate two histories (⌘Z ambiguous between "undo my cut" and "undo an
  edge-wiggle"), and Logic doesn't undo selection either. Because selection lives as
  isolated plain `@Observable` state (not `@Shared`, not in `mutateDocument`), adding
  a lightweight session-local selection-edit history *later* is purely additive — no
  rework, no coupling to the document stack. Revisit only if freeform fiddling proves
  annoying enough to warrant it.
- **Empty / silence:** a marquee that resolves to a zero/negative range clears
  the selection (mirror today's "drag over pure silence clears").

---

## 8. Testing strategy

Model-only (Swift Testing, `expectNoDifference`), no audio/subprocess:

- **`BoundaryRangeEditor`** unit tests: move/nudge start/end, min-duration
  floor, file-bound clamps, `snap` on/off parity with the old `FineTuneModel`
  math (regression: same results the shipped nudge produced).
- **Derived-display predicates:** fully-contained strikethrough vs overlap
  highlight vs overlap clip membership, including the exact off-by-one edges
  (word touching the boundary by one sample).
- **Selection flow:** word-seed → source range; marquee sets exact source range
  (no word snap); edge-drag mutates only the dragged edge; nudge by 10 ms.
- **Downstream wiring:** `canRemoveSelectedSection`, `removeSelectedSectionTapped`,
  `canAddSlice`, `addSliceTapped` all read `audioSelection`; overlap-with-existing
  removal is blocked.
- **Coexistence / regression:** existing `WaveformModel`/`EditedWaveformAdapter`
  and slice-edit-modal tests stay green (source-purity preserved).
- **Seam discontinuity:** edge-drag across a collapsed removal maps to the
  expected source sample.

---

## 9. Out of scope (explicit)

- Character-level (sub-word) text strikethrough/highlight.
- A dedicated UI affordance for dragging a selection edge *across* a collapsed
  removal seam (works, but no special visual yet).
- Crossfade *audio* rendering for removals (that is the separate crossfade PR).
- Persisting selection across sessions (it stays ephemeral).
