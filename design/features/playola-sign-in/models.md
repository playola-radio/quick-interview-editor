# Playola Sign-in — Model changes

This app has no database. Here, "models" means the on-disk `.pie` project contract,
persisted settings, Keychain items, and the in-memory or Codable types that cross a
dependency boundary. **No server models change in this repo.** **The `.pie` project
file does not change in this step.** The server-side fields this feature uses are
listed in `endpoints.md`.

| Change | Model | Storage | Summary |
|---|---|---|---|
| New | Playola token | Keychain generic password | One JWT per environment |
| New | `PlayolaEnvironment` | code, plus the `playolaEnvironment` setting | production / staging / local |
| New | `PlayolaAccount`, `PlayolaUser` | `@Shared(.playolaAccount)`, in memory | Who is signed in to the active environment, or why no one is |
| New | `playolaEnvironment` setting | `appStorage` (UserDefaults) | The debug server picker's choice |
| New | API DTOs | not stored | `DesktopTokenResponse`, `PlayolaUser` (decoded from `/v1/users/me`) |

## Playola token (Keychain) — New

| Attribute | Value |
|---|---|
| Class | `kSecClassGenericPassword` |
| `kSecAttrService` | `fm.playola.PlayolaInterviewEditor.playolaToken` (a **stable literal**, pinned by a test, the same invariant as the Anthropic key) |
| `kSecAttrAccount` | `production` \| `staging` \| `local` |
| Value | The JWT, UTF-8 |

- **Who writes it:** a successful sign-in, for the active environment only.
- **Who reads it:** `PlayolaTokenStore.load(environment)`, at launch and when the debug
  server picker switches environment. Reads happen off the main thread.
- **Who deletes it:** Sign Out, and the 401 rule (only for the session generation that
  made the call). It is **never deleted on a read error**. Only `errSecItemNotFound`
  means "absent". Any other read failure, including item data that isn't valid UTF-8,
  is logged and leaves the user signed out for this launch without touching the item.
  (Unlike today's Anthropic-key loader, unreadable data is an error, not "absent".)
- **Writes are serialized:** saves and deletes run one at a time, and each is checked
  against the session generation before it runs.
- **Migration:** none. This is a new item. It survives Sparkle updates because the
  bundle id, team and service don't change.
- **Existing Anthropic key:** unchanged. It stays in `KeychainClient` under its own
  service.

## PlayolaEnvironment — New

`enum PlayolaEnvironment: String, Codable, CaseIterable, Sendable { case production, staging, local }`

| Case | Base URL | Picker label |
|---|---|---|
| `production` | `https://admin-api.playola.fm` | Production |
| `staging` | `https://admin-api-staging.playola.fm` | Staging |
| `local` | `http://localhost:10020` | Local |

These match `playola-radio-ios` `Config.swift`. Release builds always resolve to
`production`, whatever the setting says.

## PlayolaAccount / PlayolaUser — New (`@Shared(.playolaAccount)`, in memory)

```swift
struct PlayolaAccount: Equatable, Sendable {
  var environment: PlayolaEnvironment
  var status: Status

  enum Status: Equatable, Sendable {
    case restoring                       // Keychain not read yet
    case signedOut(SignedOutReason?)     // nil = never signed in, or signed out by the user
    case signedIn(PlayolaUser?)          // nil until /v1/users/me answers
  }

  enum SignedOutReason: Equatable, Sendable {
    case rejectedByPlayola               // a 401 on the saved token
  }
}
```

| `PlayolaUser` field | Type | Null | Notes |
|---|---|---|---|
| `id` | String | no | |
| `firstName` | String | no | |
| `lastName` | String | yes | Optional, matching the iOS `LoggedInUser` |
| `email` | String | no | |

- **Source of truth:**
  - Signed in or not: whether the Keychain holds a token for the active environment.
  - Name and email: the server (`GET /v1/users/me`). Refilled on launch and on
    sign-in, never persisted.
- **Default:** `PlayolaAccount(environment: <setting>, status: .restoring)`.
- **Writer:** `PlayolaSessionModel` only. It is the single copy of the account; every
  page reads it.
- **Who reads it:** the Welcome gate in every project window, Settings ▸ Playola, and,
  from step 2 on, the source-tape check.

## `playolaEnvironment` setting (`appStorage`) — New

| Key | Type | Default | Read by |
|---|---|---|---|
| `playolaEnvironment` | String (`PlayolaEnvironment` raw value) | `production` | `PlayolaSessionModel` at launch and on change. Ignored in Release builds. |

## API DTOs — New (not stored)

Decoded leniently: unknown keys are ignored. Defined only in `PlayolaAPIClient.swift`.

- `DesktopTokenResponse { playolaToken: String }`
- `PlayolaUser`, as above
