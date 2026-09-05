# Save / Open Project Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **REQUIRED PFW SKILLS — invoke before writing code in any task:**
> `pfw-observable-models` (every `*Model.swift`), `pfw-dependencies` (the
> `TranscriptionQueueClient` client + any `@Dependency`), `pfw-sharing` (removing
> `@Shared(.projectState)`; view-state key later), `pfw-identified-collections`
> (`IdentifiedArrayOf` on `EditorDocumentState`), `pfw-testing` + `pfw-custom-dump`
> (all tests; `expectNoDifference`), `pfw-case-paths` (asserting `ProjectModel.Phase`
> / `CanonicalAudioSource` cases), `pfw-modern-swiftui` (the `DocumentGroup` scene +
> `ProjectHostView`), `pfw-issue-reporting` (`reportIssue` on error paths). List the
> ones you used in each task's checklist.

**Goal:** Make Playola Interview Editor a document-based macOS app where a project
is a `.pie` package (canonical AIFF + transcript + all edits) that saves,
autosaves in place with Versions, and reopens exactly as left.

**Architecture:** A thin `ProjectDocument: ReferenceFileDocument` owns a
`Sendable` `ProjectFile` value payload plus a `CanonicalAudioSource`; a
`@MainActor @Observable ProjectModel` (one per window) owns behavior and the
`EditorModel`; `EditorModel` stays document-agnostic and unit-tested against
values. All persisted content lives in one widened `EditorDocumentState` funneled
through `mutateDocument`, which is also the single dirtiness boundary bridged to
the environment `UndoManager`.

**Tech Stack:** SwiftUI `DocumentGroup` + `ReferenceFileDocument`,
swift-dependencies, swift-sharing, swift-identified-collections, swift-custom-dump,
Swift Testing, XcodeGen (`project.yml`), FileWrapper packages, APFS clone.

**Spec:** `docs/superpowers/specs/2026-09-04-save-open-project-design.md`
(read it alongside this plan — every task argues from it).

## Global Constraints

- Deployment target **macOS 15.0**; Swift **6.0** strict concurrency; CI on
  **Xcode 16.4** (do not use macOS 27 `Document`/`ReadableDocument`/
  `WritableDocument`/`DocumentWriter` APIs — they will not compile).
- Bundle id `fm.playola.PlayolaInterviewEditor`; Team `FSRSPV9N9Q`; keychain
  service `fm.playola.PlayolaInterviewEditor.anthropicAPIKey`;
  MARKETING_VERSION bumps to `2.0.0` (new **major**) for this release. The
  rename/bundle-id cutover is **already done** (PR #71 merged: Quick Interview
  Editor → Playola Interview Editor, new bundle id + keychain service, appcast
  moved to `.../downloads/PlayolaInterviewEditor/appcast.xml`). From here on
  never change the Team ID, bundle id, or Sparkle keychain service again — the
  one-time change at n=1 was spent by #71; a second change would strand the
  stored API key.
- Architecture: **MV with `@Observable` models**, zero logic in views, every
  model unit-tested. Models inherit the `ViewModel` base
  (`Views/Reusable Components/ViewModel.swift`), are `@MainActor`, and use the
  standard `// MARK:` section order (Dependencies, Shared State, Initialization,
  Properties, View Helpers, User Actions, Private Helpers).
- No comments in generated code unless it is genuinely non-obvious; avoid `self`
  when unneeded; action-named methods (`openProjectTapped`, not `openProject`);
  `async` methods with the `Task` created in the view.
- `@Dependency` / `@Shared` are `@ObservationIgnored`. Heavy work runs in a
  `task`/`viewAppeared` method invoked from the view, never in `init`.
- Tests: Swift Testing, colocated, camelCase names, `expectNoDifference` /
  `expectDifference` (never raw `#expect(a == b)` for values), no `Task.sleep`,
  no subprocess, bundled fixtures only. The `QuickInterviewEditorTests` target
  must **not** link `Dependencies` directly (only `CustomDump`).
- Dev loop: `make test-fast` (optionally `ONLY=…`); pre-push `make test` +
  `make format-check` + `make lint`. Do **not** run `xcodegen generate` between
  test runs — only when `project.yml` changes.
- The Python engine and the export pipeline are unchanged. `edit-plan.json`
  stays the engine contract.

---

## Orientation — key existing code

- App entry: `QuickInterviewEditor/QuickInterviewEditor/QuickInterviewEditorApp.swift`
  (`WindowGroup { AppLaunchView }` + `.commands` + `Settings`).
- `Views/Pages/AppLaunch/AppLaunchModel.swift` — process-level launch
  (reapStale, engine warm, temp sweep, updater); owns `RootModel` as `root`.
- `Views/Pages/RootPage/RootModel.swift` — custom tabs, import, queue (cap 2).
- `Views/Pages/SongTab/SongTabModel.swift` — one tab; phase
  `queued|transcribing|loaded|failed`; builds `EditorModel` on completion;
  editor teardown sequence.
- `Views/Pages/Editor/EditorModel.swift` — per-song editing root; `mutateDocument`
  (~line 1422), `undoTapped`/`redoTapped` (~1933/1952), `documentState`,
  `@Shared(.projectState)`, `persistTimelineRemovals()`.
- `Views/Pages/CutSuggestions/CutSuggestionsPageModel.swift` — owns its own
  `@Shared(.projectState)`, `acceptTapped`/`rejectTapped`, `runSuggest`.
