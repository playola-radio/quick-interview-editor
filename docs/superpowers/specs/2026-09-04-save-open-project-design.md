# Save / Open Project — Design

**Status:** Draft — awaiting user approval (no code written)
**Date:** 2026-09-04
**Author:** Brian (with Claude + Codex architecture consult, session
`01a06d95-c0fc-73f2-b3ad-6082e05c96cc`)

---

## Goal

A project is a file. Importing audio creates an untitled project; File > Save
writes it; File > Open reopens it exactly as it was left: canonical audio,
transcription, marked clips, deletions with their crossfades, cut suggestions
and their accept/reject state, and the speaker overrides. Once a project has a
location it autosaves in place with macOS Versions, so today's write-through
feel is preserved and Revert To… works.

This is a major release: the app becomes document-based and the invisible
fingerprint-keyed sidecar stops being the source of truth.

## Confirmed product decisions (locked, not re-litigated here)

1. Document-based app, Logic/Word/Xcode style. Import audio → untitled
   project; Save writes it; Open restores it.
2. The project bundles the **canonical AIFF only**, never the original MP3/M4A.
3. **Autosave in place + Versions.** Cmd-S still works; an untitled project
   prompts for a location on first save.
4. The project is a **macOS document package** (a folder Finder shows as one
   file, like `.logicx`).

## Non-goals (v1)

- Persisting session view state (zoom, scroll, cursor, right-panel tab,
  selection). The document stores content only. View state can come later in
  Application Support, keyed by document identity, without touching the
  package format.
- Opening raw audio files from Finder or the Dock. Audio enters only through
  File > Import Audio…, drag-and-drop, or the empty-window button.
- Bundling the original import (locked decision 2).
- App sandboxing, iCloud conflict resolution, and security-scoped bookmarks.
  The app is Developer ID, non-sandboxed; the package is opened through the
  document system, which handles coordination.
- Replacing the in-memory `UndoStack` with the system `UndoManager`.
- Any change to the export pipeline or the Python engine contract.

## Verified constraints

- Deployment target macOS 15.0, Swift 6 strict concurrency, CI on Xcode 16.4.
- Apple's newer `Document` / `ReadableDocument` / `WritableDocument` /
  `DocumentWriter` protocols (WWDC26) are macOS 27-only. They are out.
- `ReferenceFileDocument` (macOS 11+): `init(configuration:)`,
  `snapshot(contentType:)`, and `fileWrapper(snapshot:configuration:)` all run
  **off the main actor**; `FileDocumentWriteConfiguration.existingFile` exposes
  the on-disk package's current `FileWrapper` tree; document dirtiness is
  driven **only** by changes registered on the environment `UndoManager`.
- Today `EditorModel` is the per-song root of all editing state, funnels every
  content mutation through `mutateDocument` (slices + timeline removals), and
  keeps a value-snapshot `UndoStack<EditorDocumentState>` capped at 30.
  `CutSuggestionsPageModel` owns its own `@Shared(.projectState)` and writes
  accept/reject state directly. Cmd-Z / Shift-Cmd-Z are `keyboardShortcut`s on
  the slices-panel buttons, not menu commands.
- The editor already plays and exports from a session-owned copy of the
  canonical AIFF in `CanonicalAudioStore` (Caches), never from the durable
  `TranscriptCache` copy.

---

## Architecture

### A1. Document framework: `DocumentGroup` + `ReferenceFileDocument`

SwiftUI `DocumentGroup` with a `ReferenceFileDocument` package document. It
supplies, on macOS, the NSDocument machinery for free: Open/Save/Save As/
Duplicate/Rename/Move, autosave in place, Versions and Revert To…, Open Recent,
the edited-dot and close-with-unsaved-changes sheet, and native window tabs.

Rejected: subclassing `NSDocument` directly. It would require an AppKit
lifecycle layer (`NSDocumentController`, window controllers, `NSHostingView`)
around a SwiftUI-first app and its tests for no capability we need. If a spike
proves `ReferenceFileDocument` cannot reuse the on-disk audio during save
(A5), NSDocument is the fallback, and the value types in A2 carry over
unchanged.

### A2. Ownership: thin document, value payload, behavior in models

Three layers, each testable in isolation:

