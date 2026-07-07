# Phase 1 — Packaging Spike: Design

**Date:** 2026-07-07
**Branch:** `briankeane/phase1-packaging-spike`
**Status:** Approved (driven through Codex consult session `019f3c8c-…`)
**Roadmap:** `plans/roadmap-macos-app.md` → "Phase 1 — Packaging spike", decisions 1 & 6.

## Goal

Prove — and wire up — a shippable path: the Python engine (`logic_markers/`,
torch + WhisperX + faster-whisper) packaged inside a signed, notarized macOS
`.app` that runs a real transcription on a **clean Mac with no dev environment**.

Success criterion: a notarized build transcribes audio with **no `.venv`, no
`QIE_ENGINE_REPO`, no Homebrew Python, no network** (models already present).

This is a **spike**: bias toward proving the risky unknowns end-to-end over
polish, while leaving the engine-resolution seam clean and tested.

## What the spike must retire (risk, ranked)

1. **Can we freeze the torch/CTranslate2 ML stack and run it?** (highest unknown)
2. **Can we run it fully offline** from pre-downloaded model files? WhisperX has
   two implicit runtime downloads that must be removed.
3. **Can we sign + notarize** the app with all nested Mach-O binaries?
4. Engine-resolution seam that prefers the bundled helper but keeps the dev
   `.venv` workflow working (parallel waveform effort depends on it).

## Key facts established (verified on disk, not assumed)

- Engine entry: `python -m logic_markers.cli {plan|render}`. Heavy imports
  (`whisperx`, `torch`) are lazy. stdout is pure JSON; progress is stderr
  `QIE_EVENT {json}` lines. Audio decode uses system `afconvert` (no ffmpeg).
- **Models are two artifacts, from two mechanisms** (Codex corrected an earlier
  wrong assumption that both came from HuggingFace):
  - **ASR:** `Systran/faster-whisper-large-v2` CTranslate2 model in the HF hub
    cache — files `config.json`, `model.bin` (~3.0 GB), `tokenizer.json`,
    `vocabulary.txt`. MIT-licensed.
  - **Alignment (English):** WhisperX 3.8.6 maps `en` to **torchaudio**
    `WAV2VEC2_ASR_BASE_960H`, downloaded by torch hub to
    `TORCH_HOME/hub/checkpoints/wav2vec2_fairseq_base_ls960_asr_ls960.pth`
    (~377 MB). MIT-licensed. **Not** an HF wav2vec2 repo.