- `Models/EditorDocumentState.swift`, `Models/UndoStack.swift`, `Models/Slice.swift`,
  `Models/TimelineRemoval.swift`, `Models/CutSuggestion.swift`, `Models/EditPlan.swift`,
  `Models/ProjectState.swift`.
- `Core/CanonicalAudioStore.swift`, `Core/TranscriptCache.swift`,
  `Core/SourceFingerprint.swift`, `Core/TranscriptionCacheKey.swift`,
  `Core/TranscriptionClient.swift`, `Core/EngineFingerprint.swift`.
- `State/ProjectStore.swift` — `@Shared` key `.projectState(fingerprint:)`.
- Commands: `Views/Commands/TranscriptionCommands.swift`, `UpdaterCommands.swift`.
- Tests reference: `QuickInterviewEditorTests/State/ProjectStorePersistenceTests.swift`
  (in-memory `FileStorage` pattern), `RecordIntroPageTests`-style suites.

---

## PR 1 — Package format (no UI, invisible)

**Deliverable:** pure value types for the project package, a codec that
round-trips through a `FileWrapper` tree, UTType + document-type declarations,
and a widened `EditorDocumentState` — all behind no UI, fully tested.

**Spike gate (do first, throwaway):** S1 + S2 from the spec. Prove
`DocumentGroup` + `ReferenceFileDocument` compiles on the macOS 15 / Xcode 16.4
API surface, and measure 50 autosaves against a 500 MB and 1 GB AIFF for
wrapper reuse, save latency, and `.DocumentRevisions` growth. Record findings in
`docs/superpowers/plans/2026-09-04-save-open-project-spike-notes.md`. If S2 shows
Versions copying the AIFF every checkpoint, STOP and escalate before PR 4.

