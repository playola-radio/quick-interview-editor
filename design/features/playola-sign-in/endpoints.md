# Playola Sign-in — Endpoint changes

All endpoints live on the Playola admin API. The base URL depends on the environment:
`https://admin-api.playola.fm`, `https://admin-api-staging.playola.fm`, or
`http://localhost:10020`. Decoding ignores unknown fields. Authenticated calls don't
follow redirects.

Server state was checked on `playola` `origin/develop` @ `fd456a5`: `/v1/users/me`
exists, and the two desktop-auth endpoints do not exist yet. The **New** rows are the
contract the server session builds. The final names live only in `PlayolaAPIClient`
and its live implementation.

| Change | Method | Path | Auth | Purpose |
|---|---|---|---|---|
| New | GET | `/v1/auth/desktop/authorize` | none (browser) | Start Playola sign-in for the desktop app (PKCE) |
| New | POST | `/v1/auth/desktop/token` | none | Exchange the one-time handoff code for a Playola JWT |
| Unchanged (new consumer) | GET | `/v1/users/me` | signed-in user | Load the signed-in user's name and email |

## GET /v1/auth/desktop/authorize
- **Change:** New
- **Auth:** none. It is opened in `ASWebAuthenticationSession`, not called with
  URLSession.
- **Path params:** none
- **Query params:**

  | Param | Type | Required | Default | Notes |
  |---|---|---|---|---|
  | `state` | string (base64url, 32 random bytes) | yes | | Echoed back unchanged in the callback |
  | `code_challenge` | string (base64url SHA-256 of the verifier) | yes | | |
  | `code_challenge_method` | `S256` | yes | | Only `S256` is accepted |
  | `provider` | `google` \| `apple` | no | absent | When absent, Playola shows its own "Continue with Google / Apple" page in the browser. The app never sends it in step 1. |

- **Request body:** none
- **Response `302`:** to Playola's provider chooser, or straight to the provider when
  `provider` is given. After the provider succeeds, a final redirect goes to
  `playola-interview-editor://auth/callback?code=<one-time code>&state=<state>`.
  The code is single-use and expires after 60 seconds.
- **Errors:**

  | Status | When |
  |---|---|
  | 400 | missing or invalid `state`, `code_challenge`, or `code_challenge_method`; or an unknown `provider` |
  | `…/auth/callback?error=<reason>&state=<state>` | the provider sign-in failed or was denied. The app shows "Sign-in failed". |

- **Consumers:** Welcome and Settings ▸ Playola ("Sign In with Playola…").

## POST /v1/auth/desktop/token
- **Change:** New
- **Auth:** none. The one-time code plus the PKCE verifier authenticate the call.
- **Path params:** none
- **Query params:** none
- **Request body:**
  ```json
  { "code": "4f1c…", "codeVerifier": "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" }
  ```
- **Response `200`:**
  ```json
  { "playolaToken": "eyJhbGciOi…" }
  ```
- **Errors:**

  | Status | When |
  |---|---|
  | 400 | malformed body, or the verifier doesn't match the challenge |
  | 401 | the code is unknown, expired, or already used |

  A 401 here is a **sign-in failure** ("Sign-in failed"), not the "signed out by
  Playola" rule, because no session exists yet.
- **Consumers:** Welcome and Settings ▸ Playola, after the browser callback.

## GET /v1/users/me
- **Change:** Unchanged. The desktop app is a new consumer.
- **Auth:** `Authorization: Bearer <playolaToken>`
- **Path params:** none
- **Query params:** none
- **Request body:** none
- **Response `200`** (the fields the app reads; it ignores the rest):
  ```json
  {
    "id": "7c2e…", "firstName": "Brian", "lastName": "Keane", "email": "brian@playola.fm"
  }
  ```
- **Errors:**

  | Status | When | What the app does |
  |---|---|---|
  | 401 | the token is expired, revoked, or unknown | Deletes the token, signs out, and empty windows show "Signed out by Playola" |
  | other / network | server or connection trouble | Stays signed in and shows "Signed in" without the name until the next launch or server switch |

- **Consumers:**
  - Called right after a successful sign-in.
  - Called at launch when a saved token exists.
  - Called when the debug server picker switches to an environment with a saved token.
