# Playola Sign-in — Design (Step 1 of the Playola work)

Status: approved by Brian, 2026-11-07 (decisions D1–D3 below).
Supersedes: `2026-11-06-playola-assignments-design.md` (removed in the same commit).
That design put assignments in a separate window with its own look; it was rejected
because it didn't match the app. The direction also changed (see Roadmap).

## Why

Playola assigns interview tapes to editors on the server. Today the editor has to
download each tape by hand, import it, and keep track of files and folders. Brian is
removing file management from the app one step at a time, until the editor never
thinks about uploading or downloading.

Everything after this step (automatic downloads, the source-tape browser) needs to
know who the editor is. So step 1 is only this: **sign in to Playola, stay signed in,
and see who you're signed in as.**

## Goals

- An editor can sign in to Playola from the app through the browser (Google or Apple,
  via Playola's own sign-in page).
- The sign-in survives quitting, relaunching and Sparkle updates (Keychain).
- A fresh, empty window shows a Welcome screen while signed out, inviting sign-in.
- Settings ▸ Playola shows who is signed in and lets the editor sign out.
- Debug builds can switch between the production, staging and local servers, and each
  server keeps its own sign-in.

## Non-goals (later steps or never)

- Downloading, listing or opening Playola tapes (step 2 and step 3).
- Sending anything back to Playola (write-back is out of scope for now).
- Token refresh. A 401 means signed out.
- A profile picture, roles, or anything else from the user record beyond name and
  email.
- Changing the `.pie` file format.

## Anti-goals (failure even if it "works")

- **Anything that works today stops working.** Opening a `.pie` file (Finder, File ▸
  Open, Open Recent, double-click), importing a local audio file, Model Setup,
  exporting: all must behave exactly as now, signed in or not.
- A signed-out editor is blocked from their own projects.
- A Playola token is sent to the wrong server, or one server's sign-in is used for
  another.
- A Keychain hiccup silently deletes a valid sign-in.
- New look-and-feel. Every screen is built from the existing app's components (see
  `design/interview-editor.pen`, section 09).

## Decisions

| # | Question | Decision |
|---|---|---|
| D1 | Is sign-in **forced**? | **No (Brian, 2026-11-07).** Local editing never requires sign-in. Signing in is required only for the Playola download and, later, upload features. Welcome offers "Use a Local Audio File", which goes to today's import screen in that window. |
| D2 | One "Sign In with Playola…" button, or separate Google and Apple buttons? | **One button (Brian, 2026-11-07).** The authorize URL is sent without `provider`, and Playola's server shows its own "Continue with Google / Apple" page in the browser. This needs the server to accept a missing `provider` (see `endpoints.md`). If the server team says no, the fallback is two buttons on Welcome and in Settings, each sending `provider`; nothing else changes. |
| D3 | Does "Use a Local Audio File" stick? | **Per window only (Brian, 2026-11-07).** The next new window shows Welcome again while signed out. It nudges toward Playola, matching the direction. If it gets annoying before step 2 lands, a "don't show again" is a small follow-up. |

## Constraints (verified)

- macOS 15 target, Swift 6 strict concurrency, CI on Xcode 16.4. Developer ID, not
  sandboxed, hardened runtime. Bundle id `fm.playola.PlayolaInterviewEditor`, team
  `FSRSPV9N9Q`. These must not change (they keep the Keychain items across updates).
- The only scenes are `DocumentGroup` and `Settings`. Every window is a project
  window, so Welcome lives inside the project window, not in a new window.
- `ProjectHostView` already gates a window's content: Model Setup when
  `launch.showsModelSetup`, otherwise `ProjectView`. `ProjectModel.Phase.empty` means
  an untitled window with no audio yet (the drop target, map 02.1.2).
- `AppLaunchModel` is app-scoped, held by the App struct and passed to windows with
  `.environment`. The new session model follows the same pattern.