### Task 1.1: Widen `EditorDocumentState`

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Models/EditorDocumentState.swift`
- Test: `QuickInterviewEditorTests/Models/EditorDocumentStateTests.swift`

**Interfaces:**
- Produces: `EditorDocumentState { slices, timelineRemovals, cutSuggestions,
  speakerCountOverride, speakerDisplayNames }` — `Codable, Equatable, Sendable`,
  lenient decode of the three new fields.

- [ ] **Step 1: Write the failing test** — decoding a JSON object that has only
  `slices` + `timelineRemovals` (the old shape) yields empty `cutSuggestions`,
  nil `speakerCountOverride`, empty `speakerDisplayNames`; a full round-trip via
  `JSONEncoder`/`JSONDecoder` is identity.

```swift
@Test func decodesLegacyShapeWithNewFieldDefaults() throws {
  let json = Data(#"{"slices":[],"timelineRemovals":[]}"#.utf8)
  let state = try JSONDecoder().decode(EditorDocumentState.self, from: json)
  expectNoDifference(state.cutSuggestions, [])
  expectNoDifference(state.speakerCountOverride, nil)
  expectNoDifference(state.speakerDisplayNames, [:])
}

@Test func roundTripsAllFields() throws {
  let state = EditorDocumentState(
    slices: [.fixture],
    timelineRemovals: [.fixture],
    cutSuggestions: [.fixture],
    speakerCountOverride: 2,
    speakerDisplayNames: ["0": "Host"]
  )
  let data = try JSONEncoder().encode(state)
  let decoded = try JSONDecoder().decode(EditorDocumentState.self, from: data)
  expectNoDifference(decoded, state)
}
```

- [ ] **Step 2: Run to verify it fails** — `make test-fast ONLY=PlayolaInterviewEditorTests/EditorDocumentStateTests` → FAIL (extra members / missing initializer).
- [ ] **Step 3: Add the three fields** with a custom `init(from:)` using
  `decodeIfPresent` and defaults (mirror `ProjectState`'s lenient decoder), and a
  memberwise `init` with defaults for the new fields so existing call sites keep
  compiling. Confirm `Slice`, `TimelineRemoval`, `CutSuggestion` are already
  `Codable, Sendable` (they are).
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: widen EditorDocumentState to carry suggestions + speaker overrides"`.

### Task 1.2: `ProjectFile` value types

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Models/ProjectFile.swift`
- Test: `QuickInterviewEditorTests/Models/ProjectFileTests.swift`

**Interfaces:**
- Produces: `ProjectFile { schemaVersion: Int; source: ProjectSource;
  engine: ProjectEngineInfo; content: EditorDocumentState }`;
  `ProjectSource { originalFileName, originalPath?, originalFingerprint,
  canonicalFingerprint, canonicalByteCount, importedAt, sampleRate, channels,
  durationSamples }`; `ProjectEngineInfo { engineFingerprint: String }`;
  `enum CanonicalAudioSource: Sendable { case packageChild; case sessionFile(URL) }`.
  All value types `Codable, Equatable, Sendable` except `CanonicalAudioSource`
  which is `Sendable` only (URL is not persisted here). `ProjectFile.currentSchemaVersion = 1`.

- [ ] **Step 1: Write the failing test** — round-trip a `ProjectFile` fixture;
  assert `currentSchemaVersion == 1`; assert lenient decode of a v1 JSON missing
  `originalPath` yields nil.

```swift
@Test func projectFileRoundTrips() throws {
  let file = ProjectFile.fixture
  let data = try JSONEncoder().encode(file)
  expectNoDifference(try JSONDecoder().decode(ProjectFile.self, from: data), file)
}
```

- [ ] **Step 2: Run to verify it fails** (type missing).
- [ ] **Step 3: Implement** the value types with a `ProjectFile.fixture` and
  `ProjectSource.fixture` in the test target (or `#if DEBUG`), lenient
  `decodeIfPresent` for optional fields.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: add ProjectFile package value types"`.

### Task 1.3: Package codec (FileWrapper tree ↔ ProjectFile + EditPlan + audio)

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Core/ProjectPackage.swift`
- Test: `QuickInterviewEditorTests/Core/ProjectPackageTests.swift`

**Interfaces:**
- Consumes: `ProjectFile` (1.2), `EditPlan` (`Models/EditPlan.swift`).
- Produces:
  - `enum ProjectPackageError: Error, Equatable { case missingProjectJSON, missingPlanJSON, missingAudio, unsupportedSchema(Int), audioMismatch }`
  - `struct DecodedPackage { var file: ProjectFile; var plan: EditPlan; var audioWrapper: FileWrapper }`
  - `enum ProjectPackage { static func decode(_ root: FileWrapper) throws -> DecodedPackage; static func encode(file: ProjectFile, plan: EditPlan, audio: FileWrapper) throws -> FileWrapper }`
  - `encode` builds a directory wrapper with children `project.json`, `plan.json`,
    and a subdirectory `audio` containing the passed `canonical.aiff` wrapper
    (preferred filename set).

- [ ] **Step 1: Write the failing tests:**
  - `encode` then `decode` yields the same `file` and `plan`; the audio child
    bytes are preserved.
  - `decode` of a tree missing `project.json` → `missingProjectJSON`; missing
    `plan.json` → `missingPlanJSON`; missing `audio/canonical.aiff` → `missingAudio`.
  - `decode` of a `project.json` with `schemaVersion: 2` → `unsupportedSchema(2)`.
  - Build the input tree in-memory:

```swift
private func tree(projectJSON: Data, planJSON: Data, audio: Data?) -> FileWrapper {
  var children: [String: FileWrapper] = [
    "project.json": FileWrapper(regularFileWithContents: projectJSON),
    "plan.json": FileWrapper(regularFileWithContents: planJSON),
  ]
  if let audio {
    children["audio"] = FileWrapper(directoryWithFileWrappers: [
      "canonical.aiff": FileWrapper(regularFileWithContents: audio)
    ])
  }
  return FileWrapper(directoryWithFileWrappers: children)
}
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** `decode`/`encode`. In `decode`, read
  `project.json`, decode `ProjectFile`, reject `schemaVersion > currentSchemaVersion`,
  then read `plan.json` and locate `fileWrappers?["audio"]?.fileWrappers?["canonical.aiff"]`.
  In `encode`, set each child's `preferredFilename`.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: ProjectPackage FileWrapper codec"`.

### Task 1.4: Audio integrity check

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Core/ProjectPackage.swift`
- Test: `QuickInterviewEditorTests/Core/ProjectPackageTests.swift`

**Interfaces:**
- Produces: `ProjectPackage.verifyAudio(_ wrapper: FileWrapper, against source: ProjectSource) throws`
  — throws `audioMismatch` when the audio child's byte count ≠
  `source.canonicalByteCount`. (Header sample-rate/channel checks are deferred to
  the hydration step in PR 5, where an `AVAudioFile` is opened anyway.)

- [ ] **Step 1: Write the failing test** — a wrapper whose byte count differs
  from `source.canonicalByteCount` throws `audioMismatch`; a matching one does not.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** `verifyAudio` reading `wrapper.regularFileContents?.count`.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: byte-count integrity check for bundled canonical audio"`.

### Task 1.5: UTType + document-type declarations

**Files:**
- Modify: `QuickInterviewEditor/project.yml`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Info.plist`
- (Regenerate once: `cd QuickInterviewEditor && xcodegen generate`)

**Interfaces:**
- Produces: exported UTType `fm.playola.interview-editor.project` conforming
  to `com.apple.package` + `public.composite-content`, extension `pie`;
  a `CFBundleDocumentTypes` entry (role `Editor`, `LSTypeIsPackage = true`)
  referencing it. No consumer until PR 4, but declaring early keeps Open Recent /
  Finder association correct and lets the spike exercise real save/open.

- [ ] **Step 1: Add `UTExportedTypeDeclarations`** to `Info.plist`:

```xml
<key>UTExportedTypeDeclarations</key>
<array>
  <dict>
    <key>UTTypeIdentifier</key><string>fm.playola.interview-editor.project</string>
    <key>UTTypeDescription</key><string>Playola Interview Editor Project</string>
    <key>UTTypeConformsTo</key>
    <array><string>com.apple.package</string><string>public.composite-content</string></array>
    <key>UTTypeTagSpecification</key>
    <dict><key>public.filename-extension</key><array><string>pie</string></array></dict>
  </dict>
</array>
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key><string>Playola Interview Editor Project</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSTypeIsPackage</key><true/>
    <key>LSItemContentTypes</key><array><string>fm.playola.interview-editor.project</string></array>
  </dict>
</array>
```

- [ ] **Step 2:** Mirror any Info.plist keys that `project.yml` manages so
  `xcodegen generate` does not drop them; regenerate once and confirm the plist
  in the generated target keeps the keys.
- [ ] **Step 3:** Build (`make test-fast` compiles the app target) → PASS.
- [ ] **Step 4: Commit** — `git commit -m "feat: declare .pie package UTType + document type"`.

### Task 1.6: Package fixture

**Files:**
- Create: `QuickInterviewEditorTests/Fixtures/project-v1.pie/{project.json,plan.json,audio/canonical.aiff}`
- Modify: `QuickInterviewEditor/project.yml` (add the fixture folder to the test target resources if fixtures are declared there; follow how `edit-plan.json` is bundled)

- [ ] **Step 1:** Build a minimal valid package by hand: `project.json` (schema 1,
  matching `ProjectFile.fixture`), `plan.json` (copy the existing tiny
  `edit-plan.json` fixture), and a **tiny** real AIFF (a few frames — generate
  with `afconvert` or reuse an existing test AIFF) whose byte count matches the
  fixture's `canonicalByteCount`.
- [ ] **Step 2: Write a test** that loads the fixture folder as a
  `FileWrapper(url:options:)` and `ProjectPackage.decode`s it successfully, then
  `verifyAudio` passes.
- [ ] **Step 3:** `make test-fast` → PASS.
- [ ] **Step 4: Commit** — `git commit -m "test: add project-v1.pie package fixture"`.

**PR 1 self-check:** value types + codec + declarations exist and are tested;
nothing user-visible changed; `make test` + `make format-check` + `make lint` green.

---

## PR 2 — One content boundary (invisible)

**Deliverable:** all persisted content (suggestions + speaker overrides included)
flows through `EditorModel.mutateDocument`, which becomes the single dirtiness
signal via a callback. `CutSuggestionsPageModel` stops owning `@Shared`. The app
still works: `SongTabModel` temporarily receives the callback and keeps writing
the legacy sidecar so behavior is unchanged between PRs.

### Task 2.1: `mutateDocument` carries the full document + emits a change callback

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift`
- Test: `QuickInterviewEditorTests/Editor/EditorDocumentMutationTests.swift`

**Interfaces:**
- Produces on `EditorModel`:
  - `var documentState: EditorDocumentState` now includes `cutSuggestions`,
    `speakerCountOverride`, `speakerDisplayNames` (backed by stored properties on
    the model, seeded in `init`).
  - `var onDocumentStateChanged: (@MainActor (EditorDocumentState) -> Void)?`
  - `func mutateDocument(recordUndo: Bool = true, _ body: (inout EditorDocumentState) -> Void)`
    — applies, records undo when `recordUndo`, then calls
    `onDocumentStateChanged?(documentState)`.
- Consumes: `EditorDocumentState` (1.1).

- [ ] **Step 1: Write failing tests:**
  - a `mutateDocument` that adds a slice calls `onDocumentStateChanged` once with
    the new state.
  - a no-op `mutateDocument` (body changes nothing) still calls the callback but
    records no undo entry (`canUndo` stays false) — matches existing no-op undo behavior.
  - `mutateDocument(recordUndo: false)` dirties (callback fires) but leaves
    `canUndo` unchanged.

```swift
@Test func mutateDocumentEmitsChange() {
  @Shared(.projectState) var projectState = .fixture   // still present in PR 2
  let model = EditorModel.fixture()
  var seen: [EditorDocumentState] = []
  model.onDocumentStateChanged = { seen.append($0) }
  model.mutateDocument { $0.slices.append(.fixture) }
  expectNoDifference(seen.count, 1)
  expectNoDifference(seen.last?.slices.last, .fixture)
}
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement.** Add the stored properties + widen `documentState`'s
  getter/setter (or computed assembly) to include the new fields; add
  `recordUndo` and the callback to `mutateDocument`; keep `undoTapped`/`redoTapped`
  calling `onDocumentStateChanged` after restoring. Leave `persistTimelineRemovals`
  in place for now (still called from `mutateDocument`).
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: EditorModel.mutateDocument carries full document + change callback"`.

### Task 2.2: Move cut-suggestion + speaker mutations onto the funnel

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/CutSuggestions/CutSuggestionsPageModel.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift`
- Test: `QuickInterviewEditorTests/CutSuggestions/CutSuggestionsPageTests.swift`,
  `QuickInterviewEditorTests/Editor/EditorSuggestionFlowTests.swift`

**Interfaces:**
- Produces on `CutSuggestionsPageModel`: removes `@Shared(.projectState)`; reads
  suggestions from an injected/observed source; emits intents:
  - `var onAccept: (@MainActor (CutSuggestion.ID) -> Void)?`
  - `var onReject: (@MainActor (CutSuggestion.ID) -> Void)?`
  - `var onSuggestionsProduced: (@MainActor ([CutSuggestion]) -> Void)?`
  - `var onSpeakerOverridesChanged: (@MainActor (Int?, [String: String]) -> Void)?`
- Produces on `EditorModel`: handlers wired to these that call `mutateDocument`
  (`onSuggestionsProduced` uses `recordUndo: false`), plus the existing
  `acceptCutSuggestion(...)` → `onAcceptSlice` slice creation preserved.

- [ ] **Step 1: Write failing tests:**
  - `CutSuggestionsPageModel.acceptTapped(id)` invokes `onAccept(id)` and owns no
    `@Shared`.
  - In `EditorModel`, accepting a suggestion marks it accepted **and** is undoable
    (`canUndo == true`, `undoTapped` reverts the status) and fires
    `onDocumentStateChanged`.
  - The background suggestion pass (`recordUndo: false`) adds suggestions,
    dirties, but leaves `canUndo == false`.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement.** In `CutSuggestionsPageModel`, replace every
  `$projectState.withLock { … }` with the matching intent closure; `runSuggest`
  calls `onSuggestionsProduced`. In `EditorModel`, wire the child's closures in
  the place it already sets `onAcceptSlice`/`onSelectSuggestion`, routing through
  `mutateDocument`. `acceptSuggestion`/`rejectSuggestion` logic moves to operate on
  `documentState.cutSuggestions`.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: route cut-suggestion + speaker edits through mutateDocument"`.

### Task 2.3: Temporary sidecar bridge on the tab model

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabModel.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift`
  (remove the editor's own `@Shared(.projectState)` write path)
- Test: `QuickInterviewEditorTests/SongTab/SongTabPersistenceBridgeTests.swift`

**Interfaces:**
- Consumes: `EditorModel.onDocumentStateChanged` (2.1).
- Produces: `SongTabModel` sets `editor.onDocumentStateChanged` to persist the
  document into the legacy `.projectState(fingerprint:)` sidecar (removals +
  suggestions + speaker fields). This keeps existing persistence behavior alive
  and centralizes it, so `EditorModel` no longer touches `@Shared`.

- [ ] **Step 1: Write the failing test** — after a `mutateDocument`, the tab's
  bridge writes the expected fields into an in-memory `@Shared(.projectState)`
  (use the in-memory `FileStorage` pattern from `ProjectStorePersistenceTests`).
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** the bridge in `SongTabModel` where it builds the
  `EditorModel`; delete `EditorModel`'s `@Shared(.projectState)` property,
  `persistTimelineRemovals()`, and its seeding read (move the initial-seed read
  into `SongTabModel`, passing an initial `EditorDocumentState` into the editor's
  init).
- [ ] **Step 4: Run** the full editor + tab suites → PASS (this is the risky
  refactor; run `make test-fast` broadly, not one suite).
- [ ] **Step 5: Commit** — `git commit -m "refactor: centralize sidecar persistence on SongTabModel via change callback"`.

**PR 2 self-check:** app behaves exactly as before (still sidecar-persisted); the
editor no longer owns `@Shared`; suggestions/speaker edits are undoable; green
`make test` + format + lint.

---

## PR 3 — `ProjectModel` + `TranscriptionQueueClient` (invisible)

**Deliverable:** a document-level `ProjectModel` with phases, a shared
transcription queue dependency, and a `ProjectDocumentSink` seam — tested at the
model level. Still wired under the existing `RootModel`/tab UI (no scene change
yet), so the app keeps running.

### Task 3.1: `TranscriptionQueueClient` dependency

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Core/TranscriptionQueueClient.swift`
- Test: `QuickInterviewEditorTests/Core/TranscriptionQueueClientTests.swift`

**Interfaces:**
- Consumes: `TranscriptionClient` (`transcribe: (URL, String, CachePolicy) -> AsyncThrowingStream<EngineEvent, Error>`).
- Produces: `struct TranscriptionQueueClient: Sendable { var enqueue: @Sendable (TranscriptionJob) async -> AsyncThrowingStream<EngineEvent, Error> }`
  with `struct TranscriptionJob: Sendable { var source: URL; var sourceFingerprint: String; var policy: CachePolicy }`;
  `liveValue` wraps `TranscriptionClient` behind an actor enforcing **max 2**
  concurrent jobs; `testValue` returns the underlying stream immediately (no queue).
  `DependencyValues.transcriptionQueue`.

- [ ] **Step 1: Write failing tests** (test the queue actor, not timing): with a
  cap of 2 and 3 enqueued jobs backed by a controllable fake, the third does not
  start until one of the first two finishes. Use a fake whose streams you finish
  explicitly via continuations — **no `Task.sleep`**.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** the client + queue actor + `DependencyKey`
  (`liveValue`/`testValue`). Follow `pfw-dependencies` (`static var`,
  `Sendable`).
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: TranscriptionQueueClient with max-2 concurrency"`.

### Task 3.2: `ProjectDocumentSink` seam

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Models/ProjectDocumentSink.swift`
- Test: covered via `ProjectModel` tests (3.3).

**Interfaces:**
- Produces: `struct ProjectDocumentSink: Sendable {
  var commit: @MainActor (ProjectFile, EditPlan?, CanonicalAudioSource?) -> Void;
  var registerChange: @MainActor () -> Void }`
  plus a test recorder factory `ProjectDocumentSink.recorder()` returning the sink
  and an observable record of calls (in the test target).

- [ ] **Step 1:** No standalone test; define the struct.
- [ ] **Step 2:** Add a `#if DEBUG`/test-target recorder used by 3.3.
- [ ] **Step 3: Commit** — `git commit -m "feat: ProjectDocumentSink seam"`.

### Task 3.3: `ProjectModel` (phases, transcription, editor, migration seeding)

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Project/ProjectModel.swift`
- Test: `QuickInterviewEditorTests/Project/ProjectModelTests.swift`

**Interfaces:**
- Consumes: `TranscriptionQueueClient` (3.1), `ProjectDocumentSink` (3.2),
  `EditorModel`, `ProjectFile`/`ProjectSource`/`CanonicalAudioSource`,
  `TranscriptCache`, legacy `.projectState` sidecar, `SourceFingerprint`,
  `EngineFingerprint`.
- Produces: `@MainActor @Observable final class ProjectModel: ViewModel` with
  - `enum Phase: Equatable { case empty; case queued; case transcribing(Double); case loaded; case failed(String) }`
  - `var phase: Phase`; `var editor: EditorModel?`
  - `init(file: ProjectFile?, plan: EditPlan?, audio: CanonicalAudioSource?, sink: ProjectDocumentSink)`
    — `file == nil` ⇒ `.empty`; a decoded file ⇒ builds the editor on `viewAppeared`.
  - `func importAudioTapped(_ url: URL) async` — fingerprints, seeds from legacy
    sidecar once, consults cache, enqueues transcription, drives `phase`, on
    completion builds the editor and `sink.commit(file, plan, .sessionFile(url))`.
  - `func viewAppeared() async` — for the loaded-from-file case, hydrate the
    editor (audio hydration itself lands in PR 5; here it builds against the
    committed source).
  - Wires `editor.onDocumentStateChanged = { [weak self] state in
    self?.sink.commit(updatedFile, nil, nil); self?.sink.registerChange() }`.
  - Editor teardown sequence copied verbatim from `SongTabModel`.

- [ ] **Step 1: Write failing tests** (inject `transcriptionQueue` testValue +
  a `ProjectDocumentSink.recorder()`; `@Shared(.projectState)` declared locally
  where migration is exercised):
  - fresh `ProjectModel(file: nil, …)` is `.empty`; `importAudioTapped` moves
    `.queued → .transcribing → .loaded`, builds `editor`, and calls `sink.commit`
    once with `.sessionFile`.
  - while `.empty` or `.transcribing`, no `registerChange` is recorded.
  - an `editor.mutateDocument` after load records exactly one `registerChange` and
    one `commit`.
  - migration: with a matching legacy sidecar in in-memory storage, the built
    editor's `documentState` is seeded with the sidecar's removals/suggestions.
  - failure: a throwing queue stream drives `.failed(message)`.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** `ProjectModel`, porting `SongTabModel`'s phase logic,
  `withDependencies(from: self)` editor construction, and teardown. Follow
  `pfw-observable-models` (no heavy work in `init`; `viewAppeared`/`importAudioTapped`
  are the task methods). Assert cases with `pfw-case-paths`.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: ProjectModel document-level phases + transcription + migration seeding"`.

### Task 3.4: Port `SongTabModel` phase tests to `ProjectModel`

**Files:**
- Modify/Move: relevant cases from `QuickInterviewEditorTests/SongTab/*` into
  `ProjectModelTests`.

- [ ] **Step 1:** Copy the still-relevant `SongTabModel` behavior tests
  (phase transitions, teardown, cache policy) and adapt them to `ProjectModel`.
- [ ] **Step 2:** `make test-fast` → PASS.
- [ ] **Step 3: Commit** — `git commit -m "test: port tab phase tests to ProjectModel"`.

**PR 3 self-check:** `ProjectModel` fully tested; no scene change yet;
`RootModel`/`SongTabModel` still drive the UI; green `make test` + format + lint.

---

## PR 4 — Document shell (USER-VISIBLE switch)

**Deliverable:** the app becomes document-based. `DocumentGroup` + `ProjectDocument`
+ `ProjectHostView`, one project per window, focused commands, Undo/Redo menu
items, dirtiness + autosave, first save, and open with audio hydration. Delete
`RootModel`, the custom tab bar, and `SongTabModel`.

**Spike gate (do first):** S3 (UndoManager dirtiness bridge) and S5 (nonisolated
`init` → `@MainActor` model with zero Swift 6 diagnostics). Record in the spike
notes file. If S3 fails, escalate before proceeding.

### Task 4.1: `ProjectDocument: ReferenceFileDocument`

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Documents/ProjectDocument.swift`
- Test: `QuickInterviewEditorTests/Documents/ProjectDocumentTests.swift`

**Interfaces:**
- Consumes: `ProjectPackage` (1.3), `ProjectFile`, `EditPlan`, `CanonicalAudioSource`.
- Produces: `final class ProjectDocument: ReferenceFileDocument` (nonisolated
  read/write hooks):
  - `static var readableContentTypes: [UTType] = [.pieProject]` (define
    `UTType.pieProject` from the exported id)
  - stored: `var file: ProjectFile; var plan: EditPlan; var audio: CanonicalAudioSource`
  - `struct Snapshot: Sendable { var file: ProjectFile; var plan: EditPlan; var audio: CanonicalAudioSource }`
  - `init(configuration:)` → `ProjectPackage.decode`, sets `audio = .packageChild`
  - `snapshot(contentType:)` → returns the current values
  - `fileWrapper(snapshot:configuration:)` → reuse
    `configuration.existingFile?.fileWrappers?["audio"]` when `snapshot.audio` is
    `.packageChild`, else wrap the session file lazily via `FileWrapper(url:)`;
    then `ProjectPackage.encode`. Guard the audio child reuse so Save As /
    Duplicate (no `existingFile`) fall back to the session file.

- [ ] **Step 1: Write failing tests** driving the codec through the document:
  - `init(configuration:)` from the `project-v1.pie` fixture wrapper decodes
    `file`/`plan` and sets `audio == .packageChild`.
  - `fileWrapper` with `snapshot.audio == .packageChild` and a supplied
    `existingFile` reuses the same audio child wrapper instance (assert the wrapper
    returned for `audio/canonical.aiff` is the reused one, e.g. by identity of
    contents / no re-read).
  - `fileWrapper` with `snapshot.audio == .sessionFile(url)` writes the file's
    bytes. Construct `FileDocumentReadConfiguration` / `WriteConfiguration` via a
    helper that builds them from a `FileWrapper` (they are structs with
    `contentType` + wrapper).
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement.** Keep every hook `nonisolated`; the `Snapshot` is a
  `Sendable` value so no main-actor state crosses the boundary (S5). Follow
  `pfw-modern-swiftui` for the scene wiring in 4.2.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: ProjectDocument ReferenceFileDocument with audio-wrapper reuse"`.

### Task 4.2: `DocumentGroup` scene + `ProjectHostView` + dirtiness bridge

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/QuickInterviewEditorApp.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Project/ProjectHostView.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Project/ProjectView.swift`
  (moves the editor/empty/transcribing visuals out of the old tab view)
- Test: dirtiness bridge covered via `ProjectModel` sink tests (already) + a
  small host smoke assertion where practical.

**Interfaces:**
- Consumes: `ProjectDocument` (4.1), `ProjectModel` (3.3), `AppLaunchModel`.
- Produces:
  - `DocumentGroup(newDocument: { ProjectDocument.empty() }) { config in
    ProjectHostView(document: config.document, fileURL: config.fileURL) }`
  - `ProjectHostView` holds `@State private var model: ProjectModel` built from
    the document via a `ProjectDocumentSink` whose `registerChange()` registers a
    single `UndoManager` action (`levelsOfUndo` handling per S3) so the document
    goes dirty and autosaves; `commit` writes back into the `ProjectDocument`
    values via `document.objectWillChange`/`ReferenceFileDocument` change tracking.
  - `.task { await model.viewAppeared() }`; view carries no logic.
  - Keep the `Settings` scene and `UpdaterCommands`. Move the process-level
    `AppLaunchModel` work to app `init` / an app-level environment object; show its
    readiness state inside `ProjectHostView` before the project UI.

- [ ] **Step 1:** Implement the scene + host + view; wire the sink's
  `registerChange` to the environment `@Environment(\.undoManager)`.
- [ ] **Step 2:** Manual verify (documented checklist in the PR): import audio →
  edit → the window shows the edited dot; Cmd-S prompts for a location for a new
  project; after save, edits mark dirty and autosave; File > Revert To… lists
  versions.
- [ ] **Step 3:** `make test-fast` → PASS (model tests unaffected).
- [ ] **Step 4: Commit** — `git commit -m "feat: DocumentGroup scene + ProjectHostView + UndoManager dirtiness"`.

### Task 4.3: Open with audio hydration

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Project/ProjectModel.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Core/CanonicalAudioStore.swift`
  (add a clone-in entry point if not present)
- Test: `QuickInterviewEditorTests/Project/ProjectHydrationTests.swift`

**Interfaces:**
- Produces: on load-from-file, `ProjectModel.viewAppeared` clones the package's
  `audio/canonical.aiff` into a fresh `CanonicalAudioStore` session dir (APFS
  clone via `FileManager.copyItem`) and builds the `EditorModel` against that
  copy; on failure → `.failed`. Reading the package by URL here is the one
  sanctioned spot (spec A5).

- [ ] **Step 1: Write failing tests** — given a decoded document whose audio is a
  temp `canonical.aiff`, hydration produces an `EditorModel` whose
  `canonicalAudioURL` is a session-store path distinct from the package path;
  a clone failure yields `.failed`. Inject the store's base dir via a test temp dir.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** the clone-in + editor build. Move (`CanonicalAudioSource`
  from `.packageChild` to the session path is implicit — the editor always uses the
  session copy).
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: hydrate canonical audio from package into session store on open"`.

