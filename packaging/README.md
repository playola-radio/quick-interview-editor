# Packaging the engine into a signed, notarized macOS app

This directory holds the Phase 1 "packaging spike" toolchain: it freezes the
Python engine (`logic_markers/`) into a self-contained helper, embeds it in the
SwiftUI app, and signs + notarizes the result so it runs on a clean Mac with no
dev environment. Apple Silicon only for the spike.

See `docs/superpowers/specs/2026-07-07-phase1-packaging-spike-design.md` for the
design and the Codex review that shaped it.

## The pipeline

```text
packaging/package-engine.sh          # 1a. PyInstaller freeze -> dist/logic-markers-engine/
packaging/package-cut-suggester.sh   # 1b. PyInstaller freeze -> dist/cut-suggester-engine/
packaging/verify-offline.sh …        # 2a. prove the frozen engine transcribes offline (no dev env)
packaging/verify-cut-suggester.sh    # 2b. prove the frozen cutter runs a real suggest (no dev env)
packaging/build-app.sh               # 3. build the .app + embed BOTH helpers at Resources/engine/
packaging/sign-app.sh …              # 4. inside-out Developer ID + hardened-runtime signing
packaging/notarize-app.sh …          # 5. notarize + staple  (needs notarytool credentials)
```

The app ships **two** frozen Python helpers, both under `Contents/Resources/engine/`:
the heavy `logic-markers-engine` (whisperx transcription) and the light
`cut-suggester-engine` (the LLM cut-suggester). Build each with its own
`package-*.sh`; `build-app.sh` embeds both.

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

### 1b. Freeze the cut-suggester — `package-cut-suggester.sh`

The second helper is tiny next to the engine. `cut_suggester/cli.py suggest`'s whole
runtime is CPython stdlib plus the `anthropic` SDK (lazy-imported on the Anthropic
provider path); the OpenAI path is stdlib `urllib`. No torch/whisperx/numpy. So this
freeze is fast and small.

Key spec details (`cut-suggester.spec`):
- `contents_directory="_cut_suggester_internal"` — the support tree is deliberately
  **not** `_internal`, so this bundle can ditto INTO the same `Resources/engine/`
  folder as `logic-markers-engine` (whose libs live in `_internal/`) without
  colliding. The only top-level artifact is the `cut-suggester-engine` executable,
  which lands at exactly `Resources/engine/cut-suggester-engine` — the path the Swift
  `CutSuggesterResolver` seam already expects.
- `collect_all` + `copy_metadata` for the `anthropic` stack (pydantic/pydantic_core,
  httpx/httpcore, anyio, jiter, certifi, …). The metadata matters: the SDK does
  `importlib.metadata.version(...)` checks at import; `certifi`'s CA bundle is
  collected as data so live HTTPS works from inside the frozen bundle.
- One-folder (not one-file): `pydantic_core` and `jiter` are native `.so` modules,
  and one-file extracts unsigned native code to a temp dir at runtime — the same
  hardened-runtime problem the engine avoided. One-folder lets `sign-app.sh` sign
  every nested Mach-O inside-out.

The build's `--help` smoke never touches `anthropic` (it's lazy), so the script also
runs a keyless `suggest` against a `claude-*` model: it reaches `import anthropic` and
the client construction, then fails cleanly on the missing key. That proves the SDK
actually froze into the bundle (a missing SDK would raise `No module named 'anthropic'`
instead).

`verify-cut-suggester.sh` then runs a REAL suggest from the frozen binary under a
scrubbed `env -i` (no `.venv`/`QIE_ENGINE_REPO`/`PYTHONPATH`), forwarding only the LLM
key. The two providers exercise **different** runtime stacks — OpenAI is stdlib
`urllib`+OpenSSL, Anthropic is httpx+certifi — so a full release check runs it **twice**:

```
packaging/verify-cut-suggester.sh                        # OpenAI path (needs OPENAI_KEY)
MODEL=claude-sonnet-5 packaging/verify-cut-suggester.sh  # Anthropic path (needs ANTHROPIC_API_KEY)
```

TLS is the frozen-only trap here: a frozen bundle's default OpenSSL CA path is the
build machine's, which won't exist on a user's Mac. `cut_suggester_entry.py` wires
`SSL_CERT_FILE` to the bundled certifi CA when frozen so both paths verify certificates
on a clean Mac — but only the post-signing/stapling run against each provider actually
proves it, which is why the release check covers both models.

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

## Release pipeline (DMG + Sparkle self-update)

Beyond the signed `.app`, a release produces a **notarized, stapled DMG** (the
website download *and* the Sparkle enclosure) plus a signed `appcast.xml`, and
uploads both to S3. Sparkle in the app reads that appcast and self-updates in
place, preserving the user's Keychain-stored API key.

```text
packaging/make-dmg.sh    # 6. create-dmg -> sign + notarize + staple the DMG
sparkle sign_update <dmg>  # 7. EdDSA-sign the DMG (private key from login Keychain)
packaging/appcast.rb …   # 8. append a signed <item> to appcast.xml (idempotent)
aws s3 cp …              # 9. upload DMG (kept for rollback) + appcast.xml (no-cache)
```

All nine steps run from **one lane**, locally (Decision 3 — the multi-GB
Apple-Silicon engine freeze is impractical on hosted CI).

### Prerequisites (one-time)

- **`create-dmg`**: `brew install create-dmg`.
- **notarytool profile** `qie-notary` in the login Keychain (see
  `notarize-app.sh` header); export `NOTARY_PROFILE=qie-notary` before releasing.
