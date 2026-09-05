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

## Codex adversarial review (PR 1) — dispositions

Ran `/codex review` (PASS: 2 P2 advisory, no P0/P1) + `/codex challenge`
(9 findings) on the PR 1 diff. Fixed the three that are genuine
contract-correctness issues in the codec that *defines* the on-disk format;
carried the rest forward with explicit reasons.

**Fixed in PR 1:**
- **Schema-version gating** (`ProjectPackage.decode`): decode a minimal
  `SchemaProbe` first and accept only `1...currentSchemaVersion`. A newer or
  malformed file now fails with a clear `unsupportedSchema` instead of an opaque
  `DecodingError`, and `0`/negative versions are refused (was: only `> current`
  rejected, after a full v1-shaped decode).
- **Explicit ISO-8601 `Date` strategy** for `project.json` (`projectEncoder`/
  `projectDecoder`): Foundation's default `Date` coding is seconds-since-2001, so
  the fixture's `importedAt: 1700000000` silently decoded to ~year 2054. Pinned
  to ISO-8601 (self-documenting on disk); fixture updated to the string form.
  `plan.json`/`EditPlan` keeps its own engine-defined coding, untouched.
- **Regular-file guard** on `audio/canonical.aiff` in `decode`: a directory or
  symlink at that path no longer survives as "present audio."

**Deferred by design (carried forward):**
- Real audio integrity — fingerprint/header validation beyond byte count
  (challenge #1/#2, review #2) → **PR 5**, where the canonical AIFF is opened as
  an `AVAudioFile` during hydration anyway (spec A5/A8). Byte-count-only
  `verifyAudio` is the deliberate PR 1 placeholder.
- Editor snapshot drops the widened `EditorDocumentState` fields
  (`cutSuggestions`/speaker) (challenge #3) → **PR 2/PR 3**. `EditorModel` is
  untouched by PR 1; the memberwise-init defaults are intentional forward-compat
  so existing call sites compile. The `mutateDocument` funnel that populates these
  fields is explicitly PR 2/PR 3 scope.
- `FileWrapper` aliasing / caller mutation on `encode` (challenge #5) —
  theoretical; no callers exist yet, and A5 *wants* the same audio wrapper reused.
  Revisit when the save path is wired (PR 4).
- Fixture `project.json`↔`plan.json` metadata disagreement (challenge #7) and
  duplicate-JSON-key rejection (challenge #9) — noted; cross-field validation and
  strict-JSON parsing are not PR 1 requirements for a self-written local format.

## Greptile review (PR 1, Confidence 4/5) — dispositions

**Fixed in PR 1:**
- **Timestamp precision contract** (P2): `.iso8601` carries whole seconds only, so
  a real `Date()`'s sub-second part would not round-trip — and the exact-round-trip
  test only used a whole-second value, hiding it. Made whole-second normalization
  the explicit, documented contract on `projectEncoder`/`projectDecoder` and added
  `fractionalImportedAtNormalizesToWholeSeconds` proving a fractional `Date`
  truncates. Carry-forward: whoever constructs `ProjectSource` at import (PR 2/3+)
  should floor `importedAt` to whole seconds so the in-memory value matches disk.
- **Fixture resource duplication** (P2): the broad `QuickInterviewEditorTests`
  source glob was exploding `project-v1.pie`'s children (`project.json`,
  `plan.json`, `canonical.aiff`) as loose top-level bundle resources *in addition*
  to the explicit whole-package folder resource. Added an `excludes:
  [Fixtures/project-v1.pie]` to the source path so only the opaque package is
  copied; verified in the regenerated `.pbxproj` that the loose child build files
  are gone.

**Deferred by design (left unresolved for the user):**
- **S2 feasibility gate incomplete** (P1): the real end-to-end check (50 autosaves
  at 500 MB/1 GB while measuring Versions/`.DocumentRevisions` growth) **cannot** run
  in PR 1 — there is no `NSDocument` to autosave until `DocumentGroup` lands in PR 4.
  PR 1 is codec-only and PR 2/3 don't ship the document shell either, so no
  incremental disk-growth risk accrues before PR 4, where the check is already a hard
  gate (see the S2 ESCALATE note above and `graph.md`). Left the thread unresolved.
