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

## PR 4 spike results — S1 / S2 / S3 / S5 against the real `DocumentGroup`

Run 2026-09-05 on the PR 4 branch once `ProjectDocument` + `DocumentGroup` +
`ProjectHostView` were in place. S2/S3 were driven by a throwaway, env-gated
hook (`QIE_SPIKE=1`, set via `launchctl setenv` so `open -a` inherited it) that
lived in `ProjectHostView`/`ProjectModel`, logged to `/tmp/qie-spike/log.txt`,
and was deleted before commit. UI automation was unavailable (no assistive
access for `osascript`; `screencapture` returned black), so everything below
was measured from inside the process, not visually.

### S5 — `nonisolated init(configuration:)` feeding a `@MainActor` model

**PASS.** `ProjectDocument` is a `@MainActor final class` with a
`nonisolated init()` and `nonisolated convenience init(configuration:)`;
`Content`/`Snapshot` is `Sendable`. Signed and unsigned builds report zero
Swift 6 diagnostics in `ProjectDocument`, `ProjectModel`, `ProjectHostView`,
`ProjectView`, and the `Views/Commands` files.

**Bug found on the way (fixed in `bf716ee`):** NSDocument saves
asynchronously. The first Cmd-S crashed with `EXC_BREAKPOINT` inside
`ProjectDocument.snapshot(contentType:)` because it used
`MainActor.assumeIsolated` and the document system calls
`fileWrapper(ofType:)` → `ReferenceFileDocumentBox.snapshotForSerialization`
→ our `snapshot` on a dispatch worker thread. The saved values now sit behind
a `Mutex<Content?>` and `snapshot` is `nonisolated`; the test
`snapshotIsTakenOffTheMainActorAfterAMainActorCommit` pins it.

### S3 — `UndoManager` dirtiness bridge over the value-snapshot `UndoStack`

**PASS, with one amendment to the plan's mechanism.**

The plan's bridge (`registerChange()` registers a single no-op
`registerUndo(withTarget:)` action, `levelsOfUndo = 1`) does *not* by itself
mark the document edited when called from a Swift-concurrency continuation.
`NSUndoManager` opens an implicit per-event group on the first registration
and only closes it when AppKit finishes dispatching an `NSEvent`; from a task
continuation there is no event in flight, so `groupingLevel` stayed at 1 for
100+ s and `NSDocument.isDocumentEdited` stayed `false` until the next mouse
or key event. Explicit `beginUndoGrouping`/`endUndoGrouping` did not help:
at level 0 with `groupsByEvent` it nests inside the still-open implicit group.

Fix kept in product code: after `registerUndo`, post a no-op
`.applicationDefined` `NSEvent` so the run loop closes the group. With that,
`NSDocument.isDocumentEdited` flipped to `true` within 0.5 s of the edit,
autosave-in-place landed in `project.json` after ~11 s, and an explicit
`save(nil)` cleared the edited flag. The editor's `UndoStack` and the PR 2
post-init diff base were untouched; the full suite (including
`suggestionsProducedAfterAnEditSurviveUndoAndRedoOfThatEdit`) stays green.

Observed but not a failure: `NSWindow.isDocumentEdited` stays `false` for
autosaving documents even while `NSDocument.isDocumentEdited` is `true`,
which is AppKit's documented behavior for `autosavesInPlace` apps. The
title-bar "Edited" text could not be checked visually here; it is on the PR
manual-QA checklist.

### S2 — autosave/Versions disk usage, end to end

**PASS — Versions does not duplicate the audio per checkpoint.**

Package: `/tmp/qie-spike/big.pie`, 637 MB (90 copies of the 42 s
hayes-carll-intro clip as 44.1 kHz stereo AIFF = 667,975,734 bytes,
`project.json` byteCount updated, `plan.json` from the fixture). Opened in the
app, made one edit (autosave), then ten explicit saves.

| checkpoint | `.pie` size (`du -sk`) | Versions count (`NSFileVersion.otherVersionsOfItem`) | free-disk delta |
| --- | --- | --- | --- |
| open | 652,344 KB | 0 | — |
| after autosave | 652,344 KB | 1 | ≈ −106 MB |
| after save 1 | 652,344 KB | 2 | ≈ −423 MB |
| after save 2 | 652,344 KB | 3 | ≈ −141 MB |
| after saves 3–10 | 652,344 KB | 11 | flat |

Total free-disk drop ≈ 670 MB ≈ one copy of the audio, spread over the first
three checkpoints (Versions preserves the original asynchronously), then flat
for eight more saves. The package itself never grew: the audio child is
reused in place and only `project.json`/`plan.json` are rewritten.
`~/Library/Containers/<bundle>/Data/Library/Autosave Information/` is empty
(the app is not sandboxed, so there is no container); autosave writes into
the package in place. `.DocumentRevisions-V100` is root-only, so the
per-version cost was measured via free-disk deltas rather than `du`.