- `KeychainClient` stores the Anthropic key under its own service. It is not touched.
- Server, checked on `playola` `origin/develop` @ `fd456a5`: `GET /v1/users/me` exists.
  `/v1/auth/desktop/authorize` and `/v1/auth/desktop/token` **do not exist yet**. They
  are being built in a separate Playola server session. This app can be built and
  unit-tested without them; manual QA waits for them.

## How it works

### Sign-in flow (browser, PKCE)

1. The editor clicks **Sign In with Playola…** on Welcome or in Settings ▸ Playola.
2. The app makes a fresh `state` and `code_verifier` (32 random bytes each,
   base64url) and an S256 `code_challenge`. They live only for this attempt. The random
   bytes come from a dependency so tests are deterministic.
3. It opens `{baseURL}/v1/auth/desktop/authorize?state&code_challenge&code_challenge_method=S256`
   in an `ASWebAuthenticationSession` using the custom callback scheme
   `playola-interview-editor`. No `CFBundleURLTypes` entry is needed: the session
   catches its own callback. The session's presentation anchor is the app's key window
   at the moment of the click (a project window or Settings). The live client owns the
   session and its anchor provider, runs on the main actor, and finishes exactly once:
   with a callback URL, "canceled", or an error (including `start()` returning
   `false`). Check the isolation with Xcode 16.4, which CI uses.
4. The callback must be exactly `playola-interview-editor://auth/callback` with one
   `code` and one `state` equal to ours. Anything else is a failed sign-in. A callback
   with `error=` is a failed sign-in.
5. `POST /v1/auth/desktop/token {code, codeVerifier}` → `{playolaToken}`.
6. Save the token to the Keychain for the active environment. Status becomes
   **signed in**, then `GET /v1/users/me` fills in the name and email. If the save
   fails, it's a failed sign-in.

- **Cancel:** canceling in the browser, or Cancel on Welcome, returns to plain
  "signed out" with no error. Cancel ends the attempt even if the token exchange is
  already in flight: a late success is dropped, and nothing is saved.
- **Failure:** a bad callback, a failed exchange (including its 401), or a network
  error shows the "Couldn't sign in" state (map 09.3) on Welcome and in the Settings
  Status row. Details go to `AppLog`, never the token or the code.
- **One attempt at a time.** A second click while waiting does nothing new; every
  window's Welcome mirrors the single attempt.

### Staying signed in

- **Token storage:** Keychain generic password, service
  `fm.playola.PlayolaInterviewEditor.playolaToken` (stable literal, pinned by a test),
  account = environment raw value. See `models.md`.
- **At launch:** status starts as `restoring`. The token is read off the main thread.
  A token found → **signed in at once** (works offline), then `/me` fills in the name
  in the background. No token (`errSecItemNotFound`) → signed out. Any other Keychain
  error, including unreadable item data → logged, treated as signed out for this
  launch, and the item is **left alone**. (Signing in again overwrites it.)
- **Restore runs once per launch from the session model's init** in the App struct,
  not from a window appearing, so it also runs when only Settings is open.
- **While restoring** (milliseconds), an empty window shows only its background, so
  it never flashes Welcome at a signed-in editor.
- **The 401 rule:** when Playola answers 401 to the saved token, the app deletes that
  token and shows "You were signed out of Playola" (map 09.4). Any other error keeps
  the editor signed in, without a name, until the next launch or server switch. The
  401 from the token exchange is a failed sign-in, not this rule.
- **Generation guard:** a counter is bumped on every sign-in attempt start, cancel,
  sign-out and server switch. Every async step (restore, exchange, Keychain save,
  `/me`) captures the environment and generation when it starts and **checks them
  before it publishes anything or saves a token**. A late answer from an old attempt
  or an old server is dropped. Token saves and deletes run one at a time, in order.
- **Sign Out** (Settings ▸ Playola) deletes the active environment's token and sets
  status to signed out. It never touches projects or files. If the Keychain delete
  fails, the editor stays signed in (a relaunch would restore the token anyway) and
  the Status row says "Couldn't sign out. Try again."
- **Redirects:** authenticated calls don't follow redirects, so the token only ever
  goes to the environment's base URL.

### Environments