### Task 4.4: Focused commands + Undo/Redo menu + delete legacy UI

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Commands/TranscriptionCommands.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Commands/EditUndoCommands.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/SlicesPanelView.swift`
  (remove the `keyboardShortcut("z")` modifiers from the panel buttons)
- Delete: `Views/Pages/RootPage/RootModel.swift` + its view,
  `Views/Pages/SongTab/SongTabModel.swift` + its view, and the tab-bar view;
  update/remove their tests.
- Test: `QuickInterviewEditorTests/Commands/EditUndoCommandsTests.swift` (model-
  level: the focused-project routing helper), plus manual menu verification.

**Interfaces:**
- Produces:
  - `@FocusedValue(\.projectModel)` set by `ProjectHostView`.
  - `EditUndoCommands: Commands` with `CommandGroup(replacing: .undoRedo)`:
    Undo/Redo buttons routed to `focusedProject?.editor?.undoTapped()/redoTapped()`,
    labels `undoLabel`/`redoLabel`, enabled by `canUndo`/`canRedo`,
    shortcuts `⌘Z` / `⇧⌘Z`.
  - `TranscriptionCommands` re-targets the focused project (re-transcribe ignoring
    cache), cache clearing stays app-level.

- [ ] **Step 1: Write the failing test** for the small routing helper (given a
  focused project with `canUndo`, the command's enabled state and action resolve
  to the editor's).
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** the commands + `@FocusedValue`; remove the panel
  shortcuts; delete `RootModel`/`SongTabModel` and the tab bar; delete or port
  their tests.
- [ ] **Step 4: Run** full `make test` (large deletion — run everything);
  manual menu verify (Cmd-Z from the menu undoes; disabled with empty history).
- [ ] **Step 5: Commit** — `git commit -m "feat: focused Undo/Redo + re-transcribe commands; remove RootModel/SongTabModel/tab bar"`.

**PR 4 self-check:** app opens/saves/autosaves `.pie`; one project per window;
menus route to the focused project; no `RootModel`/`SongTabModel`; the spec's
S1–S3/S5 spikes passed; green `make test` + format + lint; PR description carries
the manual-verify checklist (import, edit, save, autosave, Revert To…, open,
re-transcribe).

---

## PR 5 — Re-transcribe identity + cleanup (mostly invisible)

**Deliverable:** re-transcription from a saved project uses the bundled canonical
AIFF with a canonical-fingerprint cache key; the legacy sidecar write path is
removed (read-only migration remains); docs + release notes for the major version.

### Task 5.1: Canonical fingerprint on import + re-transcribe cache key

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Project/ProjectModel.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Core/TranscriptionCacheKey.swift`
  (only if a helper is needed; the key already takes a `sourceFingerprint`)