- **Sparkle EdDSA keypair**: the **public** key is baked into `project.yml`
  (`SUPublicEDKey`); the **private** key lives in the login Keychain (item
  "Private key for signing Sparkle updates", read automatically by `sign_update`).
  **Back it up offline, encrypted:**

  ```bash
  GK="$(find ~/Library/Developer/Xcode/DerivedData "$(pwd)" \
         -path '*/artifacts/sparkle/Sparkle/bin/generate_keys' -type f 2>/dev/null | head -1)"
  "$GK" -x sparkle_private_key.pem      # export
  # move sparkle_private_key.pem into 1Password / an encrypted disk image, then:
  rm -P sparkle_private_key.pem         # shred the plaintext
  ```

- **AWS**: the `default` profile (override with `AWS_PROFILE`) must have write
  access to `s3://playola-static/downloads/QuickInterviewEditor/`.

### One-command release

```bash
export NOTARY_PROFILE=qie-notary
bundle exec fastlane mac bump version:1.1.0   # or: bump   (build integer only)
bundle exec fastlane mac release              # build → sign → notarize → DMG → appcast → S3
```

`bump` edits the version single-source in `project.yml`
(`MARKETING_VERSION` + the integer `CURRENT_PROJECT_VERSION` = `sparkle:version`),
regenerates the Xcode project, and commits — so `release` starts from a clean
tree with a never-reused `CFBundleVersion`. Env overrides (defaults shown):
`RELEASE_S3_BUCKET=playola-static`,
`RELEASE_S3_PREFIX=downloads/QuickInterviewEditor`,
`RELEASE_DOWNLOAD_HOST=https://playola-static.s3.amazonaws.com`,
`AWS_PROFILE=default`.

To rehearse without touching S3, point the release at a **staging prefix**
(`RELEASE_S3_PREFIX=downloads/QuickInterviewEditor-staging`, matching
`RELEASE_DOWNLOAD_HOST`) and run the checklist against that URL.

### Release-verification checklist (run every release, before announcing)

The pipeline is signing/notarization/network logic that unit tests can't prove;
run this on a real build:

1. **Gatekeeper on a freshly *downloaded* DMG** (not the local build — download
   from the S3 URL so you test the notarization ticket that actually shipped):

   ```bash
   spctl --assess --type open --context context:primary-signature -v QuickInterviewEditor-<short>-<build>.dmg
   xcrun stapler validate QuickInterviewEditor-<short>-<build>.dmg
   ```

2. **Clean install**: on a clean Mac / user account, mount the DMG, drag to
   `/Applications`, launch — no Gatekeeper block, no translocation, engine runs.

3. **Keychain round-trip (the core guarantee):**
   - Install **vN** (Developer ID) from the DMG, save an API key, run a
     cut-suggestion to confirm it works.
   - Publish **vN+1** (`bump` + `release`).
   - In the installed vN, **Check for Updates…** → install → relaunch.
   - Confirm the API key **still works with no Keychain prompt**.

4. **Designated-requirement match** (proves the silent read is legitimate, not a
   fluke): the DRs of vN and vN+1 must agree on the invariants below.

   ```bash
   codesign -d -r- /Applications/QuickInterviewEditor.app 2>&1 | grep '^designated'
   # compare vN vs vN+1: same identifier + "certificate leaf[subject.OU] = FSRSPV9N9Q"
   ```

### Invariants that must never change

Silent Keychain reads across updates depend on the code-signing **designated
requirement**, not the bundle path. Changing any of these makes an update unable
to read the previously-saved key without a prompt:

- **Team ID** `FSRSPV9N9Q`
- **bundle id** `fm.playola.QuickInterviewEditor`
- **Keychain service** `fm.playola.QuickInterviewEditor.anthropicAPIKey`,
  **account** `anthropic`, with **no** `kSecAttrAccessGroup` / sandbox /
  synchronizable change (mirrored in a comment on `KeychainStore.service`).

### Losing the EdDSA private key is recoverable

Because the app is Developer ID code-signed, Sparkle accepts a **new** EdDSA key
as long as the Developer ID identity is unchanged. To recover: ship an update
signed with the **same Developer ID** and a **new** `SUPublicEDKey`. Do **not**
rotate the Developer ID cert and the EdDSA key in the same release, and (with
`SUVerifyUpdateBeforeExtraction`) the rotation update must be a Developer ID
code-signed DMG — ours is. Only losing **both** the EdDSA key *and* the Developer
ID identity forces users to manually re-download. Back the key up anyway to avoid
the forced rotation.

### Rollback

Old DMGs stay in S3 (the release never deletes them). To roll back, point the
appcast's latest `<item>` enclosure back at a prior DMG's URL (or re-run
`appcast.rb` against the older DMG) and re-upload `appcast.xml`.

## How the app finds the engine

`EngineResolver` (Swift) prefers the bundled helper at
`Resources/engine/logic-markers-engine`; if it's absent it falls back to the dev
`.venv` (`QIE_ENGINE_REPO`/`#filePath`). So the same build runs packaged for
users and against the dev engine for development. When bundled, `LiveEngine`
passes the downloaded model dirs to the engine via `QIE_WHISPER_MODEL_DIR` /
`QIE_ALIGN_MODEL_DIR` / `QIE_OFFLINE=1`.

`CutSuggesterResolver` mirrors this for the cutter: it prefers
`Resources/engine/cut-suggester-engine`, else falls back to
`python -m cut_suggester.cli` from the dev repo root; if neither is runnable it
throws `helperNotFound` cleanly (never a crash). The frozen helper reads the LLM
key from its environment — the packaged app's auth story (how the user's key
reaches the child env) is a separate follow-up, not part of this freeze.

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
