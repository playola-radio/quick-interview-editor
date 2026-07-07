# Phase 4 — Read-only waveform sync: implementation plan

Design: `docs/superpowers/specs/2026-07-07-phase4-waveform-sync-design.md`.
TDD, incremental commits. `xcodegen generate` + commit the `.xcodeproj` after any
file add. Local gate each stage: `xcodebuild test`, `make lint`, `make format-check`.
Invoke the relevant `pfw-*` skills before writing Swift in each stage.

## Stage 1: `Waveform` value type + `WaveformClient` dependency
**Goal**: The peak-pyramid data model and its mockable client boundary exist.
**Deliverable**: `Core/WaveformClient.swift` (`WaveformClient`, `Waveform`,
`Waveform.Level`), `liveValue`/`testValue`/`previewValue`, `DependencyValues.waveform`.
Live reads native PCM via streaming `AVAssetReader`, downmixes to mono, builds a
min/max pyramid keyed in plan samples (base bucket 256), native→plan ratio internal.
**Tests**: `Waveform` fixture helpers; `previewValue` returns a non-empty pyramid;
pyramid level invariants (bucketSize doubles, mins ≤ maxs, level lengths halve). Live
decode is not unit-tested (parity with `AudioPlayerClient.live`).
**Success**: builds; client injectable; `make lint`/`format-check` clean.
**Status**: Not Started

## Stage 2: `WaveformModel` geometry + hit-testing (the correctness core)
**Goal**: All sample↔pixel math, zoom, visible-window, columns, overlay rects — pure,
tested, zero audio.
**Deliverable**: `Views/Pages/Editor/WaveformModel.swift` (`@MainActor @Observable`,
`ViewModel` subclass) + `WaveformColumn`. Load action calls `WaveformClient`; geometry
functions per design; zoom/scroll actions clamped.
**Tests**: `WaveformTests.swift` — `sampleToX`/`xToSample` floor semantics + round-trip;
`visibleColumns` bucket floor/end-exclusive + final partial bucket; `rect(for:)` clip;
zoom/scroll clamping to `0..<totalSamples`; loads a fixture via `withDependencies`.
Use `expectNoDifference`.
**Success**: model fully unit-tested against fixtures, no subprocess/audio.
**Status**: Not Started

## Stage 3: `AudioPlayerClient.positions` stream + playhead in the model
**Goal**: Real, mockable playback position feeding a playhead sample.
**Deliverable**: add `positions` to `AudioPlayerClient` (+ `PlaybackPosition`); live
samples `AVAudioPlayerNode` render timing → plan samples; test/preview return an empty
stream. `WaveformModel.playheadSample`/`playheadX`; `EditorModel` subscribes and maps
positions while a slice plays, clears on stop.
**Tests**: scripted `positions` stream drives `playheadSample`/`playheadX`
deterministically; cleared on stop; existing `AudioPlayerClientTests` still green.
No `Task.sleep`.
**Success**: playhead driven by injected positions in tests; live isolated in the actor.
**Status**: Not Started

## Stage 4: Two-way sync wiring in `EditorModel`
**Goal**: word↔waveform selection + red overlay, mediated by `EditorModel`.
**Deliverable**: `EditorModel` owns `waveform`; pushes `highlightedSampleRange`,
`redRanges` (shared `runTogetherWordIDs` + sensitivity), and drives waveform load;
`waveformTapped(atX:)` maps x→sample→word→transcript selection (`[start,end)`,
end-belongs-to-next).
**Tests**: extend `EditorTests.swift` — tapping waveform selects the right word; tapping
at a boundary picks the next/none; transcript selection updates `highlightedSampleRange`;
sensitivity change updates `redRanges`; words missing samples excluded.
**Success**: sync correct both directions, all on the model.
**Status**: Not Started

## Stage 5: Views + `EditorView` integration
**Goal**: It renders and is interactive; zero logic in the view.
**Deliverable**: `Views/Pages/Editor/WaveformView.swift` — `Canvas` for columns +
overlay rects, `GeometryReader`→`viewportResized`, tap→`waveformTapped`, separate
playhead overlay subview reading `playheadX`. Wire into `EditorView`. Zoom controls
bound to model.
**Tests**: covered by model tests (view holds no logic). Manual QA via dev `.venv` /
`QIE_ENGINE_REPO`; confirm sample alignment on the real Hayes Carll clip.
**Success**: waveform visible, click/zoom/playhead work against real audio; `make lint`,
`make format-check`, `xcodebuild test`, `pytest` all green.
**Status**: Not Started

## Adversarial review (pre-PR)
`/codex review` then `/codex challenge` on the diff — focus sample drift, pixel↔sample
off-by-one, native↔plan mapping, perf on long audio. Fix findings. Then PR against main,
`/fix-review`, resolve Greptile + CodeRabbit, CI green.
