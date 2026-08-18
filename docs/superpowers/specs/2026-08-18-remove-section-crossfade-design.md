# Remove Section + Editable Crossfade — Design

**Status:** Draft for review
**Date:** 2026-08-18
**Author:** Brian (with Claude + Codex architecture consult)

---

## 1. Goal

Let the user **remove a section of audio** and have the two cut points automatically
joined by an **editable crossfade**, with the crossfade **displayed and edited the same
way as Logic Pro** (bowtie X at the seam, drag-to-resize, `⌃⌥X` equal-power default,
numeric values).

This is the app's first **subtractive, timeline-mutating** edit. Everything today is
*extractive* (pull a range out into its own AIFF); nothing removes a middle region and
rejoins the halves. There is also **no real crossfade DSP** in the codebase yet — "fade"
is advisory only. So this feature introduces both a new edit model and brand-new
crossfade audio rendering.

## 2. Confirmed product decisions

1. **Scope is context-dependent.** A removal made inside a single slice's edit view
   applies only to that slice's exported audio. A removal made in the full editor applies
   to the **whole interview timeline** — every overlapping slice/export inherits it.
   Timeline-scope is the fundamental case and lands first; slice-scope is a later PR in
   the same feature.
2. **Live audition in context is required.** Normal Play/Space playback must run
   **continuously across every seam with the crossfade blended** — hearing the join in
   context is the point of the feature, not a deferral. Dragging a cut point/fade must
   also audition the seam. (Continuous playback is a large job and may span PRs, but the
   feature is not "done" until it works.)
3. **Display is Logic-exact: the gap collapses.** Deleted audio is hidden, the timeline
   closes up, and a Logic-style crossfade **bowtie X** is drawn at the seam. A cut point
   is draggable **outward** to reveal more audio (like dragging a region edge in Logic).
   The waveform, ruler, playhead, and playback all render in an **edited/output**
   timeline distinct from original ("source") sample coordinates.
4. **Initiation.** Transcript-word selection **and** waveform marquee are both
   first-class. `Delete`/`⌫` removes the selected span and auto-creates an equal-power
   crossfade. Crossfade editing mirrors Logic: `⌃⌥X` creates/applies the equal-power
   default, drag the bowtie edges to resize, drag the curve to reshape, numeric values in
   an inspector.
5. **Crossfade DSP is Swift-owned.** Swift renders the crossfade for **both** live
   audition and export. The Python engine is demoted to a marker writer for these edits
   (its WhisperX / forced-alignment / silence-aware chunking are untouched). Equal-power
   math is implemented **once**, in Swift, to avoid cross-language drift.

## 3. Non-goals (v1 of the feature)

- Cross-seam marquee selection in one gesture (make removals one seam at a time).
- Multiple crossfade curve shapes beyond equal-power + linear.
- Arbitrary DAW-style timeline (ripple across tracks, multiple lanes, etc.).
- Rewriting the Python engine's analysis pipeline.

## 4. Architecture

### 4.1 Coordinate model — `EditedTimeline`

A dedicated **immutable value type** built from the normalized removal list, mapping
between **source samples** (original file) and **edited samples** (collapsed output):

```swift
struct EditedTimeline {
  let sourceDurationSamples: Int
  let removals: IdentifiedArrayOf<TimelineRemoval>  // normalized: sorted, non-overlapping

  func sourceToEdited(_ source: Int, bias: MappingBias) -> Int?
  func editedToSource(_ edited: Int) -> Int
  func editedRange(forSource range: Range<Int>) -> Range<Int>?
  func sourceRanges(forEdited range: Range<Int>) -> [Range<Int>]   // ≥1; 2 across a seam
  func seam(containingEdited sample: Int) -> TimelineSeam?
  var editedDurationSamples: Int { get }
}

enum MappingBias { case leftEdge, rightEdge, nearest, nilInsideRemoval }
```

`sourceToEdited` is **not total** — a sample inside a removed span has no edited
coordinate except under an explicit bias. Call sites must choose the bias; this prevents
silent "which side of the cut?" bugs.