```
ProjectDocument (ReferenceFileDocument, thin, no behavior)
  └─ file: ProjectFile            ← Sendable value, everything that is serialized
  └─ audio: CanonicalAudioSource  ← where the AIFF bytes live right now

ProjectModel (@MainActor @Observable ViewModel — one per window)
  └─ phase: empty | transcribing | loaded | failed
  └─ editor: EditorModel?         ← created on load, exactly as today
  └─ pushes ProjectFile changes into the document and registers dirtiness

EditorModel (unchanged role; document-agnostic)
  └─ documentState: EditorDocumentState (widened, A6)
  └─ onDocumentStateChanged callback → ProjectModel
```

Serialized value types (all `Codable, Equatable, Sendable`):

```swift
struct ProjectFile {
  var schemaVersion: Int              // 1
  var source: ProjectSource
  var engine: ProjectEngineInfo       // engineFingerprint used for the plan
  var content: EditorDocumentState    // slices, removals, suggestions, speakers
}

struct ProjectSource {
  var originalFileName: String        // "interview.mp3" — display only
  var originalPath: String?           // informational; never used to read
  var originalFingerprint: String     // SourceFingerprint of the imported bytes
  var canonicalFingerprint: String    // sha256 of audio/canonical.aiff
  var canonicalByteCount: Int
  var importedAt: Date
  var sampleRate: Int
  var channels: Int
  var durationSamples: Int
}
```

`EditPlan` is not part of `ProjectFile`; it is stored beside it (A4) and read
into `ProjectDocument.editPlan` on open.

`ProjectDocument` holds only values plus a `CanonicalAudioSource`:

```swift
enum CanonicalAudioSource: Sendable {
  case packageChild                   // unchanged since read; reuse on save
  case sessionFile(URL)               // imported or re-transcribed this session
}
```

`ProjectModel` is created by a tiny `ProjectHostView` (`@State private var
model`, `.task { await model.viewAppeared() }`); the view makes no decisions.
`ProjectModel` receives the document through a `ProjectDocumentSink` value
(closures: `commit(ProjectFile, EditPlan?, CanonicalAudioSource?)`,
`registerChange()`) so tests inject recorders and never touch a document type.
`EditorModel` keeps its current initializer shape; tests construct it with a
fixture `EditPlan`, a fake canonical URL, and an initial `EditorDocumentState`.

### A3. Window model: one project per window

- Drop the custom in-app tab bar. Each `.pie` is one window; users who
  want tabs use macOS native window tabs (Window > Merge All Windows), matching
  Logic's one-project-per-window convention.
- `RootModel` is deleted. Its import validation moves to `ProjectModel`; its
  empty-state strings move to `ProjectModel`'s view helpers.
- `SongTabModel` becomes `ProjectModel`. Its phases map directly:
  `queued`/`transcribing`/`loaded`/`failed` plus a new `empty` phase for a
  fresh untitled window. Its editor teardown sequence (cancel export, stop
  playback, await export teardown, discard session audio) is kept verbatim.
- The transcription concurrency cap (2) moves out of the visual model into an
  app-level dependency, `TranscriptionQueueClient`, whose live value wraps the
  existing `TranscriptionClient` behind a queue. Test value returns the job's
  stream immediately.
- `AppLaunchModel` survives as the process-level model: stale-cache reaping,
  engine fingerprint warm-up, temp sweep, updater start, and the model-setup
  readiness gate. `ProjectHostView` observes it (via the environment) and shows
  the setup state before the project view, as `AppLaunchView` does today.
- Menu commands act on the **focused** project via `@FocusedValue`, not a
  global root. `TranscriptionCommands` (Re-transcribe ignoring cache) targets
  the focused `ProjectModel`; cache clearing stays app-level.
- Launch opens an untitled empty project (DocumentGroup default) or restores
  the previous windows.

### A4. Package layout, type, and compatibility

```
Interview.pie/
  project.json          ← ProjectFile (small; rewritten on every save)
  plan.json             ← EditPlan verbatim (engine-owned; ~1 MB per hour)
  audio/
    canonical.aiff      ← canonical PCM; reused, never re-serialized (A5)
```

- Extension **`.pie`**; UTType **`fm.playola.interview-editor.project`**
  conforming to `com.apple.package` and `public.composite-content`. Declared as
  an exported type and the app's document type in `project.yml`/Info.plist
  (Open Recent and Finder association depend on this being right).
  `.interview` was rejected as too generic; `.pie` puns on **P**layola
  **I**nterview **E**ditor and reads as a project bundle.
