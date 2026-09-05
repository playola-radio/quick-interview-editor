# Save/Open spike notes (PR 1 spike gate)

Both spikes below used throwaway code, run and then deleted; neither is part
of the PR 1 diff.

## S1 — `DocumentGroup` + `ReferenceFileDocument` compiles on the project's API surface

**Goal:** prove the design's document-based approach uses the macOS 11+
`ReferenceFileDocument`/`DocumentGroup` API, not the macOS 26/27-only
`Document`/`ReadableDocument`/`WritableDocument`/`DocumentWriter` APIs that
would compile locally (this machine runs Xcode 27.0.0-Beta) but fail on CI's
Xcode 16.4.

**What was done:** added a throwaway
`QuickInterviewEditor/QuickInterviewEditor/Core/_Spike_ReferenceFileDocument.swift`
defining a minimal `ReferenceFileDocument` conformance (`init(configuration:)`,
`snapshot(contentType:)`, `fileWrapper(snapshot:configuration:)`) backed by
`ProjectPackage.decode`/`.encode`, plus a `DocumentGroup(newDocument:)` scene,
built against the project's real settings (`deploymentTarget: macOS 15.0`,
`SWIFT_VERSION: "6.0"`). Ran:

```
xcodebuild -project PlayolaInterviewEditor.xcodeproj -scheme PlayolaInterviewEditor \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

**Result: `BUILD SUCCEEDED`.** No macOS 26/27-only symbols were referenced —
only `ReferenceFileDocument`, `DocumentGroup`, `FileDocumentReadConfiguration`/
`WriteConfiguration`, all available since macOS 11. The file was deleted after
the build and `xcodegen generate` was re-run; `git status` shows no diff from
the confirmed PR 1 commits.

**Known gap:** this machine only has Xcode 27.0.0-Beta installed, not CI's
Xcode 16.4, so this is a same-API-surface proxy, not a literal CI-toolchain
build. The API surface used (`ReferenceFileDocument`/`DocumentGroup`) has been
stable and available since macOS 11/Xcode 13, well before 16.4, so risk is low,
but PR 4 (which actually adds `DocumentGroup` to the app) should get one real
CI run before merge to close this gap for certain.

## S2 — autosave/Versions behavior with large AIFFs

**Goal:** validate spec A5's core assumption — that saving reuses the
existing, unchanged canonical-audio `FileWrapper` child rather than
re-serializing the AIFF's bytes on every save, so autosave/Versions doesn't
duplicate a large audio file on disk each cycle.

**What was done:** a throwaway standalone Swift script (not part of the Xcode
project) built a `.pie`-shaped `FileWrapper` tree with a synthetic audio
payload, wrote it to disk, read it back, mutated only `project.json` while
reusing the **same** audio `FileWrapper` instance read from disk (never
re-instantiating it from `Data`), then wrote again with `originalContentsURL`
set to the existing package URL — mirroring exactly what
`ReferenceFileDocument`'s system-driven save does. Tested at 200 MB and 800 MB.

**Results:**
- Both writes succeeded with no errors at both sizes.
- `audio/canonical.aiff`'s modification **time** was unchanged after the
  second write in both runs.
- Its **inode** changed on both runs (expected — atomic writes replace the
  package via write-then-swap regardless of whether a child's content
  changed).
- Second-write duration scaled roughly linearly with audio size (200 MB →
  0.22 s, 800 MB → 0.84 s; ~950 MB/s effective throughput either way).

**Interpretation — inconclusive on the core question:** the linear scaling
with size means this experiment **cannot cleanly distinguish** "FileWrapper
performs a real byte-for-byte copy of the unchanged audio on every save" from
"FileWrapper does a cheap APFS copy-on-write clone whose setup cost scales
with extent count." Either explanation fits the numbers. Practically, even in
the worst case (a real copy every save), ~950 MB/s throughput on this
hardware means a 1 GB canonical AIFF costs roughly ~1s of extra save latency
— likely tolerable, but not free, and untested on non-SSD or older hardware.

**Explicit gaps (not closed by this spike):**
1. This measured `FileWrapper.write()` mechanics directly, in isolation. It did
   **not** exercise real `NSDocument` autosave scheduling, real macOS Versions
   snapshot creation, or actual on-disk footprint growth (`du`) across many
   consecutive saves of the same document window.
2. No test used real production-scale audio (500 MB–1 GB+ multi-hour
   interviews) end-to-end through the actual app; only synthetic payloads
   through a standalone script.
3. Versions (Time Machine-style local snapshots macOS keeps for
   document-based apps) operates at a layer this spike never touched at all —
   it's plausible Versions makes its own full copy independent of whatever
   `FileWrapper` itself does internally.

**ESCALATE before PR 4:** PR 4 (which wires `DocumentGroup` into the real app)
should re-run this as a real end-to-end check — open a multi-hour interview,
edit a slice, save repeatedly, and watch actual disk usage (`du -sh` on the
`.pie` package and on `~/Library/Containers/.../Data/Library/Autosave
Information/`) to confirm Versions isn't duplicating the audio every
checkpoint. If it is, the fix is likely disabling `NSDocument.autosavesInPlace`
or hooking `fileWrapper(snapshot:configuration:)` to explicitly hand back the
identical wrapper reference (which this spike shows is safe to do) rather than
rebuilding the audio child from scratch on every save call.
