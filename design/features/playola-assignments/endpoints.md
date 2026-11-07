# Playola Assignments — Endpoint changes

All endpoints live on the Playola admin API. The base URL depends on the environment:
`https://admin-api.playola.fm`, `https://admin-api-staging.playola.fm`, or
`http://localhost:10020`. The app sends `Authorization: Bearer <playolaToken>` on every
call except the two desktop-auth calls, and never on S3 URLs. Decoding ignores unknown
fields.

Server state was checked on `playola` `origin/develop` @ `fd456a5`. The **New** rows
are provisional and are being built in the server session. Final names land only in
`PlayolaAPIClient` and its live implementation.

| Change | Method | Path | Auth | Purpose |
|---|---|---|---|---|
| New | GET | `/v1/auth/desktop/authorize` | none (browser) | Start Google/Apple sign-in for the desktop app (PKCE) |
| New | POST | `/v1/auth/desktop/token` | none | Exchange the one-time handoff code for a Playola JWT |
| New | GET | `/v1/jobs` | signed-in user | List every job assigned to the caller, across stations |
| Changed | GET | `/v1/stations/:stationId/jobs/:jobId` | admin, job assignee | Adds `assignedAt`, and tape `downloadUrl`/`previewUrl`/`fileSizeBytes`/`fileExtension` |
| Unchanged (new consumer) | GET | `/v1/users/me` | signed-in user | Load the signed-in user's profile |

## GET /v1/auth/desktop/authorize
- **Change:** New
- **Auth:** none. It is opened in `ASWebAuthenticationSession`, not called with URLSession.
- **Path params:** none
- **Query params:**

  | Param | Type | Required | Default | Notes |
  |---|---|---|---|---|
  | `provider` | `google` \| `apple` | yes | | |
  | `state` | string (base64url, 32 random bytes) | yes | | Echoed back unchanged in the callback |
  | `code_challenge` | string (base64url SHA-256 of the verifier) | yes | | |
  | `code_challenge_method` | `S256` | yes | | Only `S256` is accepted |

- **Request body:** none
- **Response `302`:** to the provider's sign-in. After the provider succeeds, a final
  redirect goes to
  `playola-interview-editor://auth/callback?code=<one-time code>&state=<state>`.
  The code is single-use and expires after 60 seconds, like the Android Apple flow.
- **Errors:**

  | Status | When |
  |---|---|
  | 400 | missing or invalid `provider`, `state`, `code_challenge`, or `code_challenge_method` |
  | `…/auth/callback?error=<reason>&state=<state>` | provider sign-in failed or was denied. The app shows a sign-in error alert. |

- **Consumers:** Sign-in page ("Sign in with Google" / "Sign in with Apple").

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

  A 401 here is a **sign-in failure** (an alert), not the global "signed out" rule,
  because no session exists yet.
- **Consumers:** Sign-in page, after the browser callback.

## GET /v1/jobs
- **Change:** New
- **Auth:** signed-in user. With `assignedTo=me`, the server returns only the caller's
  jobs.