- `schemaVersion` starts at 1 in `project.json`. `EditPlan` keeps its own
  `schema_version`. Rules: refuse to open a **greater** major `schemaVersion`
  with a clear alert ("This project was saved by a newer version of Playola
  Interview Editor"); decode additive fields leniently with defaults (the
  `ProjectState` / `Crossfade` pattern); unknown enum values fall back only
  where a safe default exists (crossfade curve → equal power).
- Open-time integrity check: `audio/canonical.aiff` byte count must equal
  `canonicalByteCount` and the AIFF header must agree with `sampleRate`,
  `channels`, `durationSamples`. Mismatch → open fails with an actionable
  message. The full SHA-256 is not recomputed on open; it is used only for the
  re-transcription cache key (A7).
- JSON everywhere except the audio. Readable, diffable, and the engine
  contract is already JSON.

### A5. Audio handling: never re-serialize, never read from the package

**Invariant:** the editor plays and exports from a session-owned copy in
`CanonicalAudioStore`, exactly as today. The package can be moved, renamed,
autosaved, or version-swapped while open without pulling audio out from under
the player.

- **Open:** `ProjectDocument.init(configuration:)` decodes `project.json` and
  `plan.json` from the wrapper tree and records `audio = .packageChild`. It does
  not touch audio bytes. `ProjectModel.viewAppeared()` then clones
  `audio/canonical.aiff` (APFS clone via `FileManager.copyItem`, effectively
  free) into a fresh `CanonicalAudioStore` session directory and builds the
  `EditorModel` against that copy. Reading the package by URL here is an
  accepted deviation from Apple's "use the wrapper" advice, isolated to one
  place, done once, before any write can race it.
- **Import:** transcription produces a canonical AIFF in the session store
  (today's path). `ProjectModel` commits `audio = .sessionFile(url)` along with
  the plan and source metadata.
- **Save:** `fileWrapper(snapshot:configuration:)` builds a directory wrapper:
  `project.json` freshly encoded; `plan.json` freshly encoded (cheap at ~1 MB —
  measured in spike S2; add generation-based reuse only if it is not); for
  audio, **reuse `configuration.existingFile?.fileWrappers?["audio"]` when the
  snapshot's source is `.packageChild`**, otherwise a lazily-read
  `FileWrapper(url:)` pointing at the session file. Save As / Duplicate (no
  matching existing child) fall back to the session file, which always exists
  while the project is open.
- **Re-transcribe** replaces plan + audio (`.sessionFile`) in one commit.

### A6. One persisted content boundary: `EditorDocumentState` widened

```swift
struct EditorDocumentState: Codable, Equatable, Sendable {
  var slices: IdentifiedArrayOf<Slice>
  var timelineRemovals: IdentifiedArrayOf<TimelineRemoval>
  var cutSuggestions: IdentifiedArrayOf<CutSuggestion>
  var speakerCountOverride: Int?
  var speakerDisplayNames: [String: String]
}
```

- `mutateDocument` stays the single funnel and becomes the single **dirtiness**
  boundary: after applying a change it invokes
  `onDocumentStateChanged(documentState)`. `undoTapped`/`redoTapped` invoke the
  same callback after restoring a snapshot. `persistTimelineRemovals` and the
  editor's `@Shared(.projectState)` are removed.
- `mutateDocument` gains `recordUndo: Bool = true`. The automatic background
  suggestion pass on load uses `recordUndo: false` so Cmd-Z never silently
  discards suggestions the user did not ask for; it still dirties the document.
- `CutSuggestionsPageModel` stops owning persistence. It reads suggestions from
  the editor's `documentState` (passed in / observed) and emits intents
  (`onAccept(id, slice)`, `onReject(id)`, `onSuggestionsProduced([CutSuggestion])`,
  `onSpeakerOverridesChanged(...)`) that `EditorModel` applies through
  `mutateDocument`. Accept/reject become undoable and dirty the document, which
  the Codex consult flagged as the main structural conflict.

### A7. Dirtiness, undo, and autosave

- **Undo truth stays the value-snapshot `UndoStack`.** It is tested,
  deterministic, and already guards `hasUncommittedSliceEdit` / `isExporting`.
  Mirroring every entry into `UndoManager` would create two stacks that drift
  the first time the editor refuses an undo the system already popped.
- **Dirtiness is signalled through the environment `UndoManager`**, because
  that is the only public path by which a `DocumentGroup` document becomes
  edited. `ProjectModel.registerChange()` registers a lightweight undo action on
  each committed change (from `onDocumentStateChanged`, from a transcription
  commit, from re-transcribe). With `levelsOfUndo = 1` the manager holds one
  entry; NSDocument's change count, autosave, and the edited indicator key off
  the close-undo-group notification, not the stack depth. Spike S3 proves this
  end-to-end before PR 4.
- **Edit > Undo / Redo are replaced** (`CommandGroup(replacing: .undoRedo)`)
  with commands routed to the focused project's editor (`undoTapped` /
  `redoTapped`, labels from `undoLabel` / `redoLabel`, enabled by `canUndo` /
  `canRedo`). The `keyboardShortcut("z")` modifiers come off the slices-panel
  buttons so Cmd-Z has exactly one owner. Behaviour for text fields is
  unchanged from today (the panel shortcut already pre-empted field undo).
