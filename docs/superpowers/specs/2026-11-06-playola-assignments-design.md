# Playola Assignments — Design

**Status:** Draft, awaiting Brian's approval. No product code is written until it is approved.
**Date:** 2026-11-06
**Author:** Brian (brief), with Claude and a Codex architecture consult (session
`01a1b350-4917-7212-b1de-be74364b41f4`, model `gpt-6-astra`; transcripts in
`.context/codex-arch-consult-{1,2}.md`)
**Builds on:** `2026-09-04-save-open-project-design.md` (the `.pie` package and
DocumentGroup) and `2026-09-28-prepare-for-mastering-design.md`. That spec deferred
direct upload to Playola, and this one keeps the deferral.

---

## Why

Today an editor gets raw interview tapes by hand. They download each file, drag it in,
wait for transcription, and pick a save location. Playola now assigns stations to an
Editor, and each station's source tapes reach that editor through jobs. The app should
already know what the editor has to work on and have it transcribed and waiting.
Opening a tape should be one click, with no save dialog and no waiting.

Success looks like this: an editor signs in once. From then on, every tape assigned to
them appears in an Assignments window, downloads and transcribes in the background,
and opens ready to edit.

## Decisions that need your call

Each question has my recommendation. Approving the spec as written accepts these
recommendations.

| # | Question | Recommendation | Why |
|---|---|---|---|
| Q1 | Does Assignments replace the untitled window at launch when signed in? | **Yes.** If this environment had a saved sign-in at last quit, launch shows Assignments and no untitled document. Signed-out launches are unchanged. File ▸ New, Finder opens and window restoration keep working. | Your lean. It is also the editor's real starting point. A blank untitled window is noise for an editor who works only from assignments. |
| Q2 | Where is the library root? Is the app sandboxed? | **`~/Music/Playola Interview Editor/`.** The app is **not sandboxed** (Developer ID; `packaging/app.entitlements` is empty), so no entitlement is needed. | Logic's own default project location is `~/Music/Logic`, so editors already look there. `~/Documents` is often synced by iCloud's "Desktop & Documents" option, which would upload multi-GB WAVs. |
| Q3 | Schema for the Playola link: refuse older readers, or additive-safe? | **Refuse older readers.** Linked projects are written as `schemaVersion: 4`. | Additive is **not** safe. Older apps rebuild `project.json` from their own struct on autosave (`ProjectPackage.rewriteMetadata`), which silently **drops** an unknown `playola` key. A separate `playola.json` file in the package doesn't survive either, because a fresh-tree save (`ProjectPackage.encode`) rebuilds the children. See §6. |
| Q4 | Keep or delete originals after preparation? | **Delete the original once the `.pie` is published and verified.** This drops "Free up space" entirely. | Nothing reads the original after import: `ProjectSource.originalPath` is written but never read, and re-transcription uses the canonical AIFF bundled in the `.pie`. Keeping originals until the job is completed costs GBs per tape plus a whole cleanup feature, and buys nothing the package doesn't already have. The cost: a removed or missing project has to be downloaded again. *Your lean was to keep originals until completion. If you prefer that, §5 has the delta.* |
| Q5 | Should a server-side tape rename rename the local `.pie`? | **No.** Identity is the Playola id. The list shows the current server name, and the file keeps its creation-time name. | Your lean. Renaming a file that may be open, or in Logic's recent list, is risky and gains nothing. |
| Q6 | A per-editor limit on background transcriptions beyond the queue's? | **Yes: one background preparation at a time.** The shared queue allows 2, so a manual import always has a slot free unless the editor is already running one manually. Opening a tape moves it to the front of the waiting line and never cancels running work. | Long tapes are expensive. One at a time keeps the Mac usable and leaves room for manual work. |
| Q7 | Keyboard shortcut for Window ▸ Assignments | **⇧⌘A**, pending a check against Logic's default key commands before implementation. `Window("Assignments", id:)` already puts the item in the Window menu. | ⌘0 is taken: this app already uses it for transcript zoom reset (`TranscriptPageView.swift`). |
| Q8 | Server contract gaps (to pass to the server session) | Ask the server to add: **`assignedAt` on Job**; the **`GET /v1/jobs?assignedTo=me` list** (all assigned jobs, completed included); and, on each source tape, **`fileSizeBytes`** plus the original **file extension or content type**. | The row's "assigned date" can't come from `createdAt`/`updatedAt`. Size lets the app check disk space before downloading. The extension names the original correctly. See `endpoints.md`. |
| Q9 | The brief says to mirror the iOS `APIClient`, which takes the JWT as a parameter on every call. Do we keep that shape? | **No. The session supplies the token inside the live client.** Page models never see the JWT. Every request takes the environment, token and generation from one snapshot, so the base URL and header can't disagree, and a 401 signs out only the session that sent it. | With three environments and a 401 → sign-out rule, passing the token per call means each caller must also pass the matching environment and handle 401 itself. This is the only place the design deliberately departs from the iOS pattern. Everything else (`@DependencyClient` shape, the `PlayolaAlert` struct, the SignInPage model's cancel/error handling) mirrors it. |
| Q10 | PR shape and merging before the server is ready | **5 PRs** (§11). The first (preparation extraction) merges now. Sign-in merges once desktop auth is deployed. The assignments PRs merge once the list endpoint and download URLs are deployed. Until then they stay draft. **No feature flags or hidden UI.** | You don't want dead UI. A flag would only hide unfinished integration. |

## Goals

1. One-time Playola sign-in (Google or Apple), remembered across launches and Sparkle
   updates, and kept separately per server environment.