- Test: `QuickInterviewEditorTests/Project/ReTranscribeIdentityTests.swift`

**Interfaces:**
- Produces: on import, `ProjectSource.canonicalFingerprint` = `SourceFingerprint`
  of the canonical AIFF bytes + `canonicalByteCount`. Re-transcribe from a saved
  project builds a `TranscriptionJob`/cache key using `canonicalFingerprint`
  (not the original MP3 fingerprint), so a Versions-restored or copied project
  never collides with the original import's key.

- [ ] **Step 1: Write failing tests** — re-transcribe on a loaded-from-file
  project enqueues a job whose fingerprint equals `source.canonicalFingerprint`;
  import records a non-empty `canonicalFingerprint` and correct `canonicalByteCount`.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement.** Compute the canonical fingerprint at commit time;
  thread it into the re-transcribe path.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "feat: canonical-fingerprint identity for re-transcribe from saved projects"`.

### Task 5.2: Remove the legacy sidecar write path

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Project/ProjectModel.swift`
  (drop the temporary bridge write; keep the migration **read**)
- Modify: `QuickInterviewEditor/QuickInterviewEditor/State/ProjectStore.swift`
  (keep the key for read-only migration; annotate as legacy)
- Test: `QuickInterviewEditorTests/Project/MigrationReadOnlyTests.swift`