**`WaveformModel` stays source-pure.** It keeps rendering the original audio and its
source-indexed peak pyramid unchanged. The collapse lives in a **presentation layer above
it** (methods on `EditorModel`, or a small `EditedWaveformAdapter`) that composes
`editedX → editedSample → sourceSample → source peaks`. Rationale: the pyramid is
source-indexed; if `WaveformModel` learned edited coordinates every existing caller would
become ambiguous. Keep the low-level renderer honest.

**Rendering a collapsed seam.** Visible edited columns map to source ranges via
`sourceRanges(forEdited:)`. Most columns map to one source span; a column straddling a
seam maps to two (left-source + right-source) whose min/max merge for the waveform
stroke. The **bowtie** is a separate overlay in edited coordinates: center = seam edited
sample, width = crossfade length in edited samples, representing overlapping source
material that is audible but not linearly present in the output.

### 4.2 Data model + scope

```swift
struct TimelineRemoval: Identifiable, Equatable, Codable, Sendable {
  var id: UUID
  var removedRange: Range<Int>   // SOURCE samples [a,b)
  var crossfade: Crossfade
}

struct Crossfade: Equatable, Codable, Sendable {
  var lengthSamples: Int
  var curve: CrossfadeCurve
}

enum CrossfadeCurve: Equatable, Codable, Sendable { case equalPower, linear }
```

Removals live in **editor document state, not in `EditPlan`** (EditPlan stays immutable
engine input / source truth):

```swift
struct EditorDocumentState: Equatable {
  var slices: IdentifiedArrayOf<Slice>
  var timelineRemovals: IdentifiedArrayOf<TimelineRemoval>
}
```

Slices keep `startSample/endSample` in **source** coordinates and are **not rewritten**
when a global removal happens; their edited/exported duration is *derived* from
`EditedTimeline`. Slice-local removals (later PR) attach to the `Slice`, also in **source**
coordinates (slice-relative coordinates drift when global removals shift the slice).

**Composition rule:** (1) global removals apply first, (2) slice export clips to the slice
source range, (3) slice-local removals apply within the slice's remaining material. A
global removal deleting the middle of a slice joins that slice's export around it; one
consuming a whole slice marks the slice unexportable. A removal straddling a slice
boundary only affects the in-slice portion — export never pulls audio from outside the
slice to satisfy a crossfade.

**Crossfade length is constrained by available audio around the seam, not the deleted
range.** Clamp on every edit:

```
leftHandleAvailable  = a - previousKeptLowerBound
rightHandleAvailable = nextKeptUpperBound - b
effectiveCrossfade   = min(requestedLength, leftHandleAvailable, rightHandleAvailable)
```

Overlapping removals are **normalized or rejected at edit time** — the stored list is
always non-overlapping and sorted by `lowerBound`. A slice-local removal that overlaps a
global removal is **rejected** in v1 (ambiguous "which seam owns the fade").

### 4.3 Undo

Widen the snapshot from slices-only to the document state; keep snapshot-based undo (no
command log yet — this feature needs correctness before undo compression):

```swift
struct EditorUndoState: Equatable {
  var slices: IdentifiedArrayOf<Slice>
  var timelineRemovals: IdentifiedArrayOf<TimelineRemoval>
}
```

Rename the `mutateSlices { }` funnel to `mutateDocument { }`; same cap (30), same restore
behavior, still does not track selection/zoom/playback. Crossfade dragging uses the
existing **`FineTuneModel` draft pattern**: drag into draft state, commit **once** on
mouse-up — never snapshot per drag tick.

### 4.4 Crossfade DSP + export (Swift-owned)

One equal-power crossfade renderer in Swift, used for both audition and export. Data-only
render spec shared with the engine:

```swift
struct AudioEditRenderPlan {
  var sourceURL: URL
  var sampleRate: Int
  var channels: Int
  var keptSegments: [Range<Int>]     // source ranges, in output order
  var seams: [RenderedCrossfade]     // per seam: overlap length + curve
  var markers: [Marker]              // in EDITED coordinates
}
```