- **Two implicit runtime downloads must be eliminated** (they'd be "downloading
  code/data post-notarization" and would fail offline):
  - `whisperx/alignment.py:194` calls `nltk.download('punkt_tab')` when the NLTK
    tokenizer isn't already on disk. Fix: **bundle `punkt_tab` as data** in the
    frozen engine and point `NLTK_DATA` at it.
  - `whisperx.load_model("large-v2")` / `load_align_model("en")` fetch weights
    when absent. Fix: **explicit local model dirs + offline env** (below).
- WhisperX ships data assets that PyInstaller won't auto-collect:
  `whisperx/assets/{mel_filters.npz,pytorch_model.bin}` (the VAD model).
- Signing identity present: **`Developer ID Application: Playola Radio
  (FSRSPV9N9Q)`**. Notarization credentials (notarytool) are **not** configured
  in this environment → notarize/staple is scripted + documented but can't be
  executed here (documented gap).

## Architecture

### 1. Packaging: PyInstaller one-folder

Freeze the engine with **PyInstaller one-folder** (`--target-arch arm64`),
driven by a checked-in `packaging/engine.spec`, producing
`dist/logic-markers-engine/` (a `logic-markers-engine` executable + `_internal/`
tree of torch/ctranslate2/torchaudio `.so`/`.dylib`). A thin entry module calls
`logic_markers.cli.main()`.

The spec uses `collect_all` for the packages PyInstaller under-collects
(`torch`, `torchaudio`, `ctranslate2`, `faster_whisper`, `whisperx`,
`transformers`, `tokenizers`, `huggingface_hub`, `nltk`), plus explicit
`whisperx/assets` and pre-downloaded `nltk_data/punkt_tab`.

**Codex's caveat, recorded:** PyInstaller is acceptable for the spike but not
necessarily the final strategy — a `python-build-standalone` + installed-wheels
relocatable venv preserves normal package layout and is often more robust for
torch. We proceed with PyInstaller to retire the risk fast; if it proves
fragile, the seam (below) makes swapping the packaging mechanism a one-file
change. This is logged as a follow-up, not a blocker.

The `.app` bundles the folder at `Contents/Resources/engine/`. For the spike the
bundling is a **documented, scripted build step** (`packaging/package-engine.sh`
+ `packaging/build-app.sh`) rather than an Xcode "Run Script" phase, so the slow
(multi-GB) freeze doesn't run on every `xcodebuild test`. Wiring it into an
Archive-only build phase is a Phase 6 concern.

### 2. Engine resolution seam (Swift)

Extract engine resolution from `LiveEngine` into a pure, testable unit that
returns a **spawn plan** — `(executable: URL, argumentPrefix: [String])` — not
just a path (Codex's suggestion; avoids special-casing in `transcribe`/`render`):

- **Bundled helper** (production): `Bundle.main.resourceURL/engine/logic-markers-engine`,
  if present + executable → `(that, [])`. The subcommand (`plan`/`render`) and
  its args are appended by the caller.
- **Dev fallback**: the current `.venv/bin/python` resolved via `QIE_ENGINE_REPO`
  or `#filePath` → `(python, ["-m", "logic_markers.cli"])`.

Resolution order: env override for tests → bundled helper → dev `.venv`. The
probe (does-this-file-exist-and-is-executable) is injected so unit tests never
touch the filesystem or spawn a subprocess. `transcribe`/`render` build
`argumentPrefix + [subcommand] + args`.

### 3. Offline model contract (Python)

Add a small `logic_markers/model_config.py` and thread it through
`whisperx_backend.py`:

- New env read by the engine: `QIE_WHISPER_MODEL_DIR` (absolute CT2 model dir),
  `QIE_ALIGN_MODEL_DIR` (dir containing the align `.pth`), `QIE_OFFLINE=1`.
- When `QIE_WHISPER_MODEL_DIR` is set, call
  `whisperx.load_model(model_dir=…, download_root=…)` with the absolute path
  instead of the bare `"large-v2"` name.
- When `QIE_ALIGN_MODEL_DIR` is set, set `TORCH_HOME` so torch hub finds the
  pre-placed `.pth` (no download), and set `NLTK_DATA` to the bundled punkt_tab.
- When `QIE_OFFLINE=1`, export `HF_HUB_OFFLINE=1` + `TRANSFORMERS_OFFLINE=1`
  before the heavy import so no library phones home.
- **Dev behavior is unchanged**: with none of these set, the engine downloads to
  the default caches exactly as today. This keeps the parallel dev workflow and
  the fixture-regen script working.

The env→config mapping is pure and unit-tested with pytest (no torch needed).

### 4. First-launch model download (Swift)

- `ModelManifest`: the exact file list per model (relative path, absolute
  HuggingFace/torch-hub URL, SHA-256, byte size). Checked-in, versioned data.
- `ModelDownloadClient` (`swift-dependencies` client): downloads each file with
  `URLSession` download tasks, **resumable** (persist `resumeData` on
  interruption), **checksummed** (SHA-256 verified before marking complete),
  into `~/Library/Application Support/Quick Interview Editor/Models/`. Atomic
  move into place only after checksum passes.
- `ModelDownloadModel` (`@Observable`, `@MainActor`): holds progress
  (bytes/total, per-file, phase), error state, and **all display text +
  derived flags as view helpers** (no logic in the view). Actions:
  `viewAppeared()`, `retryTapped()`, `cancelTapped()`.
- The downloaded dir is passed to the engine via the `QIE_*` env above. Weights
  are **data** (loaded by model loaders), satisfying decision 6.
- Tested against a stubbed client (immediate resolution; no network).

### 5. Signing + notarization

- `packaging/engine.entitlements` + `packaging/app.entitlements`. Start
  **strict**; the only likely addition is
  `com.apple.security.cs.disable-library-validation` on the **helper** (the
  process that loads torch dylibs) — needed only if any nested dylib isn't
  Team-signed. We sign every nested Mach-O with our Developer ID, so we try
  without it first and add only if a runtime crash log proves it necessary. We
  do **not** add `allow-jit`, `allow-unsigned-executable-memory`, or
  `allow-dyld-environment-variables` (the `QIE_*`/`HF_*`/`TORCH_HOME`/`PYTHONPATH`
  env we set are not `DYLD_*`).
- `packaging/sign-app.sh`: sign nested Mach-O **inside-out, individually**
  (`--force --options runtime --timestamp`), then the helper (with
  entitlements), then the app. `--deep` is used only for **verification**
  (`codesign --verify --strict --deep`), never construction. Re-sign happens
  after PyInstaller (which invalidates signatures) and after copying into the
  `.app`; `_internal/` is never mutated post-signing.
- `packaging/notarize-app.sh`: `notarytool submit --wait` + `stapler staple`.
  Requires notarytool credentials (App Store Connect API key or app-specific
  password) — **documented; not runnable in this environment**.

## Verification plan (no second physical Mac)

Prove the clean-env run with a scrubbed environment (Codex's cheapest check):

```bash
env -i HOME="$TMPDIR/qie-fresh-home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  QIE_WHISPER_MODEL_DIR=… QIE_ALIGN_MODEL_DIR=… QIE_OFFLINE=1 \
  dist/logic-markers-engine/logic-markers-engine plan sample.wav --work-dir …
```

`env -i` drops the dev shell env (no `.venv`, no `QIE_ENGINE_REPO`), a fake
`HOME` proves no reliance on `~/.cache`, and offline env proves no network. Plus
`codesign --verify --strict --deep --verbose=4`, `spctl -a -vvv -t exec`,
`otool -L` on the helper. `spctl`/notarization acceptance can't be fully proven
without notarytool creds → documented gap.

## Non-goals (this spike)

Intel builds, App Store, Sparkle auto-update, an Xcode Archive build phase for
the engine, CI notarization secrets, and the licensing audit (noted as a
distribution-hardening follow-up). safetensors migration for the align model is
noted (torch `.pth` uses pickle; untrusted-input risk) but out of scope.

## Stages

1. Offline model contract in the engine (Python) + pytest.
2. PyInstaller spec + package script; **verify frozen `plan` runs offline**.
3. LiveEngine resolution seam + Swift tests.
4. Signing/notarization scripts + entitlements; sign + verify locally.
5. Swift model-download client + `@Observable` model + tests.
6. Verify, Codex review + challenge, PR.