**Interfaces:**
- Produces: `.projectState(fingerprint:)` is read once during import migration and
  never written. Document state persists only through the package.

- [ ] **Step 1: Write the failing test** — after a `mutateDocument` on a
  loaded-from-file project, no write occurs to the in-memory `.projectState`
  storage (only the document sink commits).
- [ ] **Step 2: Run to verify it fails** (the PR 2 bridge still writes).
- [ ] **Step 3: Implement** — remove the bridge write now that `ProjectDocument`
  owns persistence.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "refactor: legacy sidecar is read-only migration input; document owns persistence"`.

### Task 5.3: Docs + release notes + version bump

**Files:**
- Modify: `QuickInterviewEditor/project.yml` (MARKETING_VERSION major bump)
- Modify: `CLAUDE.md` project structure note (document-based; `Documents/`)
- Create/Modify: release notes / appcast entry per the distribution flow
  (`document-release` skill when shipping).

- [ ] **Step 1:** Bump `MARKETING_VERSION` to the new major; `xcodegen generate`
  once; confirm build.
- [ ] **Step 2:** Update `CLAUDE.md` "Project structure" to reflect
  `Documents/ProjectDocument.swift`, `Views/Pages/Project/**`, and the removal of
  `RootModel`/`SongTabModel`.
- [ ] **Step 3:** `make test` + `make format-check` + `make lint` → all green.
- [ ] **Step 4: Commit** — `git commit -m "docs: document-based app structure + major version bump"`.

**PR 5 self-check:** re-transcribe identity correct; no sidecar writes; migration
read still works; docs updated; green `make test` + format + lint.

---

## Self-Review (plan vs spec)

- **Spec coverage:** A1 document framework → PR4/4.1–4.2; A2 ownership → 1.2/3.3/4.1;
  A3 window model + queue + focused commands → 3.1/3.3/4.2/4.4; A4 layout/UTType/
  compat → 1.3/1.5; A5 audio never re-serialized → 4.1 (reuse) + 4.3 (hydrate);
  A6 one content boundary → 1.1/2.1/2.2; A7 dirtiness/undo/autosave → 2.1/4.2/4.4
  + S3; A8 migration/cache/canonical key → 3.3 (seed) + 5.1/5.2; A9 error handling
  → 1.3/1.4/4.3/`reportIssue`; A10 testing → every task's tests. Spikes S1–S5
  gated at PR 1 and PR 4.
- **Placeholder scan:** no TBD/TODO; every code step shows the test or the type.
- **Type consistency:** `EditorDocumentState` (five fields) used identically in
  1.1/2.1/3.3; `ProjectFile`/`ProjectSource`/`CanonicalAudioSource` consistent
  across 1.2/1.3/4.1/5.1; `ProjectDocumentSink.{commit,registerChange}` consistent
  3.2/3.3/4.2; `ProjectModel.Phase` cases consistent 3.3/4.x;
  `onDocumentStateChanged` signature consistent 2.1/2.2/3.3.

## Execution notes

- Delegate implementation tasks to **Sonnet** subagents (per repo model tiering);
  escalate only a genuinely hard task (e.g. the S3 UndoManager bridge or the
  4.1 nonisolated/`@MainActor` concurrency) to Opus. Every subagent must invoke
  the relevant `pfw-*` skills first and list them.
- After a non-trivial PR's diff is ready, run the Codex adversarial pass
  (`codex` review then challenge) before opening the PR; fix everything it
  surfaces. Skip it for the trivial doc/version tasks.
- Prototype the spikes as throwaway branches; do not merge spike code.