- Swift builds output PCM deterministically from the canonical AIFF: copy kept-segment
  interiors, and at each seam mix the two overlapping tails with the equal-power (or
  linear) gain curve applied **per frame across all channels** (never per byte, never
  assume 16-bit until validated).
- The Python engine stops constructing joined samples. Two acceptable splits (decide in
  the export PR): **(a)** Swift writes the whole rendered AIFF including MARK chunks
  (port the small, tested `aiff_markers` MARK path to Swift), or **(b)** Swift renders
  PCM and Python injects/rebases markers without touching samples. Either way sample
  construction is not split across languages.
- Marker coordinates for exported slices become **edited** coordinates.

### 4.5 Live audition (continuous, required)

Playback must run continuously across seams with the blend baked into **PCM** (node gain
automation is not sample-accurate enough at seams — render the ramp into samples). Reuse
the §4.4 renderer.

- **Same renderer, two callers.** Dragging a cut/fade renders a **short preview buffer**
  around the one seam and plays it (fast, immediate). Continuous playback plays the whole
  edited timeline.
- **Continuous playback** on the existing single `AVAudioPlayerNode` + `TimePitch` chain:
  schedule each kept segment's non-overlapping interior directly from the source file
  (`scheduleSegment`), and at each seam schedule a small **pre-rendered crossfade PCM
  buffer** (the equal-power blend of the two tails). Seeking maps an edited sample →
  segment/seam → schedule from there. Speed changes ride the existing TimePitch node.
- **Position reporting is in edited coordinates.** Introduce distinct names —
  `sourceSample` vs `editedSample` — and never overload one integer called `sample`.

Extend `AudioPlayerClient` with a buffer-playing primitive alongside the existing
range-playing one:

```swift
func playRenderedBuffer(_ buffer: AVAudioPCMBuffer, editedStartSample: Int,
                        sampleRate: Int, rate: Double, session: TransportSession)
```

Keep `play(url, range:)` for the un-edited path until it is deliberately replaced.

### 4.6 Interaction (Logic parity)

- **Create:** select a span (transcript words or waveform marquee within one continuous
  stretch) → `Delete`/`⌫` → the source span is removed and an **equal-power crossfade** is
  auto-created at the seam; the gap collapses.
- **Edit the crossfade:** click a seam to select it; drag the bowtie's outer edges to
  lengthen/shorten (clamped to available handle), drag a cut point outward to reveal more
  audio; drag the curve to reshape; `⌃⌥X` (re)applies the equal-power default; numeric
  fade values in an inspector. Snapping reuses a generalized `FineTuneGeometry`
  ("movable source boundary with neighboring kept ranges") — decoupled from `SliceEdge`,
  since a seam has up to four constraints, not two slice boundaries.
- **Zoom/scroll anchor by edited sample under the cursor** (anchoring by source sample
  makes the viewport jump when the gap collapses).
- **Ruler labels are edited/output time.** Source time appears only in an
  inspector/debug affordance (a collapsed ruler showing source time is lying).

### 4.7 Edge-case policies (v1 defaults)

- A word whose **midpoint** is in a deleted span is **hidden** from the transcript
  (matches existing midpoint membership logic). A word straddling a removal keeps showing;
  its audio is clipped by the crossfade.
- **Cross-seam marquee is rejected** for the delete gesture.
- **Markers** inside a removed region are dropped; markers after a removal shift left;
  markers in a crossfade handle region bias to the audible edited coordinate from their
  source side.
- **Transcript clip bands** hide deleted words and collapse around removals (will exercise
  assumptions in `TranscriptClipBand`).
- **Cut-suggester / tight-join warnings** evolve: "tight join — add a fade in Logic"
  becomes scope-dependent ("crossfade too short / no handle / abrupt boundary"). Full
  reconciliation is a later PR; v1 must not crash or contradict existing warnings.

### 4.8 Persistence