- `production`, `staging`, `local`, with the base URLs in `models.md` (matching
  `playola-radio-ios` `Config.swift`).
- The choice is the `playolaEnvironment` setting, shown as a picker in Settings ▸
  Playola **in debug builds only**. Release builds always use production.
- Switching bumps the generation, drops any in-flight attempt, and restores that
  environment's own token. Every API call takes the environment and token together,
  so a token can only ever go to its own server.
- **Local server:** `http://localhost:10020` needs App Transport Security's scoped
  `NSAllowsLocalNetworking` in the generated Info.plist (not arbitrary loads).

### Where Welcome shows

Welcome replaces a window's content only when **all** of these are true:

- the window's project is empty (`ProjectModel.Phase.empty`, today's drop target),
- the active environment's status is signed out,
- this window hasn't chosen **Use a Local Audio File**.

Welcome comes **before** Model Setup. Leaving Welcome, by signing in or by **Use a
Local Audio File**, goes through today's Model Setup gate (packaged builds with
missing models) and then to the drop target. An opened `.pie` starts `.queued`, never
`.empty`, so it never shows Welcome, signed in or not. The decision is one `Bool` on a
model; the host view only branches on it. Document hydration, undo wiring, focused
commands and the lifecycle modifiers stay on the host, outside the content branches.

Screens and every state: [screens.md](../../../design/features/playola-sign-in/screens.md).

## Architecture

```
QuickInterviewEditorApp
 ├─ @State PlayolaSessionModel   (app-scoped @Observable, like AppLaunchModel)
 │    ├─ PlayolaTokenStore         dependency: load / save / delete per environment (Keychain)
 │    ├─ PlayolaAPIClient          dependency: exchangeCode, currentUser (URLSession)
 │    └─ PlayolaBrowserAuthClient  dependency: run one ASWebAuthenticationSession
 ├─ DocumentGroup → ProjectHostView
 │    └─ WelcomePage trio (new)    shown by the host gate above
 └─ Settings → new "Playola" tab
      └─ PlayolaSettings trio (new)
```

- **`PlayolaSessionModel`** is the only writer of `@Shared(.playolaAccount)` (in
  memory), which is the single copy of the account; the session model doesn't keep
  its own. It owns the token, generation, the one sign-in attempt
  (idle / waiting / failed), restore at launch, Sign Out, the 401 rule and server
  switching. It's injected with `.environment` into both the document windows and the
  Settings scene. It's a plain `@MainActor @Observable ViewModel` with injected
  dependencies, tested like a page model.
- **`WelcomePageModel`** and **`PlayolaSettingsModel`** read the account and the
  attempt from the session model and hold all text, flags and actions for their
  screens. `WelcomePageModel` also holds the window's "use a local file" choice.
- **`PlayolaAPIClient`** keeps every path and DTO in one file. Each call takes
  `(environment, token)` explicitly, and errors separate `unauthorized` (401) from
  everything else. URLSession, not Alamofire.
- **`PlayolaBrowserAuthClient`** only runs the browser session and returns the
  callback URL, or throws "canceled". PKCE generation and callback checking are plain
  functions in the session model's file, tested directly.
- Every side effect is a dependency with `liveValue` and `testValue`. Tests never touch
  the network, the Keychain or a browser.

## Testing

Swift Testing, `expectNoDifference`, `withDependencies`, local `@Shared`, no
`Task.sleep`.

- **PKCE / callback:** fixed bytes give a known verifier and challenge (RFC 7636
  example); callback checks reject wrong scheme, host, path, missing or duplicate
  `code`, a mismatched `state`, and `error=`.
- **PlayolaSessionModel:**
  - sign-in success: token saved for the active environment, status signed in, then
    the user filled from `/me`
  - cancel: back to signed out, no failure
  - state mismatch, exchange failure (400 and 401), network error: failed, no token
    saved
  - a second sign-in while waiting doesn't start another browser session
  - restore: token → signed in before `/me` answers; no token → signed out; Keychain
    error → signed out and **no delete**
  - `/me` 401 → token deleted, signed out with the "rejected by Playola" reason
  - `/me` network error → stays signed in, user `nil`
  - late answers are dropped: a stale `/me` (success or 401) after sign-out or a
    server switch; an exchange that succeeds after Cancel saves nothing; switching
    away and back mid-restore restores the right token
  - save failure → failed sign-in; delete failure → still signed in, "Couldn't sign
    out" text
  - server switch loads only that server's token; a staging call never carries the
    production token
  - Sign Out deletes only the active environment's token
