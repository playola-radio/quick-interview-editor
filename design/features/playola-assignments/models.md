# Playola Assignments — Model changes

This app has no database. Here, "models" means the on-disk `.pie` project contract,
the library's on-disk files, persisted settings, the Keychain items, and the in-memory
or Codable types that cross a dependency boundary. **No server models change in this
repo.** The server-side fields this feature needs are listed in `endpoints.md`.

| Change | Model | Storage | Summary |
|---|---|---|---|
| Changed | `ProjectFile` | `<project>.pie/project.json` | Adds optional `playola` link, written as schema 4 |
| New | `PlayolaProjectLink` | inside `project.json` | Which Playola tape, job, station and environment a project belongs to |
| New | `LibraryManifest` | `<library root>/.library.json` | Remembers removed tapes and published projects |
| New | Library layout | `<library root>/…` | Folders, `.originals/`, `.staging/`, `.lock` |
| New | Playola token | Keychain generic password | One JWT per environment |
| New | `PlayolaEnvironment` | `appStorage` + code | production / staging / local |
| New | `PlayolaAccount`, `PlayolaUser` | `@Shared(.playolaAccount)`, in memory | Signed-in user for the active environment |
| New | Settings keys | `appStorage` (UserDefaults) | Auto-download, auto-transcribe, library root, environment, launch hint |
| New | API DTOs | not stored | `PlayolaJob`, `PlayolaStationSummary`, `PlayolaSourceTape`, `PlayolaJobAssignee` |
| New | `TapeKey`, `LocalAvailability`, `TapeOperation`, `TapeFailure` | in memory | Per-tape state behind each Assignments row |

## ProjectFile (`project.json`) — Changed

| Field | Type | Null | Default | Change | Notes |
|---|---|---|---|---|---|
| `schemaVersion` | Int | no | | Changed | Written as **4** when `playola` is set. Otherwise unchanged: 3 with a mastering run, 2 without. |
| `playola` | `PlayolaProjectLink` | yes (key omitted) | absent | Added | Present only for projects created from an assignment |