- **Autosave cadence.** Autosave in place runs on NSDocument's schedule
  (seconds after a change, plus on close, quit, and Versions checkpoints) rather
  than today's write-on-every-mutation sidecar. The crash-loss window becomes
  "since the last autosave" instead of "since the last mutation". Accepted for
  v1; no shadow journal.
- **Untitled projects** autosave to the system Autosave Information location
  like any untitled document, so a large AIFF may be copied there once. Close
  offers Save / Delete / Cancel as standard.
- **Save is inert while transcribing.** An untitled window that is empty or
  mid-transcription registers no change; closing it cancels the job without a
  prompt. The document first becomes dirty when the completed transcription is
  committed.

### A8. Migration and the cache layer

- The fingerprint sidecar (`~/Library/Application Support/Playola Interview
  Editor/Projects/<sha256>.json`, post-rename unified folder — see
  `AppDirectories`) becomes **read-only migration input**. On import,
  after the source fingerprint is known and before the editor is built, seed
  `EditorDocumentState` from a matching sidecar (removals, suggestions, speaker
  fields — slices were never persisted). The sidecar is not written again and
  not deleted; the read path is removed in a later major version.
- `TranscriptCache` stays as it is: a cache **behind** the document that makes
  re-importing the same audio skip transcription. It is never required to open
  a project: the package carries `plan.json` and the AIFF, so a project opens
  on a machine with an empty cache.
- **Re-transcribe from a saved project** uses the bundled canonical AIFF as the
  source (the original import is not bundled). Its cache key is
  `TranscriptionCacheKey(sourceFingerprint: canonicalFingerprint, …)`, which is
  why `canonicalFingerprint` is stored: a project restored from Versions or
  copied between machines must not collide with the original MP3's key. The
  engine's canonicalization of an already-canonical AIFF must be sample-exact
  (spike S4 verifies) so existing clips and removals stay aligned; they are
  revalidated through the existing `validatedRemovals` path either way.
- `EngineFingerprint` is recorded in `project.json` for provenance and to drive
  the "transcript produced by an older engine" affordance later; it does not
  gate opening.

### A9. Error handling

- Decode failure or unsupported schema on open → the document system shows the
  error; the message names the file and the reason ("missing plan.json",
  "saved by a newer version"). No partial windows.
- Audio integrity mismatch (A4) → open fails; the message says the bundled
  audio does not match the project.
- Clone-into-session failure (disk full, permissions) → `failed` phase in the
  window with the underlying error and a Retry.
- Save failure surfaces through the document system's standard alert; the
  in-memory state is untouched and remains dirty.
- Transcription failure keeps today's `failed` phase and copy.
- All unexpected states go through `reportIssue`, never silently swallowed.

### A10. Testing

Every model is tested; no view carries logic.

- `ProjectFile` / package codec: round-trip through an in-memory
  `FileWrapper(directoryWithFileWrappers:)`; lenient decode of a v1 file with
  fields missing; refusal of a greater `schemaVersion`; missing `plan.json`;
  audio wrapper reuse when the source is `.packageChild` and a fresh wrapper
  when it is `.sessionFile`. Fixtures: a bundled `project-v1.pie` tree
  with a tiny AIFF.
