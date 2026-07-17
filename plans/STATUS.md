# Quick Interview Editor — Status & Checklist

Living status doc. Pairs with `plans/roadmap-macos-app.md` (the phase plan) — this
tracks what's actually shipped and what's next. Update as PRs land.

_Last updated: 2026-07-17 (Phase 5 PR 3 — fine-tune drag — implemented)._

---

## ✅ Done

### Engine (Python `logic_markers/`)
- [x] WhisperX transcription + wav2vec2 forced alignment; silence-aware chunking; AIFF `MARK` writer; `edit-plan.json` contract. (pre-app baseline)
- [x] `plan` subcommand — analyze-only, pure-JSON `EditPlan` on stdout, `QIE_EVENT` progress on stderr. (PR #3/#4)
- [x] `render` subcommand — stateless, request-file driven, per-slice AIFFs keyed by id, marker rebasing, id/range validation. (PR #7)

### macOS app (`QuickInterviewEditor/`)
- [x] **Transcript page** — plan-driven word rendering, two-click selection, run-together "red" tight-join reading aid. (Steps 1–2, PRs #1–#4)
- [x] **Import + live engine** — drag/open audio → transcribe via spawned subprocess, streaming progress, cancel, tabbed songs. (Step 2, PR #4)
- [x] **Slices panel (3a)** — `Slice` sample-native model, tight-join warnings from silences, create/rename/reorder/delete/play. (PR #5)
- [x] **QA-fixes batch** — copyable errors, pure-JSON stdout fix, AVAudioEngine actor + per-run logging, full-slice playback, middle-truncated snippets, panel polish. (PR #6)
- [x] **Export/reveal (3b)** — `EngineClient.renderSlices` + `LiveEngine.render`, `WorkspaceClient`, sanitized/collision-safe filenames, export flow (per-slice + Export all, progress/cancel), tight-join warnings in summary. (PR #7)
- [x] **Packaging spike (Phase 1)** — PyInstaller one-folder engine freeze, `EngineResolver` (bundled helper → dev `.venv` fallback), first-launch model download to Application Support (resumable, SHA-256), inside-out code-signing + hardened runtime. (PR #8)
- [x] **Read-only waveform sync (Phase 4)** — `WaveformClient` (AVAssetReader → mono/resample → vDSP min/max peak pyramid), `WaveformModel` (sample↔pixel math, zoom, pan, hit-testing), two-way word↔waveform sync, red tight-join bands, live playhead via `AudioPlayerClient.positions`. (PR #9)
- [x] **Canonical AIFF foundation (Phase 5 PR 1)** — one canonical PCM AIFF at plan rate backs waveform + playback + render; `plan` keeps `<stem>.plan.aiff` (verifies COMM rate), `render` slices it directly (no reconvert; verifies rate/frames/duration); `CanonicalAudioStore` in Caches, `TranscriptionResult{editPlan, canonicalAudioURL}`. Closes the playhead-vs-pyramid drift. (PR #10)

---

## 🔜 Next — pick up here

### Phase 5 — Interactive cut editing (drag the cuts)
Design: `docs/superpowers/specs/2026-07-07-phase5-interactive-cut-editing-design.md` (Codex-reviewed). Three PRs:
- [x] **PR 1 — Canonical AIFF foundation.** (PR #10, merged)
- [x] **PR 2 — Undo/redo over slice mutations.** (PR #11) `UndoStack<IdentifiedArrayOf<Slice>>` value type (bounded, validated limit); every slice mutation routed through one `mutateSlices` helper that snapshots + records; add/delete/rename/reorder rewritten through it; multi-row delete batched into one entry; redo cleared on new record; `undoTapped`/`redoTapped` + `reconcilePlayback` (stops playback if the playing slice is gone); Undo/Redo buttons in the panel. **`activeSliceID` reconcile deliberately deferred to PR 3** — a `TODO(PR 3)` seam is left in `reconcilePlayback`.
- [x] **PR 3 — Fine-tune drag editing.** Pure snap/range/clamp/word helpers (`FineTuneGeometry`); `FineTuneModel` (fixed committed-centered ±0.5 s inset geometry, magnetic snap to silence edges filtered to the legal boundary interval, live red via `sliceWarnings`, ±10 ms nudge, safe-zone spans, midpoint word re-derivation); two dumb inset views (Cut in / Cut out). `EditorModel` glue: new `activeSliceID` (distinct from `playingSliceID`) wired into the PR-2 `reconcilePlayback` seam; a whole drag commits as exactly one `mutateSlices` (one undo entry) with re-derived `wordIDs`/`snippet`; export + undo/redo gated on an uncommitted existing-slice edit; transcript selection retargets the pane; preview-edit plays the draft range with a distinct playback identity. Hardened via 13 rounds of Codex adversarial review (session/preview lifecycle, EOF clamp, generation-guarded preview).

### Phase 6 — Distribution hardening (ship to real users)
- [ ] **Notarization** — the only step between the packaging spike and a clean-Mac Gatekeeper pass. `packaging/notarize-app.sh` is written; needs notarytool credentials (App Store Connect API key or app-specific pw) configured. `spctl` currently reports `Unnotarized Developer ID`. **Small, high-value, independent — can be done anytime.**
- [ ] Sparkle auto-update integration.
- [ ] Crash/error reporting.
- [ ] Model-manager UI + onboarding/progress/error UX (the first-launch download currently has model hooks but no polished UX).
- [ ] Licensing audit (WhisperX, pyannote, torch, model weights) before commercial distribution.
- [ ] (Optional) Intel support; native (MLX/CoreML) inference research, gated on a word-boundary-error benchmark.

---

## 🧹 Cross-cutting follow-ups (not blocking, fold in when relevant)
- [x] ~~Canonical working AIFF (roadmap decision 4)~~ — done in Phase 5 PR 1 (PR #10); playhead drift closed.
- [ ] Disk-cached peak pyramids + RMS band (deferred from Phase 4; matters for long interviews / reopening).
- [ ] `PlayolaAlert` modal error type — 3b surfaced export errors as inline status text; a modal alert type can land with the broader error-UX work (Phase 6).
- [ ] Offline model path is **English-only** for the spike — multi-language align model download is a later item.
- [ ] **Global Cmd+Z / Cmd+Shift+Z** for undo/redo (CodeRabbit suggestion on PR #11, deferred). Needs focus-aware first-responder handling so it doesn't shadow the slice-rename field's native in-field undo — polish item, not a one-liner.

---

## Recommendation
1. **Phase 5 PR 2 — Undo/redo** — next; ships value on its own and de-risks the stack before drag.
2. **Phase 5 PR 3 — Fine-tune drag editing** — the marquee interaction; needs PR 2's undo stack.
3. **(Anytime, independent) Finish notarization** — turns the packaging spike into an actually-installable app.

Phase 6 (distribution hardening) is independent of Phase 5 and could run in parallel
(separate worktree), same as Phase 1 ‖ Phase 4 did.
