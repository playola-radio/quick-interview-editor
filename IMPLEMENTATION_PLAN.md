# Implementation Plan: Step 3b — Engine render + export/reveal

Spec: `docs/superpowers/specs/2026-07-06-step3-slices-export-design.md` (the **3b** section).
Mirrors the Step-2 plumbing (`cli.py` `plan`, `LiveEngine.transcribe`, `EngineClient`).

## Stage 1: Python `render` subcommand + pytest
**Goal**: `python -m logic_markers.cli render <audio> --request req.json --work-dir dir`
converts the source to a canonical AIFF once, then `slice_aiff` per slice into the
work-dir; result JSON keyed by slice id on stdout; `QIE_EVENT` `rendering` progress
(index/total) on stderr. Stateless, writes only to work-dir. Existing commands untouched.
**Success**: N valid AIFFs, frame counts match requested ranges, markers rebased+renumbered,
result keyed by id, nothing written beside the source, progress in order.
**Tests**: `tests/test_render.py` (tiny hand-built WAV + request; no WhisperX/models).
**Status**: Complete

## Stage 2: Swift render types + `EngineClient.renderSlices` + `LiveEngine.render`
**Goal**: `RenderRequest`/`RenderMarker`/`RenderSliceSpec`/`RenderEvent`/`RenderProgress`/
`RenderedSlice`; `EngineClient.renderSlices` (streaming/cancellable/mockable, mirrors
`transcribe`); `LiveEngine.render` writes `request.json`, spawns, streams progress,
decodes result on exit 0, cleans up work-dir on failure/cancel only.
**Success**: testValue fails cleanly; previewValue yields fixture; decode maps results by id.
**Tests**: `EngineClientTests` render cases (testValue/previewValue).
**Status**: Not Started

## Stage 3: `WorkspaceClient` + pure export-naming function
**Goal**: `Core/WorkspaceClient.swift` (`chooseDirectory` + `reveal`, Sendable, mockable);
`Models/ExportNaming.swift` pure `exportFileName(...)` — `<stem> - <sanitized name>.aiff`,
zero-padded `Slice NNN` fallback, collision suffixes ` 2`, ` 3`, … case-insensitively.
**Success**: sanitization strips separators/illegal chars; collisions resolved vs a taken set.
**Tests**: `Models/ExportNamingTests.swift` (pure).
**Status**: Not Started

## Stage 4: `EditorModel` export flow
**Goal**: `ExportPhase`, `destinationURL`, `exportSliceTapped`, `exportAllTapped`,
`cancelExportTapped`; ensure destination (prompt if nil) → build `RenderRequest` →
consume `renderSlices` → copy temp AIFFs → destination (naming) → `reveal`; carry
tight-join warnings into the summary; cancel kills the group + deletes temp, reports partial.
**Success**: exportPhase walks exporting→done; results mapped by id; reveal called with
copied URLs; missing-destination prompts; throwing stream → failed.
**Tests**: `EditorTests` export cases (engine + workspace mocked; real temp-dir copy).
**Status**: Not Started

## Stage 5: Wire Export / "Export all" buttons + full gate
**Goal**: per-slice **Export** + **"Export all"** + cancel/progress into
`SlicesPanelView`/`EditorView` (all copy/flags from the model); `xcodegen generate`;
green `xcodebuild test`, `make lint`, `make format-check`, `python3 -m pytest -q`.
**Success**: no dead controls; all local gates green; Codex adversarial pass clean.
**Status**: Not Started