- **Constants** (replacing today's overloaded pair):
  - `baseSchemaVersion = 2`
  - `masteringSchemaVersion = 3`
  - `linkedSchemaVersion = 4`
  - `maximumReadableSchemaVersion = 4` (was 3)
- **Write rule:** `playola != nil → 4`, else `masteringRun != nil → 3`, else `2`. The
  path that preserves a corrupt mastering manifest writes
  `max(3, writtenSchemaVersion(for:))`.
- **Read rule:** 1…4 are accepted, and above 4 shows the existing "newer version"
  alert. "Mastering manifest corrupt" is tracked explicitly. It is no longer inferred
  from "schema ≥ 3 and `masteringRun == nil`", because a healthy schema-4 project may
  have no mastering run.
- **Who reads it:** `ProjectPackage.decode` and `ProjectModel`, for the editor
  subtitle and to keep the link on re-transcribe.
  `InterviewLibraryClient.scan` reads only `schemaVersion` and `playola`.
- **Migration:**
  - Existing projects are untouched and stay at version 2 or 3.
  - A project becomes 4 only when the library creates it from an assignment.
  - There is no backfill. An existing manual project is never linked after the fact.
- **Deploy compatibility (deliberate):**
  - Apps from 2.6.x and earlier **refuse** schema-4 projects with their existing
    "saved by a newer version" alert.
  - They can't be allowed to open them: they would rewrite `project.json` without the
    unknown `playola` key on the first autosave and silently unlink the project.
  - Manual projects remain openable by older apps.
- **Data at risk:** none. Old apps refuse to open the file rather than rewriting it.

## PlayolaProjectLink — New

| Field | Type | Null | Notes |
|---|---|---|---|
| `environment` | `PlayolaEnvironment` (`"production"`/`"staging"`/`"local"`) | no | Picks which server and token any future server call for this project uses |
| `sourceTapeId` | String (UUID) | no | **Identity** together with `environment` |
| `jobId` | String (UUID) | no | Provenance (the job at creation). A future upload re-checks the current job. |
| `stationId` | String (UUID) | no | |
| `stationName` | String | no | Snapshot at creation, never updated. Shown in the editor subtitle offline. |
| `tapeName` | String | no | Snapshot at creation, never updated |

```json
"playola": {
  "environment": "production",
  "sourceTapeId": "t-91…", "jobId": "5b0d…", "stationId": "a1f3…",
  "stationName": "KXYZ Morning", "tapeName": "Interview with Jane"
}
```

- **Source of truth:**
  - The ids are authoritative for which tape a project belongs to.
  - The names are a display snapshot only. The Assignments list always shows current
    server names.
- **Upload-later compatibility:** environment, tape and station ids are what a future
  upload needs. Adding upload-related fields later is additive at schema 4, because
  4-capable readers decode the link leniently.

## LibraryManifest (`<library root>/.library.json`) — New

| Field | Type | Notes |
|---|---|---|
| `version` | Int | `1` |
| `suppressedTapes` | `[TapeKey]` | Tapes the editor chose "Remove from this Mac" for. Auto-download skips them, and an explicit Download clears the entry. Read by the coordinator before queueing. |
| `knownProjects` | `[TapeKey]` | Every tape whose project was published here, or later found by a scan. If a complete scan can't find one, the row shows "Project missing" and automatic work leaves it alone. |

- **Source of truth:**
  - Packages are authoritative for which project belongs to which tape and where it
    lives. The tape → path lookup is rebuilt in memory on every scan and never saved.
  - The manifest holds only the two facts a scan can't recover.
  - On a conflict, the package wins: a scanned package is added to `knownProjects`.
- **Narrowed from the brief:** the brief's draft index also cached package paths,
  original paths and server metadata. Those are derivable (paths come from scanning,
  metadata from the next refresh), so they are left out to avoid two sources of truth.
- **Missing file:** start empty (a new or repointed root).
- **Corrupt file:** move it aside to `.library.json.corrupt-<timestamp>` and **pause
  automatic work** with a banner. Explicit actions still work. Resetting it would
  re-download tapes the editor removed.
- **Writes:** only under the library `flock`, written atomically (`Data.write(options: .atomic)`).

## Library layout — New

```
<root>/                                   default ~/Music/Playola Interview Editor/
  <Station name> (<stationId first 8>)/<Tape name>.pie     production
  Staging/<Station…>/<Tape>.pie                            staging environment
  Local/<Station…>/<Tape>.pie                              local environment
  .originals/[staging/|local/]<sourceTapeId>.<wav|m4a>     verified downloads awaiting preparation
  .staging/<attempt-uuid>/                                 in-flight downloads; wiped at launch
  <station folder>/.<uuid>.pie.partial                     in-flight publish; swept at launch
  .library.json                                            manifest (above)
  .lock                                                    flock target; never deleted
```

- **Names:**
  - Sanitized by a shared `sanitizedFileStem`, which is `ExportNaming`'s rules plus a
    byte budget reserved for the suffix and extension.
  - Collisions get `" 2"`, `" 3"`, … from the existing `nextExportCollisionSuffix`.
  - Names are fixed at creation and never renamed.
- **Retention (Q4 as recommended):** an original is deleted after its `.pie` is
  published and verified. If you choose "keep until job completed" instead, originals
  stay until the per-job "Free up space" action.

## Playola token (Keychain) — New

| Attribute | Value |
|---|---|
| Class | `kSecClassGenericPassword` |
| `kSecAttrService` | `fm.playola.PlayolaInterviewEditor.playolaToken` (a **stable literal**, pinned by a test, same invariant as the Anthropic key) |
| `kSecAttrAccount` | `production` \| `staging` \| `local` |
| Value | The JWT, UTF-8 |

- **Who reads it:** `PlayolaTokenStore.load(environment)` at launch and on an
  environment switch, off the main thread.
- **Who deletes it:** sign-out, and the 401 rule (only for the matching session
  generation). It is **never deleted on a read error**.
- **Migration:** none. This is a new item. It survives Sparkle updates because the
  bundle id, team and service don't change.

## PlayolaEnvironment — New

`enum PlayolaEnvironment: String, Codable, CaseIterable { case production, staging, local }`

| Case | Base URL | Library subfolder |
|---|---|---|
| `production` | `https://admin-api.playola.fm` | none (root) |
| `staging` | `https://admin-api-staging.playola.fm` | `Staging/` |
| `local` | `http://localhost:10020` | `Local/` |

These match `playola-radio-ios` `Config.swift`. Release builds always resolve to
`production`.

## PlayolaAccount / PlayolaUser — New (`@Shared(.playolaAccount)`, in-memory)

| Field | Type | Null | Notes |
|---|---|---|---|
| `environment` | `PlayolaEnvironment` | no | |
| `user` | `PlayolaUser` | yes | `nil` while signed out or restoring |
| `user.id` | String | no | |
| `user.firstName` | String | no | |
| `user.lastName` | String | yes | Optional, matching the iOS `LoggedInUser` |
| `user.email` | String | no | |
| `user.profileImageUrl` | URL | yes | |
| `user.role` | String | no | Kept as a raw string so unknown roles still decode |

- **Source of truth:** the server (`GET /v1/users/me`). It is refilled on launch and
  sign-in, and not persisted. Only the token persists.
- **Writer:** `AssignmentsCoordinator` only. Pages read it.

## Settings keys (`appStorage`) — New

| Key | Type | Default | Read by |
|---|---|---|---|
| `autoDownloadAssignments` | Bool | `true` | Coordinator, when queueing new tapes |
| `autoPrepareAssignments` | Bool | `true` | Coordinator, after a verified download |
| `libraryRootPath` | String | `~/Music/Playola Interview Editor` (expanded) | `InterviewLibraryClient` |
| `playolaEnvironment` | String | `production` | Session; ignored in Release builds |
| `launchesToAssignments` | Bool | `false` | App scene setup at launch; cleared on sign-out or 401 |

## API DTOs — New (not stored)

All of these are decoded leniently: unknown keys are ignored and unknown `status`
strings decode to `.unknown`. They are defined only in `PlayolaAPIClient.swift`.

- **`PlayolaJob`:**
  - `id`, `stationId`, `name`, `description?`
  - `assignedTo?`, `assignedAt?`, `completedAt?`, `createdAt`, `updatedAt`
  - `station: PlayolaStationSummary?`, `assignee: PlayolaJobAssignee?`
  - `sourceTapes: [PlayolaSourceTape]`
  - `submissions` is ignored.
- **`PlayolaStationSummary`:** `id`, `name`, `imageUrl?`.
- **`PlayolaSourceTape`:**
  - `id`, `stationId`, `name`, `durationMS`
  - `status: SourceTapeStatus` (`new`, `inProgress`, `processingCompleted`,
    `rejected`, `unknown`)
  - `fileSizeBytes?`, `fileExtension?`, `downloadUrl: URL?`
  - `createdAt`, `updatedAt`
  - `previewUrl` is ignored.
- **`PlayolaJobAssignee`:** `id`, `firstName`, `lastName?`, `email`, `profileImageUrl?`.
- **`TokenExchangeResponse`:** `playolaToken`.
- **Dates:** ISO-8601 is accepted with or without fractional seconds.

## Per-tape state — New (in memory)

| Type | Definition |
|---|---|
| `TapeKey` | `{ environment: PlayolaEnvironment, sourceTapeId: String }` (Codable and Hashable, used in the manifest) |
| `LocalAvailability` | `none` · `original(URL)` · `project(URL)` · `missingProject` · `conflict([URL])` |
| `TapeOperation` | `idle` · `queued` · `downloading(fraction: Double?)` · `waitingForModels` · `preparing(EngineProgress?)` · `failed(TapeFailure)` |
| `TapeFailure` | `{ step: download \| verify \| transcribe \| publish \| refreshJob, message: String, detail: String (redacted, copyable), retryable: Bool }` |
| `TapeRecord` | `{ key, job: PlayolaJob?, tape: PlayolaSourceTape?, isAssigned: Bool, availability, operation, openWhenReady: Bool }` |

- **Source of truth:**
  - `availability` is derived from the library scan.
  - `isAssigned`, `job` and `tape` come from the last **successful** refresh.
  - `operation` lives only in memory and is never persisted, so after a relaunch it
    is re-derived from the files.
