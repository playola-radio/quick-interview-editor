# Roadmap: Quick Interview Editor — macOS app

Long-term plan from today's working CLI engine to a downloadable desktop app.
Architecture reviewed with Codex (2026-07-03).

## Vision

A downloadable, auto-updating macOS app for non-technical users that cuts a long
spoken-word interview into Logic Pro-ready chunks. The user edits the interview
**two synchronized ways at once**:

1. a **transcript view** (edit/delete text, mark splits), and
2. a **waveform view** (see the audio, zoom, drag cut points).

Selecting words highlights the matching audio in the waveform and vice-versa.
**Words that run together** — a cut boundary with no silence between chunks
(our `padded` boundary status) — are shown in **red**, so the user knows those
joins are tight and need a fade. Output is the same set of AIFFs with embedded
word markers, ready to drag into Logic.

## Current state (done)

A working, tested Python CLI (`logic_markers/`) that already does the hard parts:

- WhisperX transcription + wav2vec2 **forced alignment** → accurate per-word
  start/end times.
- `transcript` command → editable `[n]`-tagged transcript.
- `cut` command → silence-aware chunking into AIFFs that never clip a word;
  tight ends get a fade tail; splits exclude deleted audio.
- Byte-level AIFF `MARK` writer Logic imports.
- Versioned `edit-plan.json` — the seam the app will build on.
- 58 tests; Codex-reviewed.

## Architecture decisions

1. **The Python engine stays; the app is a separate process that drives it.**
   The SwiftUI app spawns a packaged `logic-markers-engine` helper and talks to
   it as **JSON over stdio** (move to a local socket only if we later need
   long-lived sessions or cancellation). Pass **file paths and job IDs, not
   audio blobs**. The engine stays a boring, deterministic, replaceable function:
   `audio + edit-plan → resolved plan + AIFFs`.

2. **Don't rewrite inference natively yet.** We specifically need wav2vec2
   forced alignment for the "never clip a word" promise; `whisper.cpp` word
   timestamps aren't a substitute. A native (MLX/CoreML) path is a *later*
   optimization, gated on a word-boundary-error benchmark, not just WER.

3. **`edit-plan.json` is the contract.** All interactivity (selection, zoom,
   drag, undo/redo) lives in Swift app state. The engine only analyzes and, on
   export, **revalidates and renders**. Swift computes live snap previews from
   the same silence data the engine produced.

4. **One canonical audio file.** The engine produces/imports a canonical PCM
   AIFF; the app renders that exact file so Swift and the engine **agree on
   sample coordinates**. Sample drift between the waveform and the render would
   destroy user trust — this is the guardrail against it.

5. **Waveform is built in-house.** `AVAssetReader` for PCM + `Accelerate/vDSP`
   to build multi-resolution min/max/RMS peak pyramids, rendered in a custom
   `NSViewRepresentable`/`Canvas` (Metal only if long interviews demand it).
   Everything modeled in **samples**. Existing waveform libraries are
   preview/playback tools, not precise editors.

6. **Distribution: Apple Silicon first, direct download + Sparkle auto-update,
   notarized.** Not the App Store (sandbox + model-size friction). Every nested
   binary/`.dylib`/`.so`/Python framework must be signed; hardened runtime +
   notarization will surface anything missed. Models download on first launch
   into Application Support (**data, not code** — never download executable code
   post-notarization), resumable + checksummed. Intel only if demand proves it.

## Phases (ordered to de-risk early)

### Phase 1 — Packaging spike (highest unknown, do first)
**Goal:** prove we can ship the engine inside a signed app.
- Package the current CLI as a helper binary (PyInstaller **one-folder**, not
  one-file).
- A toy SwiftUI app spawns it, sends a job over stdio, gets `edit-plan.json` back.
- Code-sign + notarize the whole bundle incl. nested torch/`.so` libraries.
- Verify first-launch model download + cache path in Application Support.
**Success:** notarized toy app runs a real transcription on a clean Mac.
**Risk it retires:** Python/PyTorch distribution — likely the project's biggest.

### Phase 2 — Contract hardening
**Goal:** make `edit-plan.json` a durable, sample-accurate API.
- Add: source fingerprint, sample rate/channels/duration, engine + model
  versions, per-word confidence + alignment status, silence regions (samples),
  boundary candidates + snap metadata, boundary status
  (`snapped|padded|manual|invalid`), fade requirements, warnings.
- Canonical working-AIFF creation the UI will render.
- Golden fixtures for `snapped` and `padded` cases.

### Phase 3 — Smallest useful app (no waveform yet)
**Goal:** kill the Terminal. Real value with the least surface.
- Drag audio in → transcribe → editable transcript/chunks list.
- **Tight (`padded`) joins shown in red** in the transcript.
- Export Logic-ready AIFFs; reveal in Finder.
**Success:** a non-technical user chunks an interview without a command line.

### Phase 4 — Read-only waveform sync
**Goal:** see the audio alongside the words.
- Render zoomable waveform from the canonical AIFF.
- Click a word → highlight its audio range; click the waveform → highlight words.
- Playback + zoom. Red still marks tight joins, now in the waveform too.

### Phase 5 — Interactive editing
**Goal:** drag the cuts.
- Draggable boundary handles (sample indices) that **snap to the same silence
  regions** the engine uses; live red state when no legal silent gap exists.
- Undo/redo in app state. Engine revalidates and renders final AIFFs on export.

### Phase 6 — Distribution hardening
- Sparkle updates, crash/error reporting, model manager, onboarding + progress +
  error UX, licensing audit, optional native-inference research.

## The "run-together words" (red) feature

The engine already emits per-segment boundary status: `snapped` (a real silence
gap) vs `padded` (a tight join, no silence — the fade tail was added). In the
app, the words on either side of a `padded` join render **red** in both the
transcript and the waveform. This is the user's cue that the chunks stick
together and the join needs a manual fade in Logic. No new engine analysis is
needed — the data already exists in `edit-plan.json`; the app maps status → color.

## Risks / open questions

- **Python/PyTorch distribution may dominate the project** more than the UI.
  Phase 1 exists to confront it first.
- **Sample drift** between the Swift waveform and the Python render would break
  trust — the canonical-AIFF rule (decision 4) is the mitigation.
- **Forced alignment can look more precise than it is** — surface confidence and
  warnings; don't present cut points as ground truth.
- **Long interviews** punish naive waveform rendering/memory — peak pyramids +
  windowed loading from Phase 4.
- **Licensing audit** (WhisperX, pyannote, torch, model weights) needed before
  commercial distribution.
- **"A fade fixes a tight join" is only partly true** — sometimes the edit is
  just in a bad spot; the app should make the cut easy to move, not only to fade.

## Deferred / out of scope (for now)

Native (MLX/CoreML) inference, Intel builds, App Store, mid-sentence splice
editing, multi-speaker diarization, cloud processing. The JSON contract leaves
room for these; none are on the critical path to the first useful app.
