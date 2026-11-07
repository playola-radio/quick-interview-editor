# Playola Assignments — Screens

Pen file: `design/features/playola-assignments/assignments.pen`

## Navigation map

| Screen | Surface | Address | Presentation | Reached from |
|---|---|---|---|---|
| Assignments window | native macOS | n/a (native) | Window scene `assignments` | Window ▸ Assignments (⇧⌘A); automatically at launch when signed in |
| Remove from this Mac alert | native macOS | n/a (native) | Alert over the Assignments window | Row ⋯ menu ▸ Remove from this Mac… |
| Sign-in error alert | native macOS | n/a (native) | Alert over the Assignments window | Sign in with Google / Apple fails |
| Settings ▸ Account | native macOS | n/a (native) | Settings window ▸ Account tab | App menu ▸ Settings… ▸ Account; Assignments avatar menu |
| Settings ▸ Library | native macOS | n/a (native) | Settings window ▸ Library tab | App menu ▸ Settings… ▸ Library |
| Editor window | native macOS | n/a (native) | Document window (`.pie` project) | Open on a ready row in Assignments; File ▸ Open |

## Assignments window

- **Status:** New
- **Surface:** native macOS
- **Address:** n/a (native); `Window("Assignments", id: "assignments")`
- **Access:** anyone; signed-out users see only the sign-in page, signed-in users see their assigned interviews
- **Navigated to from:** Window ▸ Assignments (⇧⌘A); launch when signed in (`launchesToAssignments` hint); closing the sign-in alert returns here
- **Navigates to:** Open on a ready row opens its `.pie` project in the Editor window; "Install Models…" opens the model setup flow; "Create New Project…" starts a new project for the interview; "Show Library in Finder" reveals the library folder; row ⋯ menu ▸ Remove from this Mac… opens the confirmation alert; avatar menu ▸ Settings / Sign Out; Sign in with Google / Apple opens the system web-auth sheet and, on failure, the sign-in error alert

| State | When it shows | Node | Mockup |
|---|---|---|---|
| Signed out | No Playola session. Sign-in page only; no local list is shown | vVgbG | ![Signed out](exports/assignments--signed-out.png) |
| Loading | Signed in, first fetch in flight, nothing cached | JXz1L | ![Loading](exports/assignments--loading.png) |
| List | Assignments grouped by station then assignment, with row states Ready, Preparing, Downloading, Waiting, Downloaded (waiting to transcribe), Not downloaded, Failed, and a "No longer assigned" section; the open row ⋯ menu is shown | Nm15X | ![List](exports/assignments--list.png) |
| Empty | Signed in, nothing assigned | fbUXX | ![Empty](exports/assignments--empty.png) |
| Refresh error | Refresh failed; last loaded list kept, banner with Retry | ftlRi | ![Refresh error](exports/assignments--refresh-error.png) |
| Models needed | Transcription models not installed; banner with Install Models… | AwpAu | ![Models needed](exports/assignments--models-needed.png) |
| Project missing | A ready row's project is gone from the library; Show Library in Finder and Create New Project… | tdufk | ![Project missing](exports/assignments--project-missing.png) |
| Library paused | Library settings could not be read; automatic downloads paused (no button) | X3LKr | ![Library paused](exports/assignments--library-paused.png) |
| Low disk | Less than 20 GB free; automatic downloads paused, queued rows show "Paused — low disk space", explicit Download still works | JfaIG | ![Low disk](exports/assignments--low-disk.png) |

## Remove from this Mac alert

- **Status:** New
- **Surface:** native macOS
- **Address:** n/a (native); alert over the Assignments window
- **Access:** signed-in users, on a row with a local project
- **Navigated to from:** row ⋯ menu ▸ Remove from this Mac…
- **Navigates to:** Move to Trash moves the project to the Trash and returns to the list; Cancel returns to the list; OK (document open) returns to the list

| State | When it shows | Node | Mockup |
|---|---|---|---|
| Confirm | Remove chosen on a closed project | XkSN0 | ![Confirm](exports/remove-from-this-mac--confirm.png) |
| Document open | The project is open in an editor window; user must close it first | vRhvW | ![Document open](exports/remove-from-this-mac--document-open.png) |

## Sign-in error alert

- **Status:** New
- **Surface:** native macOS
- **Address:** n/a (native); alert over the Assignments sign-in page
- **Access:** signed-out users
- **Navigated to from:** Sign in with Google / Apple fails verification or the connection fails
- **Navigates to:** OK dismisses back to the sign-in page; Copy Details copies the diagnostic text

| State | When it shows | Node | Mockup |
|---|---|---|---|
| Error | Sign-in attempt failed | CeC3i | ![Sign-in error](exports/sign-in-error--error.png) |

## Settings ▸ Account

- **Status:** Changed
- **Surface:** native macOS
- **Address:** n/a (native); Settings window ▸ Account tab
- **Access:** anyone
- **Navigated to from:** App menu ▸ Settings… ▸ Account; Assignments avatar menu
- **Navigates to:** Sign In… starts the web-auth sheet (sign-in error alert on failure); Sign Out returns the Assignments window to the signed-out page
- **Changed from today:** the Settings window gains Account and Library tabs next to Cut Suggestions, Suggestions, Editing and Playback Latency. The debug-only Server picker appears only in debug builds.

| State | When it shows | Node | Mockup |
|---|---|---|---|
| Signed in | Name, email, Sign Out | aDFCz | ![Signed in](exports/settings-account--signed-in.png) |
| Signed out | Sign In… button | h5caE | ![Signed out](exports/settings-account--signed-out.png) |
| Debug environment | Debug build: signed-in account plus a Production / Staging / Local server picker | Q9hTqB | ![Debug environment](exports/settings-account--debug-environment.png) |

## Settings ▸ Library

- **Status:** Changed
- **Surface:** native macOS
- **Address:** n/a (native); Settings window ▸ Library tab
- **Access:** anyone
- **Navigated to from:** App menu ▸ Settings… ▸ Library
- **Navigates to:** Show in Finder reveals the library; Move Library… and Choose Existing Folder… open a folder picker
- **Changed from today:** new tab. The two Assignments options are checkboxes (the macOS rendering of a SwiftUI Toggle).

| State | When it shows | Node | Mockup |
|---|---|---|---|
| Default | Library at `~/Music/Playola Interview Editor`; both automatic options on | C0TDx | ![Default](exports/settings-library--default.png) |

## Editor window

- **Status:** Changed
- **Surface:** native macOS
- **Address:** n/a (native); document window for a `.pie` project
- **Access:** anyone who can open the project
- **Navigated to from:** Open on a ready Assignments row; File ▸ Open; Open Recent
- **Navigates to:** unchanged
- **Changed from today:** projects linked to a Playola assignment show a subtitle strip under the title bar, "KXYZ Morning — Interview with Jane Doe" (station, then interview). Unlinked projects are unchanged and show no strip.

| State | When it shows | Node | Mockup |
|---|---|---|---|
| Linked | Project originated from an assignment | HgdhY | ![Linked](exports/editor--linked.png) |
