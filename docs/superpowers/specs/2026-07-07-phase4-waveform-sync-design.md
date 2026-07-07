# Phase 4 — Read-only waveform sync (design)

Date: 2026-07-07
Branch: `briankeane/phase4-waveform`
Architecture reviewed with Codex (consult session `019f3c8b-1784-7af1-ba05-8ba600a7c0d6`).

## Goal

Add a zoomable audio waveform beside the transcript, two-way synchronized with word
selection, per roadmap Phase 4. Read-only: playhead + zoom are in; dragging cuts,
fine-tune, and undo/redo are Phase 5 and explicitly out of scope here.

Success:

- Waveform renders from the interview audio, in the same **sample coordinates** as
  `editPlan` (roadmap decision 4 / decision 5).
- Click a word → its audio range highlights in the waveform.
- Click the waveform → the word(s) under that point select in the transcript.
- A playhead tracks slice playback; zoom in/out works.
- Run-together words render red in the waveform, mirroring the transcript's mapping.

## The coordinate problem (the load-bearing decision)

Everything in the app is modeled in **plan samples** — integer sample indices at
`editPlan.source.sampleRate` (44100). Words, silences, slices, and playback ranges all
use plan samples. Phase 4 must not break that.

Reality check from the code: at the Editor layer there is **no persistent canonical
AIFF**. `EditorModel.sourceURL` is the *original* dragged-in file (e.g. an `.m4a` at its
own native sample rate). The engine builds a canonical 44100 Hz AIFF only transiently in
a work-dir during transcription/render and deletes it. `AudioPlayerClient.play` already
copes by converting plan-sample ranges to native frames via `ratio = nativeRate /
planSampleRate`.

Decision: **the UI coordinate system is always plan samples.** The native→plan rate
mapping is confined *inside the dependency clients*, never exposed to the model or views:

- `WaveformClient` reads the native PCM from `sourceURL` and returns a peak pyramid whose
  buckets are keyed in **plan samples** spanning `[0, durationSamples)`. The rate
  conversion happens once, inside the client.
- `AudioPlayerClient`'s new position stream emits **plan-sample** positions (it already
  computes the ratio for playback).

This mirrors the existing playback path exactly, so the waveform, the playhead, and the
audio the user hears all derive from the same file through the same conversion and are
guaranteed to agree. It avoids scope-creeping into materializing/persisting a canonical
AIFF (an engine + file-lifecycle change that belongs to its own PR). When native rate ==
plan rate (the common 44.1k case) the conversion is identity.

## Components

### 1. `WaveformClient` (new `Sendable` dependency) — `Core/WaveformClient.swift`

```swift
struct WaveformClient: Sendable {
  /// Reads native PCM from `url`, downmixes to mono, and builds a multi-resolution
  /// min/max peak pyramid keyed in PLAN samples (`planSampleRate`), spanning
  /// [0, durationSamples). Streams the read so peak memory stays bounded.
  var loadWaveform: @Sendable (_ url: URL, _ planSampleRate: Int, _ durationSamples: Int)
    async throws -> Waveform
}
```

`Waveform` (Sendable value type):

```swift
struct Waveform: Sendable, Equatable {
  var sampleRate: Int          // plan sample rate (bucket coordinate system)
  var totalSamples: Int        // == durationSamples
  var levels: [Level]          // level 0 = finest; each higher level halves resolution
  struct Level: Sendable, Equatable {
    var bucketSize: Int        // samples per bucket (plan samples); doubles per level
    var mins: [Float]          // normalized -1...1
    var maxs: [Float]
  }
}
```

- **Live:** `AVAssetReader` pulls fixed-size `CMSampleBuffer`s (bounded memory, no
  full-file PCM buffer), downmixes channels by averaging per frame (no resample of the
  count), and accumulates min/max into base-level buckets. Frame index → plan-sample
  position via the native→plan ratio. Higher levels are built by pairwise-reducing the
  level below. Base `bucketSize = 256` plan samples (chosen over 512 for word-boundary
  zoom detail; memory for 90 min ≈ ~10 MB, trivial).