`timelineRemovals` persist in the existing per-file **`ProjectState` sidecar**
(`Models/ProjectState.swift`, `State/ProjectStore.swift`) via `@Shared(.fileStorage)`
keyed by source fingerprint. Add a new lenient-decoded optional section
(`timelineRemovals`, default `[]`) exactly like `cutSuggestions` — so older sidecars keep
decoding and are not clobbered. Slice-local removals ride inside the persisted `Slice`
when that PR lands. Without persistence the feature is fake; this is in scope from the
first editing PR.

## 5. Testing strategy

- **`EditedTimeline` unit tests** (pure, no audio): source↔edited mapping, bias behavior,
  `sourceRanges(forEdited:)` across seams, `editedDuration`, seam lookup, clamping,
  normalization/rejection of overlaps, boundary cases (removal at start/end, adjacent
  removals, zero-length guards).
- **Model tests** via `withDependencies`: delete creates the right `TimelineRemoval` +
  default crossfade; undo/redo round-trips `EditorUndoState`; drag commits one undo entry;
  crossfade clamp; word-hide policy; cross-seam marquee rejection.
- **Renderer tests**: equal-power gain sums, per-frame/multichannel correctness, endpoint
  convention identical for preview and export, deterministic output.
- **Persistence tests**: `ProjectState` round-trips `timelineRemovals`; old sidecar
  without the section still decodes.
- Value comparisons use `expectNoDifference`/`expectDifference`. No `Task.sleep`; use
  `ImmediateClock` / test doubles. Fixtures over real audio/subprocess.

## 6. PR sequence

Four PRs, each independently shippable and testable. The core feature (remove → hear →
export) is complete at PR 2; PR 3 adds Logic-parity editing; PR 4 adds slice scope.

1. **Remove + collapse + persist (silent).** `TimelineRemoval`, `Crossfade`,
   `EditedTimeline` with full mapping + normalization + validation (unit-tested); the
   delete gesture from transcript-word selection **and** waveform marquee, creating a
   `TimelineRemoval` with the default equal-power crossfade; collapsed edited-coordinate
   rendering (waveform, ruler, playhead, bowtie overlay) with `WaveformModel` kept
   source-pure and zoom/scroll anchored by edited sample; undo via the widened
   `mutateDocument` snapshot; persistence in `ProjectState`.
   *Interim limitation (state in the PR):* playback still plays the original contiguous
   ranges — the deletion is visible and persisted but not yet audible. Blending lands in
   PR 2.
2. **Hear it + export it.** The single Swift equal-power PCM crossfade renderer;
   `AudioPlayerClient.playRenderedBuffer`; continuous scheduled playback that blends
   across every seam (kept-segment interiors from source + pre-rendered seam buffers),
   position in edited coordinates; the short-window drag preview uses the same renderer;
   export through that renderer so timeline removals affect every slice export, Python
   demoted to marker-writing (split per §4.4), markers rebased to edited coordinates.
   Feature is now audible-in-context and correct on export.
3. **Editable seam UI parity.** Drag cut edges out/in, drag fade length + curve, numeric
   values, `⌃⌥X`; generalized `FineTuneGeometry` snapping ("movable source boundary with
   neighboring kept ranges", decoupled from `SliceEdge`).
4. **Slice-local removals.** `Slice.localRemovals`; composition with the global timeline
   per §4.2; the slice edit modal (`EditSliceModel`) gets the same seam editor.

Later / follow-up: reconcile cut-suggester / tight-join warnings with real crossfades;
document/version migration if the project format changes further.

## 7. Risks & open questions

- **Continuous playback complexity.** Scheduling kept-segment interiors + seam buffers
  with correct seeking, speed change, and cancellation is the hardest part; §4.5 keeps
  the blend in PCM to stay sample-accurate. Prototype scheduling early in PR 4.
- **Performance.** Cache `EditedTimeline` (mapping is called constantly); render only the
  visible range + preview buffer; never rebuild the whole edited waveform per drag tick.
- **Marker split decision** (§4.4 a vs b) is deferred to the export PR; both keep sample
  construction in Swift.
- **Rounding/endpoint convention** for the equal-power curve must be one shared function
  across preview and export.