2. An Assignments window listing every station, job and tape assigned to the editor,
   with each tape's local state.
3. New assignments download one at a time and transcribe in the background, with no
   untitled window and no save prompt.
4. A managed library: one predictable folder, one `.pie` per tape, linked by Playola id.
5. One-click switching between tapes from the list.

## Non-goals

- Uploading edited or mastered results to Playola (the server's Submission model
  doesn't exist yet). The link (§6) carries the ids that a future upload needs.
- Writing tape status back to the server, push notifications, and multi-user or
  shared-Mac support.
- Token refresh. Playola JWTs don't expire.
- Resuming a partial download. A partial download is always **restarted from scratch**
  with a fresh URL (§3). Range resume can be added later if real tapes need it.
- Running AI cut suggestions in the background. Suggestions still start on first
  open, exactly as for a manual import, so background work never spends Anthropic
  credits.
- Moving the library across volumes in v1 is limited to the flow in §5. iCloud
  conflict handling is not attempted.

## Anti-goals (failure even if the feature "works")

- Any local project is deleted, overwritten or duplicated without an explicit,
  confirmed user action. Existing edits always win.
- A staging token is sent to production, or the Playola JWT is sent to S3.
- Signed-out users lose anything: drag/drop import, File ▸ Open, untitled documents,
  mastering, export, suggestions, autosave and the Save-menu surgery all behave
  exactly as today.
- A network error or a failed refresh marks tapes "No longer assigned". Only a
  successful, complete list response can do that.
- A partial download is ever treated as complete.

## Constraints (verified)

- macOS 15 target, Swift 6 strict concurrency, CI on Xcode 16.4. Developer ID, not
  sandboxed. Hardened runtime is applied at signing. Bundle id
  `fm.playola.PlayolaInterviewEditor`, team `FSRSPV9N9Q`, Sparkle 2.9.6.
- The only scenes today are `DocumentGroup` and `Settings`. `NSDocumentController` is
  not used anywhere.
- `AppLaunchModel` (the model-setup gate, the updater start, and the
  move-to-Applications offer) is used only inside `ProjectHostView`. Its launch work
  runs only when a document window appears.
- `TranscriptionQueue` is app-wide with `maxConcurrent: 2`. A slot is held for the
  life of the engine stream, and cancelling the consumer stops the engine process.
- `ProjectPackage` is built on `FileWrapper` and has no URL-based or atomic writer.
  `.pie` files are written only through NSDocument today.
- `InstallLocation` relaunches with `createsNewApplicationInstance = true`, so **two
  instances briefly overlap**. Library writes need a cross-process lock (§5).
- `PlayolaAlert` is not in this app yet. CLAUDE.md describes it, and the iOS app has
  it.
- Server, checked on `playola` `origin/develop` @ `fd456a5`:
  - `GET /v1/users/me` exists and returns the bare user.
  - `GET /v1/stations/:stationId/jobs/:jobId` exists, for an admin or the assignee
    only. Anyone else gets 403, and a foreign station gets 404.
  - A source tape belongs to **at most one job**, enforced by a unique constraint.
  - The Android Apple PKCE flow uses 60-second handoff codes.
  - Desktop auth, the job list, and tape `downloadUrl`/`previewUrl` are not on develop
    yet.

---

## Architecture overview

```
QuickInterviewEditorApp
 ├─ DocumentGroup(ProjectDocument)          — unchanged; opens .pie (manual or managed)
 ├─ Window("Assignments", id: "assignments") — AssignmentsPageView / SignInPageView
 ├─ Settings — new "Account" and "Library" tabs
 └─ @State AssignmentsCoordinator  (app-scoped @Observable; outlives the window)
       ├─ PlayolaSessionClient      (actor: env, token, generation; Keychain-backed)
       ├─ PlayolaAPIClient          (URLSession; every path + DTO lives here)
       ├─ PlayolaBrowserAuthClient  (ASWebAuthenticationSession + PKCE)
       ├─ TapeDownloadClient        (S3 streaming download → staging, no auth header)
       ├─ ProjectPreparationClient  (shared with ProjectModel's manual import)
       ├─ InterviewLibraryClient    (actor + flock: scan, publish, remove, manifest)
       └─ ProjectOpeningClient      (NSDocumentController wrapper)
```

**Ownership.** `AssignmentsCoordinator` is an `@MainActor @Observable` class held by
the App struct, the same way `AppLaunchModel` is. It owns:

- the refresh logic, the observable tape records, one download worker, one managed
  preparation worker, and their task handles.

Closing the Assignments window stops only the refresh timer, so work in progress
continues. `AssignmentsPageModel(coordinator:)` derives every row's display values from
the coordinator's state and owns presentation-only state such as `showsCompletedJobs`.
It does not keep a second copy of the records. The coordinator is a plain `ViewModel`
with injected dependencies, so it is tested the same way as page models.

**Everything is a dependency client** with `liveValue` and `testValue`. Tests never
touch the network, the Keychain, the engine or the real library.

---

## 1. Sign-in and session

**Flow.** Desktop OAuth with PKCE. This contract is provisional and lives in
`endpoints.md`.

1. The app generates `state` and a `code_verifier` with `SecRandomCopyBytes` (32
   bytes, base64url-encoded), and derives an S256 `code_challenge`. Both live only for
   the current attempt.
2. The app opens `{baseURL}/v1/auth/desktop/authorize?provider=google|apple&state&code_challenge&code_challenge_method=S256`
   in an `ASWebAuthenticationSession` with callback scheme `playola-interview-editor`.
   Its presentation anchor is the Assignments window.
   **`CFBundleURLTypes` is not needed:** the session catches its own callback, and the
   app doesn't support external deep links.
3. The app validates the callback, rejecting anything other than exactly one `code`
   and one matching `state`:
   - scheme `playola-interview-editor`
   - host `auth`
   - path `/callback`
4. It calls `POST /v1/auth/desktop/token {code, codeVerifier}`, which returns
   `{playolaToken}`.
5. It stores the token in the Keychain and calls `GET /v1/users/me` to fill in the
   account.

**Cancel versus error.**
- Canceling the browser sheet (`ASWebAuthenticationSessionError.canceledLogin`) shows
  nothing.
- A state mismatch, failed exchange or network error shows a `PlayolaAlert` with a
  copyable, redacted detail.
- Only one sign-in attempt can run at a time.

**Token storage.**
- The token goes in a new Keychain item: service
  **`fm.playola.PlayolaInterviewEditor.playolaToken`** (a stable literal, covered by
  the same invariant as the Anthropic key and pinned by a test). The account name is
  the environment raw value: `production`, `staging` or `local`.
- `KeychainClient` (the Anthropic key) is **unchanged**. The new
  `PlayolaTokenStore { load(env), save(env, token), delete(env) }` is a separate
  client. Its test value is an in-memory dictionary keyed by environment.
- Keychain reads happen off the main thread. Only `errSecItemNotFound` means "signed
  out". Any other read error is reported as "account unavailable", and the token is
  **never deleted** on a read error.

**Session and 401.**
- `PlayolaSessionClient` wraps an actor that holds `(environment, token, generation)`.
  The generation increases on sign-in, sign-out and environment switch.
- Every authenticated request captures a single `(env, token, generation)` tuple and
  builds both the URL and the `Authorization` header from it.
- A 401 from Playola calls `signOutIfCurrent(generation)`. This deletes the token and
  clears the account only if the generation still matches, so a late 401 from an old
  session can't sign out a new one.
- After a sign-out, the coordinator cancels assignment work and the window shows the
  sign-in page. Local projects and the library are never touched. While signed out,
  the window shows **only** the sign-in page and no local-only list. Linked projects
  still open from Finder, File ▸ Open and File ▸ Open Recent.
- An S3 401 or 403 is a **download failure**, not a sign-out.

**User.** `@Shared(.playolaAccount)` is an **in-memory** key holding
`PlayolaAccount { environment, user: PlayolaUser? }`, written only by the coordinator.
The user is decoded from `GET /v1/users/me`, chosen over the JWT payload because it is
the server's source of truth and gives the right shape. `extendedPlaylist` and other
unknown fields are ignored. The account isn't persisted: the token is, and `/me`
refills the account at launch.

**Environments.**
- `PlayolaEnvironment` is `production`, `staging` or `local`:
  - production: `https://admin-api.playola.fm`
  - staging: `https://admin-api-staging.playola.fm`
  - local: `http://localhost:10020`
- These URLs match `playola-radio-ios` `Config.swift`.
- The active environment is an `appStorage` value. A Release build always uses
  production, and the picker exists only in DEBUG builds.
- Switching environments bumps the generation, cancels work, and loads that
  environment's token. Tokens never cross environments: a request can only be built
  for the active environment.

**Sign-out** lives in Settings ▸ Account and in the Assignments window's account
menu. It deletes the token for the active environment and clears the account. It never
deletes the library.

**UI.**
- **SignInPage** (Model/View/Tests trio) is shown inside the Assignments window when
  signed out. It has "Sign in with Google" (primary, since staff mostly use Google)
  and "Sign in with Apple" buttons.
- **Settings ▸ Account** shows the signed-in user and Sign Out. When signed out it
  shows a "Sign In…" button that opens the Assignments window, so there is a single
  OAuth path. In DEBUG it also shows the environment picker.

## 2. Assignments window and launch

**Scene.** `Window("Assignments", id: "assignments")` with shortcut ⇧⌘A (Q7), in
addition to the existing `DocumentGroup`.

**Launch (Q1).**
- An `appStorage` hint, `launchesToAssignments`, is set on successful sign-in and
  cleared on sign-out or a 401.
- At launch the hint picks the scenes, using `.defaultLaunchBehavior(.presented)` on
  the Assignments window and `applicationShouldOpenUntitledFile → false`:
  - Hint set: Assignments is presented and no untitled document opens.
  - Hint not set: today's untitled-document launch, unchanged.
- The real session is restored **asynchronously** from the Keychain. If no token is
  found, the window shows SignInPage and clears the hint.
- **Dock click with no windows open**
  (`applicationShouldHandleReopen(_:hasVisibleWindows: false)`):
  - Hint set: shows Assignments.
  - Hint not set: today's untitled document.
- File ▸ New, Finder opens and window restoration are unaffected. This combination
  must be verified on macOS 15 with CI's SDK, and is listed as a manual QA item.

**Launch tasks move out of `ProjectHostView`.**
- `AppLaunchModel.viewAppeared()` becomes an idempotent `start()` called from the
  application lifecycle (`applicationDidFinishLaunching` via the delegate adaptor). It
  keeps the existing order: the move-to-Applications offer before the updater starts.
- This is needed because a launch straight to Assignments shows no document window.
- The model-setup gate stays in document windows. The Assignments window shows the
  same `ModelSetupView` (sharing `launch.modelSetup`) when preparation is requested
  and models aren't installed yet.
- Sign-in, listing and downloading all work before models are installed. Only
  preparation waits.

**Contents (see `screens.md`).**
- Tapes are grouped by station, then by job.
- Each tape row shows:
  - the current server name
  - the duration (`durationMS`)
  - "Assigned <date>" (from `assignedAt`, Q8; omitted until the server sends it)
  - a state label with progress
  - its actions
- Completed jobs (`completedAt != nil`) are hidden by default, with a "Show completed
  jobs" toggle. "No longer assigned" tapes appear in their own "No longer assigned"
  section.
- Every string and every show/hide decision comes from the page model.

**Refresh triggers:**
- Launch, once a session is restored.
- The Assignments window appearing.
- The app becoming active (`NSApplication.didBecomeActiveNotification`).
- The Refresh button.
- A 5-minute timer while the window is open, using `@Dependency(\.continuousClock)`.

**Refresh rules:**
- Triggers are coalesced, so only one refresh runs at a time.
- A result from an older session generation or an older refresh is discarded.
- **Only a successful, complete response marks anything "No longer assigned".** If
  the list endpoint ever paginates, every page must be fetched first.

**Merging a refresh into local state.** Identity is `TapeKey(environment, sourceTapeId)`.

- **New tape:** added. It is queued for auto-download only when all of these hold:
  - auto-download is on
  - the tape isn't suppressed (§5)
  - its job isn't completed
  - its `status` isn't `rejected`

  On first sign-in this queues every eligible tape in the editor's open jobs. The
  point is to have them ready.
- **Queue order:** jobs oldest-assigned first (`assignedAt`, falling back to
  `createdAt`), then tapes in the order the server lists them. Open moves a tape to the
  front.
- **Failed or offline refresh, or a 401:** a failed refresh keeps the last list with an
  inline "Couldn't refresh" banner. A 401 replaces the list with the sign-in page.
- **Tape gone from every assigned job** (the job was deleted, reassigned, or the tape
  moved to another editor's job):
  - It shows as **"No longer assigned"** if a local project or original exists.
  - Otherwise it is dropped.
  - Pending work for it is cancelled. A running preparation finishes.
  - Nothing is ever deleted.
- **Job completed:** its tapes move under "Completed" (hidden by default). Downloads
  for completed jobs are not started automatically.
- **Renamed tape or station:** the list shows the new name and the file keeps its name
  (Q5).

**Opening a tape (row double-click or "Open"):**
- **Ready** (a linked `.pie` is in the library): `ProjectOpeningClient.open(url)` calls
  `NSDocumentController.shared.openDocument(withContentsOf:display:true)`, which brings
  an already-open window to the front. This works signed out and offline.
- **Not ready:** the tape is marked `openWhenReady` and moved to the **front of the
  pending queues**. Download and preparation start if idle. Running work for other
  tapes is never cancelled (Q6). When the project is published, it opens. A repeated
  Open has no extra effect.
- Opening overrides both automatic-work toggles (§8) and needs models installed (the
  model-setup view is shown if not).

**Remove from this Mac.**
- Asks for confirmation through a `PlayolaAlert`. The message names the project file
  and warns that its edits will be moved to the Trash.
- If the project's document is open, the editor must close it first.
- The removal:
  - cancels and awaits that tape's work
  - moves the `.pie` and any original to the **Trash**, not a permanent delete
  - adds the tape to the manifest's `suppressedTapes`, so auto-download doesn't
    immediately bring it back
- An explicit **Download** on a suppressed tape un-suppresses it.

## 3. Download

**`TapeDownloadClient.download(DownloadRequest) -> AsyncThrowingStream<DownloadEvent, Error>`**
- The request carries a fresh `URL` and a staging destination.
- Events: `.progress(received, expected)` and `.finished(fileURL, byteCount)`.
- The live implementation is a URLSession download using **its own session with no
  Authorization header and no shared cookies**.
- It reuses the delegate and progress patterns from `LiveModelDownloader`, but not its
  `resumeData` logic: resume data embeds the old presigned URL, which expires in about
  5 minutes.

**Rules:**
1. Before **every** attempt, including retries and post-crash restarts, re-fetch
   `GET /v1/stations/:stationId/jobs/:jobId`. Then confirm that the job is still
   assigned to this user, the tape is still on it, and the job isn't completed (except
   for an explicit Open). Take `downloadUrl` from that response. **The URL is never
   persisted or logged.**
2. Download into `<root>/.staging/<attempt-uuid>/`. Accept only a 200 with a body.
   Before writing much, check free space on the library volume against
   `Content-Length` × 3, which covers the original, the canonical AIFF in Caches, and
   the package. Fail with "Not enough disk space" (retryable) if it's short.
3. When finished, verify the bytes on disk equal `Content-Length`. A missing
   `Content-Length` is a failure, not a pass. Then move the file atomically to
   `<root>/[env/].originals/<sourceTapeId>.<ext>`. The extension comes from the tape's
   file extension or content type (Q8), falling back to the response's `Content-Type`
   (`audio/wav` → `wav`, `audio/mp4`/`audio/x-m4a` → `m4a`).
4. **Only files in `.originals/` count as downloaded.** At launch, after taking the
   library lock, everything in `.staging/` is deleted. A crash or quit mid-download
   therefore always restarts from scratch, and a partial file is never mistaken for
   complete.
5. Downloads run **one at a time** across all tapes.
   - Before each **automatic** download, the worker checks free space on the library
     volume. If the download would leave less than **20 GB** free, automatic
     downloading pauses with a row and banner message ("Paused — low disk space").
   - It resumes on the next refresh once space is available.
   - An explicit Download or Open skips the 20 GB floor. It still has to pass the 3×
     size check.
6. A network error, a non-2xx response, a short read or a full disk ends in
   `failed(retryable: true)` with a copyable detail (§9). Cancellation is not a
   failure.
7. While any worker is active, a `ProcessInfo.beginActivity(.userInitiated)` token is
   held to keep App Nap from throttling the work. It is released when idle.

## 4. Background preparation (shared with manual import)

**The problem.** A DocumentGroup untitled document has no `fileURL` until it is saved.
Assigned tapes therefore **never** go through untitled documents. The package is built
headlessly and then opened by URL.

**Extraction.** This is a chore PR that ships first and is used by today's import. The
non-UI half of `ProjectModel.transcribe` / `loadCompletedTranscription` moves into
`ProjectPreparationClient`:

```swift
struct PreparationRequest: Sendable {
  var input: TranscriptionInput            // existing: .importedSource(URL) / .bundledCanonical(...)
  var policy: CachePolicy
  var seed: EditorDocumentState            // legacy-sidecar seed for manual imports; empty for managed
  var link: PlayolaProjectLink?            // nil for manual imports
  var sourceDisplayName: String?           // managed: "<tape name>.<ext>"; nil = the input file's name
}
struct PreparedProject: Sendable {
  var file: ProjectFile                    // complete, schema per §6
  var plan: EditPlan
  var canonicalAudioURL: URL               // session file; caller owns cleanup on failure
}
enum PreparationEvent: Sendable { case progress(EngineProgress), completed(PreparedProject) }

struct ProjectPreparationClient: Sendable {
  var prepare: @Sendable (PreparationRequest) -> AsyncThrowingStream<PreparationEvent, Error>
}
```

**What moves and what stays.**

| Moves into the preparation client | Stays in `ProjectModel` |
|---|---|
| Source fingerprinting | The phase machine, progress and ETA text |
| Building the `TranscriptionJob` and consuming the shared queue | Building the editor and tearing it down |
| Canonical size and hash checks | Sink commits, dirtiness and undo |
| `makeProjectSource` (taking `sourceDisplayName` into account) | Legacy-sidecar seed lookup (it passes the result in as `seed`) |
| Assembling the initial `ProjectFile` | Suggestion recovery and auto-suggest |
| | Mastering hydration |

**Source naming for managed projects.**
- The original is stored as `<sourceTapeId>.<ext>`. Today
  `ProjectSource.originalFileName` drives the default document name, the editor's
  `sourceURL`, and therefore the **export filename stems**.
- Managed preparation therefore passes `sourceDisplayName` = the tape's server name
  plus its extension (for example `Interview with Jane Doe.wav`), so exports read like
  a manual import of a file with that name. The name is frozen at creation, like
  `tapeName`.
- `originalPath` is nil for managed projects, because the original is transient.
- Manual imports pass nil and are unchanged.

**Shared normalization.** The `EditorDocumentState` normalization that `EditorModel`
applies at construction becomes a shared `EditorDocumentState.normalized(for: EditPlan)`.
Both paths call it, so a headless project is byte-identical in shape to one made by
manual import.

**Regression rule.** The extraction must leave manual import behavior identical. The
full existing Project, Editor and transcription-queue suites must pass unchanged.

**Publishing** (`InterviewLibraryClient.publish`) runs inside the library lock:
1. Check identity again: if a linked package for this `TapeKey` already exists,
   discard the new draft and open the existing one. Existing edits always win.
2. Build the `FileWrapper` with `ProjectPackage.encode(file:plan:audio:)`. Write it to
   a sibling temporary `.<uuid>.pie.partial` directory on the destination volume. Then
   check it with `ProjectPackage.decode` and `verifyAudio`.
3. Pick a collision-free name (§5) and do a coordinated (`NSFileCoordinator`)
   **no-overwrite** move to the final `.pie`. Never use `replaceItemAt`.
4. Delete the original (Q4) and the session canonical copy, then add the tape to the
   manifest's `knownProjects`.

**Failure.** If the transcription fails or is cancelled, the original stays (when kept)
and the tape becomes `failed` or `idle`. Retrying goes through the transcription cache,
so a run that completed but failed to publish doesn't transcribe again. Leftover
`.partial` directories are swept at launch, after the lock is taken.

**Gating.**
- Managed preparation waits for models to be installed.
- At most **one** managed preparation is in flight (Q6). Once it is handed to the
  shared queue, it is never cancelled to make room for another tape.
- Cut suggestions are **not** run headlessly. `suggestionBatch` stays nil, so the
  existing auto-suggest-on-first-open runs when the editor opens the tape, just as
  for a manual import.

## 5. Managed library

**Layout** (root default `~/Music/Playola Interview Editor/`, Q2):

```
<root>/
  <Station name> (<stationId first 8>)/
    <Tape name>.pie
  Staging/<Station…>/<Tape>.pie          # non-production environments only
  Local/<Station…>/<Tape>.pie
  .originals/[staging/|local/]<sourceTapeId>.<wav|m4a>   # transient (Q4)
  .staging/<attempt-uuid>/                # in-flight downloads; wiped at launch
  .library.json                           # manifest (below)
  .lock                                   # flock target; never deleted
```

Production sits directly under the root, since editors only ever see production.
Folder names never decide identity or which credentials to use. The Playola link in
`project.json` does.

**Naming.**
- Station folder: `<sanitized station name> (<first 8 of stationId>)`.
- Tape: `<sanitized tape name>.pie`.
- Sanitizing reuses `ExportNaming`'s rules, moved into a shared `sanitizedFileStem`:
  - replace `/ \ :` and NUL
  - collapse whitespace
  - strip leading dots
  - NFC
  - fit the 255-byte UTF-8 budget, with room reserved for the collision suffix and
    `.pie`
- Collisions use the existing `nextExportCollisionSuffix` (`Name 2.pie`, …).
- Names are fixed when the package is created and never renamed later (Q5).

**Source of truth.**
- Linked packages are scanned: only each `.pie`'s `project.json` is read, never the
  audio. They are authoritative for which tape a project belongs to and where it is.
- The tape → path lookup is built **in memory** on each scan and never persisted.
  Scanning N small JSON files is cheap.
- Two packages linked to the same `TapeKey` are shown as a **conflict** on the row
  ("2 projects for this tape — Show in Finder"). Neither is overwritten.

**Manifest (`.library.json`).** It holds only what a scan can't recover: the tapes the
editor removed, and the tapes whose projects were published here. The fields are in
`models.md`.

**Recovery and reconciliation.**
- The manifest stores no cached server data and no paths. This deliberately narrows
  the brief's `library.json`: a path index and a server-metadata cache would be
  derived state that could disagree with the packages.
- Neither of its two sets can be rebuilt from packages. So a **corrupt** manifest is
  moved aside, and **automatic** work pauses with a banner ("Library settings couldn't
  be read; automatic downloads are paused"). Explicit actions still work.
- A **missing** manifest (a new or repointed root) starts empty.
- On every scan, a package wins over the manifest. A found package is added to
  `knownProjects`.

**Missing projects.**
- A tape in `knownProjects` that a **successful, complete** scan doesn't find shows
  **"Project missing"**. Usually the editor has moved or deleted it in Finder.
- Its actions are "Show Library in Finder" and a confirmed "Create New Project", which
  downloads and prepares again.
- Automatic work never re-creates it on its own.
- An unmounted root or a failed scan is a library error, not evidence that projects
  disappeared.
- There are no bookmarks or "Locate…" in v1.

**Cross-process lock.**
- `flock(LOCK_EX | LOCK_NB)` on `<root>/.lock`, held for as long as this process does
  managed-library work.
- If the lock is held elsewhere, library writes pause and retry (the
  move-to-Applications overlap).
- A crash releases the lock automatically. Manual documents are never affected.

**Settings ▸ Library: change the root.**
- **Choose existing folder…**: points at another library. It scans without merging or
  deleting anything.
- **Move library…**:
  - Requires all managed documents to be closed, and pauses the workers.
  - Moves with `FileManager.moveItem` on the same volume. Across volumes it copies,
    verifies, and then removes the old root.
  - The saved root changes only after success. On failure the old root stays the
    library.
- This is the last PR (§11).

**If you choose "keep originals until the job is completed" for Q4 instead:**
- Originals stay in `.originals/` after publishing.
- A per-job "Free up space" action appears when `completedAt != nil`. It deletes
  originals only after confirming that a valid linked package exists.
- Add one row state ("Original kept") and one PR item.

## 6. Project link and schema

**Shape.** A new optional `ProjectFile.playola: PlayolaProjectLink?`. The fields are in
`models.md`. Beyond the brief's four ids, it adds two names:

- `stationName` and `tapeName` are a **snapshot taken at creation, never updated**.
  They exist so a linked project opened from Finder, offline, can show its station and
  tape. Ids are always authoritative.
- `jobId` is historical provenance. A future upload must recheck the tape's current job
  and not trust it.
- This shape carries everything a future upload needs (environment, tape, station),
  with no schema break.

**Schema (Q3).** Linked projects are written as **schema 4**. Unlinked projects keep
today's versions (2, or 3 with mastering). That way, manual projects stay openable by
older apps.

- Replace the overloaded constants with explicit ones:
  - `baseSchemaVersion = 2`
  - `masteringSchemaVersion = 3`
  - `linkedSchemaVersion = 4`
  - `maximumReadableSchemaVersion = 4`
- `writtenSchemaVersion(for:)` returns 4 if `playola != nil`, else 3 if
  `masteringRun != nil`, else 2.
- **Fix a hidden assumption.** `ProjectPackage.decode` treats "schema ≥ 3 with no
  `masteringRun`" as a corrupt mastering manifest. A healthy schema-4 project without
  mastering would hit that path. Mastering-manifest corruption must be tracked
  explicitly, keeping the legacy rule only for exactly schema 3.
- **The same fix applies to the encoder.** The corrupt-manifest preservation path in
  `encode` and `rewriteMetadata` currently writes `maximumReadableSchemaVersion`. It
  must write `max(masteringSchemaVersion, writtenSchemaVersion(for:))`.
- The link is preserved through autosave, fresh-tree save, and re-transcription
  (⇧⌘R), because the same source keeps its link. Importing different audio into a
  window is not allowed for a linked project: the import UI only appears for empty or
  failed documents, so this can't happen today. A test pins that.

**Why older apps must refuse.** Shipped 2.6.x and earlier accept schema 1…3:

- **An unknown `playola` key:** the old app opens the project, then rewrites
  `project.json` from its own struct on autosave and **drops the link silently**.
- **A separate `playola.json` in the package:** it survives `rewriteMetadata` but is
  dropped by a fresh-tree `encode`.

Schema 4 makes those apps show their existing "saved by a newer version" alert instead.

**Tests in both directions:**
- The new reader opens schemas 1, 2, 3 and 4.
- A linked project writes `schemaVersion: 4`. That value is the only one an old reader
  checks, and it is outside 2.6.x's accepted 1…3, which a fixture-backed test pins.
- An unlinked project still writes 2 or 3.
- A schema-4 project without mastering decodes as healthy.
- Corrupt-mastering preservation still works for schemas 3 and 4.
- The link round-trips through `encode`, `rewriteMetadata`, and re-transcription.

**Finder-opened linked project.** `ProjectModel` exposes
`playolaSubtitle: String?` (for example "KXYZ Morning — Interview with Jane"), and the
editor shows it as a small header line. This works signed out. The subtitle is the
model's only Playola-related behavior.

## 7. Tape state model

Storage facts, the active operation, and the assignment relationship are kept
separate, then mapped to the row labels in the brief:

```swift
enum LocalAvailability: Equatable { case none, original(URL), project(URL), missingProject, conflict([URL]) }
enum TapeOperation: Equatable {
  case idle, queued, downloading(fraction: Double?), waitingForModels,
       preparing(EngineProgress?), failed(TapeFailure)   // TapeFailure: message, detail, retryable
}
// assignment: .assigned(job) | .noLongerAssigned   (independent badge)
```

| Row label | When it shows |
|---|---|
| Not downloaded | `.none` + `.idle` (also suppressed tapes) |
| Waiting… | `.queued` |
| Downloading 42% | `.downloading` |
| Downloaded — waiting to transcribe | `.original` + `.idle`/`.queued`, or `.waitingForModels` |
| Preparing 63% | `.preparing` |
| Ready | `.project` |
| Failed: … (Retry) | `.failed` |
| Project missing | `.missingProject` |
| No longer assigned | badge on any of the above |

**What persists and what is derived:**
- Persisted: files (the `.pie` and originals), the link, the manifest, and settings.
- Derived on every scan and refresh: availability.
- In memory only: operations. Percentages and "downloading" are never persisted.

**After a crash or quit:**
- Mid-download: `.staging` is wiped, so the next attempt is a fresh download.
- Mid-transcription: the original survives and preparation re-runs, through the cache
  where possible.
- Mid-publish: only completed `.pie` files count, and `.partial` directories are swept.

## 8. Settings

These are new `appStorage` keys under `State/PlayolaKeys.swift`.

| Key | Default | Where |
|---|---|---|
| `autoDownloadAssignments` | `true` | Settings ▸ Library: "Automatically download new assignments" |
| `autoPrepareAssignments` | `true` | Settings ▸ Library: "Automatically transcribe downloaded assignments". When off, preparation starts when the editor opens the tape. |
| `libraryRootPath` | `~/Music/Playola Interview Editor` | Settings ▸ Library (root display + Show in Finder; Move/Choose in PR 5) |
| `playolaEnvironment` | `production` | Settings ▸ Account picker, DEBUG builds only. Release builds ignore it. |
| `launchesToAssignments` | `false` | Not shown; a launch routing hint (§2) |

Each new Settings tab gets its own model trio, matching the existing tabs.

## 9. Errors and diagnostics

- **Alerts.** Introduce `PlayolaAlert`, mirroring the iOS struct: title, message,
  buttons and actions, presented with `.playolaAlert($model.presentedAlert)`. It is
  used for sign-in failures and Remove confirmation. Existing inline error surfaces
  are unchanged.
- **Row failures** show a one-line message plus a **Copy Details** button
  (`WorkspaceClient.copyToClipboard`), following the 2.6.0 diagnostics convention:
  - The detail names the step (refresh job, download, verify, transcribe, publish),
    the HTTP status or `URLError` code, and the byte counts.
  - **Redaction:** JWTs, handoff codes, PKCE values and presigned query strings are
    never logged or copied (URLs are reduced to host and path).
- **Logging.** A new `AppLog.playola` category records metadata only.

## 10. Testing

All tests use Swift Testing with `expectNoDifference`, `withDependencies`, local
`@Shared` declarations, and `TestClock`/`ImmediateClock`. There is no `Task.sleep`, and
no network, Keychain, engine or real library.

- **API decoding:** fixture JSON for the job detail (as in the brief), the job list,
  `/me`, and the token response. Cover unknown extra fields, every nullable field as
  `null`, unknown `status` and `role` strings, and fractional and non-fractional ISO
  dates. A missing required id fails.
- **SignInPageModel:**
  - success (token saved for the active environment, `/me` loaded, hint set)
  - cancel (no alert)
  - state mismatch
  - token-exchange failure
  - network-error alert
  - concurrent attempts collapse into one
- **Session:**
  - a 401 signs out and keeps the library
  - a stale-generation 401 is ignored
  - an environment switch never reuses another environment's token (a request for
    staging carries the staging token or fails)
  - a Keychain read error is not treated as signed out
- **AssignmentsCoordinator / AssignmentsPageModel:**
  - refresh merge: a new tape appears; a removed tape becomes "No longer assigned"
    when there are local files and is dropped otherwise
  - completed jobs are hidden until the toggle is on
  - a failed refresh changes nothing
  - download progress leads to ready, through preparation and publishing
  - a download failure is retryable
  - the job is re-fetched before every download, including after an expired-URL
    failure (the retry uses the new URL)
  - one-at-a-time download and preparation
  - Open on a ready tape opens it immediately; Open on an unready tape prepares it,
    then opens it, and jumps the pending queue without cancelling running work
  - Remove suppresses auto-download
  - rejected tapes and completed jobs are never auto-queued, and the queue is ordered
    oldest job first
  - automatic downloads pause below the free-space floor, and an explicit Download
    still runs
  - a failed refresh keeps the last list, while a 401 shows sign-in
  - a managed project's `originalFileName` is the tape name, so export stems aren't
    UUIDs
  - the refresh timer only runs while the window is open
- **Library:**
  - rebuild from packages with no manifest
  - a package wins over the manifest
  - rename-by-id stability: a server rename doesn't create a second project
  - collision-safe naming, including the byte budget
  - a mid-download crash (files left in `.staging`) is never treated as done
  - a leftover `.partial` is swept
  - a conflict is detected
  - "Project missing" only after a successful scan
  - a corrupt manifest pauses automatic work
  - lock contention pauses writes
  - filesystem tests run against temporary directories
- **Schema:** the full list in §6.
- **Preparation extraction:** the existing `ProjectModelTests` suites pass unchanged.
  New tests check that the headless output equals a manual import's `ProjectFile`
  apart from the link.
- **Manual QA:** these need a packaged build and can't be proven by mocks:
  - OAuth in a real browser sheet
  - launching to Assignments with File ▸ New still working
  - the Keychain item surviving a Sparkle update
  - a multi-GB download over Wi-Fi with sleep and wake
  - quitting mid-download and relaunching
  - opening an already-open project from the list

## 11. PR plan

Every PR follows CLAUDE.md, the pfw-* skills, `CHANGELOG.md ## [Unreleased]`, and
targets **`main`**: this repo has no `develop`, and Conductor's target is
`origin/main`.

| # | Title (draft) | Contents | Can merge when |
|---|---|---|---|
| 1 | `chore: share the transcribe-into-a-project step between imports and assignments` | `ProjectPreparationClient` extraction, `EditorDocumentState.normalized(for:)`, `ProjectModel` switched to it. No behavior change. | Now |
| 2 | `feature: sign in to Playola` | Environments, `PlayolaTokenStore`, `PlayolaSessionClient` + 401 rule, `PlayolaAPIClient` (auth + `/me` + all DTOs/fixtures), `PlayolaBrowserAuthClient`, `PlayolaAlert`, SignInPage trio, Settings ▸ Account, the Assignments window showing sign-in or "Signed in as …", and `AppLaunchModel.start()` moved to the app lifecycle. | Desktop auth endpoints are deployed to production |
| 3 | `feature: open assigned interviews from a local library` | Schema 4 + link + decode fix, `InterviewLibraryClient` (scan, manifest, lock, publish), `TapeDownloadClient`, `ProjectOpeningClient`, the coordinator with **manual** Download/Open, the list grouped by station and job, row states, model gate in the window, launch to Assignments, the Finder subtitle. | Job list + tape download URLs are deployed |
| 4 | `feature: download and prepare new assignments automatically` | The auto-download and auto-transcribe toggles, the refresh timer and activation refresh, queue priority, crash recovery sweeps, No-longer-assigned, Remove from this Mac (suppression), and Project missing. | After PR 3 |
| 5 | `feature: choose where assigned interviews are stored` | Settings ▸ Library: Move and Choose existing folder. | After PR 3 |

PRs 2–5 are built and reviewed against fixtures while the server work lands. They stay
**draft** until their endpoints are live. No feature flags.

## 12. Risks

- **Disk.** One multi-GB WAV needs roughly 3× its size during preparation (original,
  canonical cache and package). The pre-download space check covers this, and a full
  disk is its own retryable failure.
- **Sleep, quit and Sparkle relaunch mid-work.** These are handled by
  restart-from-scratch and the launch sweeps. The App Nap activity is held only while
  work runs.
- **Reassignment mid-edit.** The project stays fully editable and shows "No longer
  assigned". Presigned URLs may keep working for a few minutes after access is revoked,
  which is acceptable.
- **Launch routing.** Combining `defaultLaunchBehavior` with
  `applicationShouldOpenUntitledFile` must be checked with CI's Xcode 16.4 SDK on
  macOS 15. If it misbehaves, fall back to opening Assignments from the delegate after
  launch.
- **Server contract drift.** All paths and DTOs live in `PlayolaAPIClient` and its
  live implementation, so an interface change touches one place plus the fixtures.

## Calls I made (minor; flag any you disagree with)

- Built on URLSession, not Alamofire (the iOS app uses Alamofire). The API surface is
  a few GETs and one POST.
- The account (`@Shared(.playolaAccount)`) is in-memory and refilled from `/me`. Only
  the token persists.
- Sign-in UI lives in the Assignments window. Settings ▸ Account links there rather
  than running a second OAuth path.
- Partial downloads restart; they never resume.
- No background cut suggestions.
- Missing projects aren't re-created automatically. There are no bookmarks or
  "Locate…" in v1.
- Remove moves files to the Trash and never deletes them permanently.
- The Assignments window works without installed models. Only preparation waits for
  them.
- Signed out, the Assignments window shows only the sign-in page and no local-only
  list. Linked projects open from Finder and Open Recent.
- Auto-download skips `rejected` tapes and completed jobs. Otherwise, on first sign-in
  it downloads every tape in open jobs, oldest job first.
- Automatic downloads pause below 20 GB free space.
- A managed project's source name, which drives its export names, is the tape's server
  name. It is never the UUID file name.
- A Dock click with no windows open shows Assignments when signed in.

## Design deliverables

- Screens: pending — `screens.md` with pen.dev exports is blocked until a new `assignments.pen` canvas is open in pen.dev (see hand-off note)
- Endpoints: [endpoints.md](../../../design/features/playola-assignments/endpoints.md)
- Models: [models.md](../../../design/features/playola-assignments/models.md)