- **testValue:** reports an issue and throws (matches `EngineClient`/`AudioPlayerClient`).
- **previewValue:** returns a small synthetic `Waveform` for SwiftUI previews.
- Not unit-tested at the live layer (real audio decode), same as `AudioPlayerClient.live`.
  The model is tested against synthetic `Waveform` fixtures.

RMS is intentionally **skipped** in Phase 4 (min/max is what a read-only editor needs;
add RMS later only if the waveform looks too spiky).

### 2. `AudioPlayerClient` — additive playback-position stream

Codex recommended real AVFoundation-derived positions behind a mockable stream (not a
clock-estimated fake that could drift and undermine the app's sample-accuracy promise).
**Refinement over Codex's exact shape:** rather than change `play`'s signature (which
would break the already-shipped, concurrency-tuned slice-playback path, its actor, and
all call sites/tests), add a separate, independently-mockable field:

```swift
struct AudioPlayerClient: Sendable {
  var play: @Sendable (URL, Range<Int>, Int) async throws -> Void   // unchanged
  var stop: @Sendable () async -> Void                              // unchanged
  var positions: @Sendable () -> AsyncStream<PlaybackPosition>      // NEW
}

struct PlaybackPosition: Sendable, Equatable {
  var sample: Int        // plan samples
  var isPlaying: Bool
}
```

- **Live:** the player actor samples `AVAudioPlayerNode` render timing on a timer during
  playback and yields plan-sample positions (native frame → plan sample via the ratio it
  already has). AVFoundation stays isolated in the actor; only value structs cross the
  boundary. Render-thread/timer callbacks are `@Sendable` and capture no non-Sendable
  player internals (CI Swift 6 `sending` strictness).
- **testValue/previewValue:** return an empty (immediately-finishing) stream by default;
  tests inject a scripted stream to drive playhead assertions deterministically — no
  `Task.sleep`, no real audio.

### 3. `WaveformModel` (new child model) — `Views/Pages/Editor/WaveformModel.swift`

`@MainActor @Observable`, owned by `EditorModel` (composition, like `transcript`). Holds
**only waveform geometry state**; it does not know transcript semantics (Codex: the
waveform must not own word lookup).

State: `waveform: Waveform?`, `isLoading`, `viewportWidth: CGFloat`,
`samplesPerPixel: Double` (zoom), `visibleStartSample: Int`.

Rendering inputs it is *given* by `EditorModel` (plain values, recomputed when transcript
changes): `highlightedRange: Range<Int>?`, `redRanges: [Range<Int>]`,
`playheadSample: Int?`.

Pure geometry (all unit-tested, the coordinate-correctness core):

- `sampleToX(_ sample: Int) -> CGFloat`
- `xToSample(_ x: CGFloat) -> Int` (explicit floor semantics: pixel `x` covers plan
  samples `[floor(x·spp)+start, floor((x+1)·spp)+start)`)
- `visibleColumns() -> [WaveformColumn]` — one min/max column per horizontal pixel,
  reading the pyramid level whose `bucketSize` is closest to `samplesPerPixel`; start
  bucket by floor, end bucket end-exclusive; preserves the final partial bucket.
- `rect(for range: Range<Int>) -> CGRect?` — clipped to the visible window (for the
  highlight + each red range).
- `playheadX: CGFloat?`
- zoom/scroll actions: `zoomIn/Out`, `scrolled(to:)`, clamped to `0..<totalSamples`.

### 4. `EditorModel` — mediation + wiring

- Owns `waveform: WaveformModel` alongside `transcript`.
- On load: `Task { waveform.load(sourceURL:, plan:) }` via `WaveformClient`.
- Subscribes to `audioPlayer.positions()`; maps each `PlaybackPosition` into
  `waveform.playheadSample` (only while a slice is playing; cleared on stop).
- Exposes derived cross-domain inputs and pushes them into `waveform` whenever transcript
  state changes:
  - `highlightedSampleRange` ← `transcript.selectedSampleRange`
  - `redRanges` ← run-together word IDs (`runTogetherWordIDs`, the **same** gap-based
    function + live sensitivity value the transcript uses) mapped to `[startSample,
    endSample)` ranges; words missing samples are excluded (not guessed from seconds).
- Waveform → transcript command (view calls it): `waveformTapped(atX:)` →
  `waveform.xToSample(x)` → find the word whose `[startSample, endSample)` contains that
  sample (lookup lives in `EditorModel`, which owns the plan) → set transcript
  anchor/focus. A tap at exactly a word's `endSample` belongs to the next word or none.

No child↔child references; no stored parent callbacks. `EditorModel` is the single
mediator, keeping ownership acyclic and every model independently testable.

### 5. Renderer — SwiftUI `Canvas` (+ separate playhead layer) — `WaveformView.swift`

- A `GeometryReader` reports width to `waveform.viewportResized(width:)`; the model then
  produces columns.
- `Canvas` strokes `waveform.visibleColumns()` and fills the highlight + red rects. Zero
  logic in the view — it draws model output and forwards taps
  (`.onTapGesture` → `model.waveformTapped(atX:)`).
- The **playhead is a separate thin overlay** (a `Rectangle` at `waveform.playheadX`) in
  its own subview, so frequent playhead updates don't invalidate the Canvas (SwiftUI's
  granular `@Observable` tracking re-renders only the view that reads `playheadX`).