- **Path params:** none
- **Query params:**

  | Param | Type | Required | Default | Notes |
  |---|---|---|---|---|
  | `assignedTo` | `me` | yes | | The app always sends `me` |
  | `completed` | boolean | no | (all) | **The app omits it**, so completed jobs come back for the "Show completed jobs" toggle. (The brief's draft sent `completed=false`.) |

- **Request body:** none
- **Response `200`:** a bare array, not paginated. Each job has the job-detail shape
  plus a `station` summary:
  ```json
  [
    {
      "id": "5b0d…", "stationId": "a1f3…", "name": "Week 1 interviews", "description": null,
      "assignedTo": "u-77…", "assignedAt": "2026-11-04T16:20:11.000Z", "completedAt": null,
      "createdAt": "2026-11-04T16:02:55.000Z", "updatedAt": "2026-11-04T16:20:11.000Z",
      "station": { "id": "a1f3…", "name": "KXYZ Morning", "imageUrl": "https://…/kxyz.png" },
      "assignee": { "id": "u-77…", "firstName": "Sam", "lastName": "Rivera", "email": "sam@example.com", "profileImageUrl": null },
      "sourceTapes": [
        { "id": "t-91…", "stationId": "a1f3…", "name": "Interview with Jane", "durationMS": 3812000,
          "status": "new", "fileSizeBytes": 672350208, "fileExtension": "wav",
          "createdAt": "2026-11-04T15:58:00.000Z", "updatedAt": "2026-11-04T15:58:00.000Z" }
      ],
      "submissions": []
    }
  ]
  ```
  The list **leaves out** `downloadUrl` and `previewUrl`. The app gets them only from
  the job detail, right before downloading, so a list refresh never mints dozens of
  presigned URLs. If the server includes them anyway, the app ignores them.
- **Errors:**

  | Status | When |
  |---|---|
  | 400 | `assignedTo` missing or not `me`, or an unknown query field (server convention) |
  | 401 | token invalid. The app signs out for this environment. |

- **Consumers:** Assignments window (every refresh trigger), coordinator merge.
- **Server asks:** (1) `assignedAt`, (2) `station` summary, (3) `fileSizeBytes` and
  `fileExtension` (or `contentType`) on each tape, (4) completed jobs included when
  `completed` is omitted, (5) no pagination. If the list ever has to paginate, the app
  must fetch every page before it treats any tape as "No longer assigned".

## GET /v1/stations/:stationId/jobs/:jobId
- **Change:** Changed. The endpoint already exists on develop. The fields below are
  added.
- **Auth:** admin or the job's assignee (`requireAdminOrAssignedProducerForJob`)
- **Path params:** `stationId` (UUID), `jobId` (UUID)
- **Query params:** none
- **Request body:** none
- **Delta:**
  - Job: **adds** `assignedAt` (iso8601 | null; set whenever `assignedTo` changes).
  - Each `sourceTapes[]` entry **adds**:
    - `downloadUrl`: a presigned GET for the original, valid about 5 minutes. **It is
      never persisted or logged.**
    - `previewUrl`: a presigned m4a. **The app does not use it.**
    - `fileSizeBytes`: an integer.
    - `fileExtension`: `wav` | `m4a`.
  - **Behavior and compatibility:** no change for existing callers (the admin website).
    The fields are additive.
- **Response `200`:** the job shape shown under `GET /v1/jobs`, plus on each tape:
  ```json
  { "downloadUrl": "https://playola-tapes.s3.amazonaws.com/…?X-Amz-Expires=300&…",
    "previewUrl": "https://playola-tapes.s3.amazonaws.com/…preview.m4a?…" }
  ```
- **Errors:**

  | Status | When |
  |---|---|
  | 401 | token invalid. The app signs out for this environment. |
  | 403 | the caller is no longer the assignee. The app treats the tape as "No longer assigned" and doesn't download. |
  | 404 | the job was deleted or the station doesn't match. Treated the same as 403. |

- **Consumers:** the download worker, called immediately before **every** download
  attempt to check the assignment and get a fresh `downloadUrl`.

## GET /v1/users/me
- **Change:** Unchanged. This is a new consumer.
- **Auth:** signed-in user
- **Path params:** `me` (literal alias for the caller's id)
- **Query params:** none
- **Request body:** none
- **Response `200`:** the bare user. The app reads only these fields and ignores
  `extendedPlaylist` and anything else:
  ```json
  { "id": "u-77…", "firstName": "Sam", "lastName": "Rivera", "email": "sam@example.com",
    "profileImageUrl": null, "role": "user" }
  ```
- **Errors:**

  | Status | When |
  |---|---|
  | 401 | token invalid. The app signs out for this environment. |

- **Consumers:** sign-in (right after the token exchange), session restore at launch,
  Settings ▸ Account, the Assignments account menu.

## Not an endpoint: the S3 download
The app sends `GET <downloadUrl>` through a separate URLSession with **no
`Authorization` header and no cookies**. Only a `200` with a body is accepted.
`Content-Length` is required, and it drives both the progress bar and the final byte
check. An S3 `403` (expired or revoked URL) is a retryable download failure. The retry
fetches the job detail again. It is never treated as a sign-out.