- `ProjectModel`: phase transitions with an immediate `TranscriptionQueueClient`
  stream; commit + `registerChange` recorded by a test `ProjectDocumentSink`;
  no change registered while empty or transcribing; cancel on close; migration
  seeding from a legacy sidecar via the in-memory `FileStorage` pattern;
  re-transcribe replaces plan and audio in one commit.
- `EditorModel`: `onDocumentStateChanged` fires once per `mutateDocument`, once
  per undo/redo, and not for no-op mutations; `recordUndo: false` dirties
  without a history entry; cut-suggestion accept/reject/speaker overrides flow
  through the funnel and are undoable.
- `CutSuggestionsPageModel`: emits intents; owns no `@Shared`.
- Undo/redo command availability follows `canUndo` / `canRedo` of the focused
  project.
- Comparisons use `expectNoDifference`; no `Task.sleep`; no subprocess.

---

## Spikes (throwaway; run before the corresponding PR)

| # | Question | Gate for |
|---|----------|----------|
| S1 | `DocumentGroup` + `ReferenceFileDocument` package on the macOS 15 target compiles on Xcode 16.4-compatible APIs and gives Open/Save/autosave/Versions/Revert To… without NSDocument code | PR 1 |
| S2 | Save a package with a 500 MB and a 1 GB AIFF, then make 50 small autosaves: audio child reused (no copy), save latency, `.DocumentRevisions` disk growth (hard links vs copies), `plan.json` encode time | PR 1 |
| S3 | Registering one `UndoManager` action per change marks the document edited, triggers autosave, and clears on save; replaced Undo/Redo menu items do not fight the document's undo manager | PR 4 |
| S4 | Engine re-transcription with the canonical AIFF as input yields a byte-identical canonical AIFF (sample alignment for re-transcribe) | PR 5 |
| S5 | `ProjectDocument.init(configuration:)` (nonisolated) → `@MainActor ProjectModel` creation with zero Swift 6 concurrency diagnostics | PR 4 |

If S2 shows Versions duplicating the AIFF on every checkpoint at an
unacceptable rate, that is escalated to the user before PR 4; the candidate
mitigation is NSDocument with `preservesVersions` tuned, not a format change.

## PR sequence

1. **Package format (no UI).** `ProjectFile`, `ProjectSource`,
   `CanonicalAudioSource`, package encode/decode, UTType + document-type
   declarations, fixtures, tests. Widen `EditorDocumentState` (A6) as pure data.
2. **One content boundary.** Cut suggestions and speaker overrides through
   `mutateDocument`; `onDocumentStateChanged`; `recordUndo:`; remove
   `@Shared(.projectState)` from `EditorModel` and `CutSuggestionsPageModel`.
   `SongTabModel` temporarily owns the callback and writes the legacy sidecar so
   the app keeps working between PRs.
3. **`ProjectModel` + `TranscriptionQueueClient`.** Port `SongTabModel` tests to
   document-level phase tests; `ProjectDocumentSink`; legacy sidecar seeding.
4. **Document shell.** `DocumentGroup`, `ProjectDocument`, `ProjectHostView`,
   one project per window, focused commands, Undo/Redo menu replacement,
   dirtiness, autosave, first save, open with audio hydration. Delete
   `RootModel`, the tab bar, and `SongTabModel`.
5. **Re-transcribe identity + cleanup.** Canonical-fingerprint cache key,
   re-transcribe from the bundled AIFF, sidecar write path removed, docs and
   release notes for the major version.

Each PR builds, passes `make test-fast`, `make format-check`, `make lint`, and
ships behind no flag: PRs 1–3 are invisible; PR 4 is the user-visible switch.

## Open items for the user

- ~~Extension `.pie` vs `.qie`~~ **Resolved: `.pie`.** The app was also renamed
  Quick Interview Editor → Playola Interview Editor with a new bundle id
  (`fm.playola.PlayolaInterviewEditor`), keychain service, and appcast path —
  shipped ahead of this feature in PR #71.
- Whether the autosave-window crash-loss trade (A7) is acceptable for v1.
- Whether deleting the legacy sidecar after a successful first save is wanted
  (recommendation: leave it; remove the reader in a later major).