- Drop to `NSViewRepresentable`/Metal only if profiling shows Canvas stutters — not now.

### 6. `EditorView` wiring

Insert the waveform between the transcript and the slices panel (a horizontal band under
the transcript, or a middle column — visual placement finalized during implementation,
mirroring `ux-prototype`). Bind entirely to `model` (EditorModel).

## Sample-accuracy correctness (test checklist)

Derived from Codex's adversarial list; each becomes a `WaveformModel`/`EditorModel` test:

- `[startSample, endSample)` half-open everywhere; click exactly at a word's `endSample`
  selects the next word or none, never the ending word.
- `xToSample` floor semantics pinned by test; round-trip `sampleToX`/`xToSample` stable.
- Visible range clamped to `0..<totalSamples`; zoom clamped to sane min/max spp.
- Column bucket lookup: floor start bucket, end-exclusive end bucket, final partial bucket
  preserved (no dropped tail audio).
- Words with missing `startSample`/`endSample` excluded from hit-testing and red overlay.
- Red overlay uses the shared gap-based `runTogetherWordIDs` — reacts to the sensitivity
  slider exactly like the transcript.
- Native↔plan rate mapping: identity when equal; correct bucket coverage when native ≠
  plan (conversion confined to the client; model tests use plan-sample fixtures).
- Playhead: scripted `positions` stream drives `playheadSample`/`playheadX`
  deterministically; cleared on stop; no `Task.sleep`.

## Deviations from Codex (surfaced for review)

1. **Playhead is an additive `positions` stream, not a breaking `play` signature change.**
   Same core call (real AVFoundation positions, mockable, AVFoundation isolated) with a
   far smaller blast radius on already-shipped, carefully concurrency-tuned code.
2. **No canonical-AIFF materialization.** `sourceURL` is the original file; the native→plan
   rate mapping is confined inside `WaveformClient` + the `positions` stream, mirroring the
   existing playback path, instead of persisting a 44.1k AIFF (deferred to a decision-4 PR).

Both keep Phase 4 read-only and correctly scoped.

## Out of scope (Phase 5)

Dragging boundary handles, editing/moving cuts, fine-tune panel, undo/redo, global
transport / play-whole-file, disk-cached pyramids, RMS, Metal/`NSViewRepresentable`
renderer.