- **WelcomePageModel:** shows for empty + signed out; hidden while restoring, when
  signed in, for a non-empty project, and after "Use a Local Audio File"; text and
  buttons for each of the four states.
- **PlayolaSettingsModel:** signed-in text with and without a loaded user, signed-out
  text, waiting/failed Status text, picker visible only when the build allows it.
- **Token store:** the service literal is pinned by a test.
- **API decoding:** `/me` fixture with unknown extra fields and `lastName` as `null`;
  the token response.
- **API client:** authenticated requests carry the token only to the environment's
  base URL and don't follow redirects.
- **Touched-area regression:** the full existing suite runs (the host gate and the
  Settings scene are shared).

**Manual QA** (once the server endpoints are on staging): sign in with Google and with
Apple against staging in a debug build; quit and relaunch (still signed in, no
Welcome flash); turn Wi-Fi off and relaunch (still signed in, name missing); revoke or
expire the token on the server (next launch shows "signed out by Playola"); open an
existing `.pie` while signed out (opens normally); Use a Local Audio File → import
works exactly as today; a Release build shows no server picker.

## PR plan (base: `main`)

This repo has no `develop` branch (checked `origin`); `main` is the integration
branch, as for every recent PR.

One PR: **`feature: sign in to Playola`** — environment, token store, API client,
browser auth, session model, the Settings ▸ Playola tab, the Welcome screen and its
host gate. Must compile and pass on Xcode 16.4 (CI). It stays a draft until desktop
auth works end to end on staging, so a signed-out editor is never shown a button that
can't work yet. (A Settings-only first PR was considered; it would land code early but
give no one anything usable before the server is ready.)

## Roadmap (agreed direction, not part of this design)

- **Step 2 — automatic downloads.** Check Playola at launch, about every hour while
  the app is open, and on File ▸ Check for New Source Tapes. Download and prepare one
  tape at a time into a hidden cache (local storage is an invisible cache, never a
  user-facing library), then post a macOS notification that opens the project.
  Reusable rules from the superseded design: re-fetch the job before every download,
  never send the Playola token to S3, never persist the download URL, one download at
  a time, restart rather than resume, link projects to their tape in `project.json`.
- **Step 3 — Open becomes the source-tape browser.** "Not done yet" and "Done"
  sections; a local-only "I'm Done With This Tape" command (done = the editor says
  they've extracted everything); a done tape can be reopened.
- Later: results go back to Playola and local export goes away.

## Calls I made (minor; flag any you disagree with)

- Welcome lives in the empty project window (same gate as Model Setup), not a new
  window, because every window in this app is a project window.
- Welcome comes before Model Setup.
- Sign-in errors show inline (map 09.3), not as an alert. `PlayolaAlert` isn't added in
  this step.
- A saved token counts as signed in immediately, so the app works offline; `/me` is
  only for the name.
- The account is in memory and refilled from `/me`. Only the token persists.
- The browser session is not ephemeral, so an editor already signed in to Google in
  their browser isn't asked again.
- One app-wide sign-in attempt; every Welcome window mirrors it.
- Name and email only: `profileImageUrl` and `role` aren't decoded in step 1.
- No separate session actor in step 1: the main-actor session model holds the
  environment, token and generation. Step 2's background work can extract one if it
  needs to.
- URLSession, not Alamofire.

## Design deliverables

- Screens: [screens.md](../../../design/features/playola-sign-in/screens.md)
- Endpoints: [endpoints.md](../../../design/features/playola-sign-in/endpoints.md)
- Models: [models.md](../../../design/features/playola-sign-in/models.md)