Conclusion: the spec A5 "reuse the audio `FileWrapper` child" assumption
holds under the real NSDocument autosave path. One extra copy of the audio
on disk after the first save is the expected Versions baseline, not a
per-checkpoint leak.

### S1 — real CI run (Xcode 16.4 / macOS 15.0 / Swift 6.0)

**PASS.** PR #76's first CI run (workflow run 34004272572, commit 7d2adb9)
built and ran the full suite on the `Xcode app (macOS)` job under Xcode 16.4 /
macOS 15 / Swift 6.0 with no diagnostics. The `nonisolated init` +
`Mutex`-backed `ReferenceFileDocument` compiled cleanly on the older toolchain,
so the Xcode 26/27-vs-16.4 skew that bit earlier PRs did not apply here.

## Codex review + challenge (PR 4) — dispositions

Run on the finished branch (review via `codex exec` over the diff, then an
adversarial challenge). Six findings.

**Fixed:**
- **Transcription commit never dirtied the document** (P1, both passes): the
  first import into an untitled window committed the new package values but
  never called `registerChange()`, so the window stayed clean, autosave never
  armed, and closing it discarded the transcription without asking. Spec A7
  names the transcription commit as the first dirtying change. Fixed in
  `loadCompletedTranscription`; tests now expect one registered change per
  import (the earlier expectation of zero was wrong).
- **Reused package audio skipped the byte-count gate** (P1, both passes): the
  save path that keeps the on-disk `audio/canonical.aiff` child only checked
  that it was a regular file, so metadata could be rewritten over a truncated
  or swapped AIFF. `verifyAudio` now runs before `rewriteMetadata`.
- **Hydration trusted the by-path copy** (P1): open verified the package, but
  hydration re-read the audio by URL later; a package rewritten in between
  would hand the editor mismatched audio. The clone's size is now checked
  against the recorded byte count before the editor is built, and the clone
  is removed on mismatch.
- **Clone orphaned when the window closed mid-copy** (P2): the detached copy
  ignores cancellation, and `hydrate()` returned without deleting the result.
  It now removes the clone. Removal goes through a new
  `CanonicalAudioStoreClient.remove` endpoint so tests can point it at their
  own store base (the static `remove` refuses paths outside the real cache).

**Deferred by design:**
- **`canonicalFingerprint` is still `""`** (P1 by Codex's severity): a
  same-size AIFF swap passes the byte-count gate. This is PR 5's scope by the
  plan; the byte-count gate is the agreed PR 4 integrity check.
- **Session audio lifetime vs. an in-flight save** (P2): originally deferred;
  fixed in the PR-review pass below (session audio now outlives every
  re-import and is only deleted on window close).

## PR review dispositions (Greptile 3/5, CodeRabbit, Codex follow-up)

Greptile and CodeRabbit reviewed PR #76; Codex re-reviewed the fix commit.

**Fixed:**
- **Re-import discarded the project's edits** (Greptile P1): a same-source
  re-import or retry seeded the new editor from `migrationSeed` (the legacy
  sidecar, always empty slices) instead of the current document. The seed now
  comes from `file.content` when the source fingerprint matches, and from the
  sidecar only for a first import or a different source.
- **Failed re-import broke saving** (Greptile P1, CodeRabbit Major): starting a
  re-import deleted the session AIFF the document still referenced, so a
  failed or cancelled run left Save pointing at a missing file. Audio lifetime
  moved out of `EditorModel` into `ProjectModel`: teardown only cancels
  playback and export, and the audio survives until the window closes.
- **Replaced audio deleted while a save could still read it** (Codex P2 on the
  fix commit): deleting the previous session copy right after the replacement
  commit still raced a save snapshotted before it. Replaced copies are now
  retired and deleted with the current one in `viewDisappeared`, after the
  close-save. Crash leftovers fall to the 7-day `reapStale` at launch.
- **Schema 0 described as "newer app"** (CodeRabbit Minor): versions at or
  below zero now get a neutral "unsupported format version" message.

**Deferred to PR 5:**
- **Word-keyed content vs. a changed plan** (Codex P3): a force-fresh
  re-transcribe of the same source keeps the document's slices (`wordIDs`,
  `snippet`) and cut suggestions as-is. `Word.id` is an index into the plan,
  so a differently aligned plan cannot be detected per word; sample-based
  `timelineRemovals` are still validated. Revalidating word-keyed metadata
  against the new plan belongs with PR 5's re-transcribe alignment work
  (spike S4).
