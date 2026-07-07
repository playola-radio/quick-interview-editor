# Packaging the engine into a signed, notarized macOS app

This directory holds the Phase 1 "packaging spike" toolchain: it freezes the
Python engine (`logic_markers/`) into a self-contained helper, embeds it in the
SwiftUI app, and signs + notarizes the result so it runs on a clean Mac with no
dev environment. Apple Silicon only for the spike.

See `docs/superpowers/specs/2026-07-07-phase1-packaging-spike-design.md` for the
design and the Codex review that shaped it.

## The pipeline

```
packaging/package-engine.sh    # 1. PyInstaller one-folder freeze -> dist/logic-markers-engine/
packaging/verify-offline.sh …  # 2. prove the frozen engine transcribes offline (no dev env)
packaging/build-app.sh         # 3. build the .app + embed the engine at Resources/engine/
packaging/sign-app.sh …        # 4. inside-out Developer ID + hardened-runtime signing
packaging/notarize-app.sh …    # 5. notarize + staple  (needs notarytool credentials)
```

### 1. Freeze the engine — `package-engine.sh`

Runs PyInstaller against `engine.spec` using a venv that has the engine deps +
PyInstaller (`VENV=/path/to/.venv packaging/package-engine.sh`, default
`~/playola/logic-utils/.venv`). Produces
`packaging/dist/logic-markers-engine/` (~850 MB): a `logic-markers-engine`
executable + an `_internal/` tree of torch/ctranslate2/torchaudio native libs
and package data.

Key spec details (`engine.spec`):
- `collect_all` for the packages PyInstaller under-collects (torch, torchaudio,
  ctranslate2, faster-whisper, whisperx, transformers, pyannote, …).
- WhisperX ships its VAD weights + mel filters in `whisperx/assets` — collected
  explicitly.
- **Bundled NLTK `punkt_tab`**: WhisperX alignment calls `nltk.download()` at
  runtime if the tokenizer is missing. We stage it at build time and ship it as
  static data (`engine_entry.py` points `NLTK_DATA` at it) so the frozen engine
  never hits the network.

### 2. Prove it runs offline — `verify-offline.sh`

The spike's success criterion. Stages the model files into the layout the app
builds in Application Support, then runs the frozen `plan` command under
`env -i` with a fake `HOME`, no dev env, and `QIE_OFFLINE=1`:

```
packaging/verify-offline.sh ~/path/to/sample.m4a
```

`env -i` drops the dev shell (no `.venv`, no `QIE_ENGINE_REPO`), the fake `HOME`
proves nothing relies on `~/.cache`, and the offline env proves no network. This
is the cheapest way to simulate a clean Mac without a second machine.

### 3–4. Assemble + sign — `build-app.sh`, `sign-app.sh`

`build-app.sh` builds `QuickInterviewEditor.app` (Release, unsigned) and copies
the frozen engine into `Contents/Resources/engine/`. `sign-app.sh` then signs
**inside-out**: every nested Mach-O (`.so`/`.dylib`) first, then the helper
(with `engine.entitlements`), then embedded frameworks, then the app (with
`app.entitlements`) — each `--options runtime --timestamp`. `--deep` is used
only for the final verify, never construction.

Entitlements start **strict**. `engine.entitlements` carries only
`com.apple.security.cs.disable-library-validation` (a frozen multi-dylib Python
helper almost always needs it; we re-sign every nested lib with our Developer ID
so Team IDs match). If a clean-Mac run crashes on executable memory / ctypes
trampolines, add `allow-unsigned-executable-memory` (+ `allow-jit`) and re-sign —
the file documents this. We do **not** add `allow-dyld-environment-variables`;
the `QIE_*`/`HF_*`/`TORCH_HOME`/`PYTHONPATH` env we set are not `DYLD_*`.

### 5. Notarize — `notarize-app.sh`

`notarytool submit --wait` + `stapler staple`. Requires credentials (a stored
keychain profile or an App Store Connect API key) — see the script header.

## How the app finds the engine

`EngineResolver` (Swift) prefers the bundled helper at
`Resources/engine/logic-markers-engine`; if it's absent it falls back to the dev
`.venv` (`QIE_ENGINE_REPO`/`#filePath`). So the same build runs packaged for
users and against the dev engine for development. When bundled, `LiveEngine`
passes the downloaded model dirs to the engine via `QIE_WHISPER_MODEL_DIR` /
`QIE_ALIGN_MODEL_DIR` / `QIE_OFFLINE=1`.

## Models are data, not code

The app downloads the model weights on first launch into
`~/Library/Application Support/Quick Interview Editor/Models/` (see
`ModelManifest`), resumable + SHA-256 checksummed. Weights are **data** loaded
by faster-whisper / torchaudio — never executable code shipped or fetched after
notarization (roadmap decision 6):

- `Systran/faster-whisper-large-v2` (CTranslate2, MIT) — pinned HF revision.
- torchaudio `WAV2VEC2_ASR_BASE_960H` English align model (MIT).

## Gotchas

- **Running the in-app engine invalidates the app signature.** `verify-offline.sh`
  defaults to the standalone `dist/logic-markers-engine/` binary. If you point it
  at the engine *inside* a signed `.app`, first import may write bytecode/caches
  into the sealed bundle and `codesign --verify` will then report "code or
  signature have been modified". Verify against the standalone engine, and always
  sign (and notarize) **after** any in-place run.
- **Offline is English-only for the spike.** The manifest ships only the English
  torchaudio align model, and the engine passes `model_cache_only=offline`, so a
  non-English detected language fails clearly offline rather than downloading an
  undeclared model. Shipping more languages = adding align files to the manifest.
- **The installed-check is size-only for speed.** `installedLocation` trusts the
  per-version `.complete` sentinel + file sizes rather than re-hashing gigabytes
  on every launch; SHA-256 is verified at download time before the sentinel is
  written. Change a file's bytes without a `ModelManifest.version` bump and it can
  read as installed — so bump the version whenever a checksum changes.

## Known gaps (spike)

- **Notarization** can't be executed wherever notarytool credentials aren't
  configured; the script + flow are ready, but a clean-Mac Gatekeeper check
  (`spctl --assess`) needs a real notarized build.
- Intel (x86_64) builds, an Xcode Archive build phase for the engine, CI
  notarization secrets, and the licensing audit are Phase 6 concerns.
- PyInstaller was chosen to retire risk fast; a `python-build-standalone`
  relocatable venv may be a more robust final strategy (the resolution seam
  makes swapping it a one-file change).
