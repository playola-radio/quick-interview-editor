# Implementation Plan — Per-phase progress ("Phase X of N · label · NN%")

Design: `docs/superpowers/specs/2026-08-13-per-phase-progress-design.md`

TDD throughout. Each stage compiles + both suites green before commit.
`python3 -m pytest -q` for Python; XcodeGen build + test for Swift; `make lint`.

## Stage 1: Engine — per-phase emission
**Goal**: `plan` emits self-describing per-phase progress (index/count/label,
per-phase fraction); phase 3 finalize carries metadata; stdout stays pure.
**Changes**:
- `whisperx_backend`: stage-tagged `progress_callback(stage, fraction)`; stop folding.
- `cli.py`: `_ProgressEmitter` → `_PhaseEmitter(index,count,phase,label)`; `_progress`
  gains index/count/label; `run_plan` wires phase-1/2 emitters + phase-3 finalize;
  stage router.
**Tests**: `_PhaseEmitter` (throttle/monotonic/finish-only-if-emitted/skip-no-fake-100),
stage router → correct events, backend stage-tagged callback, run_plan phase-3
metadata, stdout purity.
**Status**: Not Started

## Stage 2: App — decode + phase-agnostic state
**Goal**: decode new fields leniently (never drop unknown phase); model derives
phase-of-N, label fallback, determinacy-by-fraction, hardened clamp.
**Changes**: `EngineEvent.swift` (`EngineProgress` raw string + optional metadata),
`LiveEngine.swift` (decode, no unknown-phase drop, `null`==absent fraction),
`SongTabModel.swift` (`phaseOfNText`, `phaseLabel`, clamp reset on forward change +
ignore lower index).
**Tests**: `EngineEventTests` (new fields, unknown-phase renders, null fraction,
malformed metadata), `SongTabTests` (phase-of-N, label fallback, determinacy,
clamp reset + stale-index ignore, old-event compat).
**Status**: Not Started

## Stage 3: App — per-phase ETA + view line
**Goal**: replace 0.5-split ETA with per-phase estimate; render the phase line.
**Changes**: `SongTabModel.swift` (per-phase elapsed reset on phase change, ETA
thresholds/wording), `SongTabView.swift` (phase-of-N · label · NN% line).
**Tests**: `SongTabTests` ETA thresholds + wording ("in this phase"), indeterminate → no ETA.
**Status**: Not Started

## Stage 4: Verify + adversarial review
**Goal**: full green + Codex review/challenge on the diff.
**Steps**: `make lint`, both suites, Codex review (pass/fail) + challenge; fix findings.
**Status**: Not Started
