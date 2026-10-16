# Error surfacing: never swallow errors, make every user-facing error useful

**Status:** Architecture locked 2026-10-16 (Codex consult, gpt-5.6-sol). Four PRs.
**Audits:** [audit-swift.md](2026-10-16-error-surfacing/audit-swift.md) (92 sites: S/P/D/Y/E/M/K IDs),
[audit-python.md](2026-10-16-error-surfacing/audit-python.md) (H/M/L IDs, written `py-M*` / `py-L*` below).

## Why

A brand-new user ran a suggestion search and saw only
"Some requests failed. Resume to retry the unfinished requests." The real Anthropic
error (out of credits, bad key, Tier-1 rate limit, overloaded, network/TLS) was thrown
away at three layers:

1. Python keeps only `type(exc).__name__` (`cut_suggester/configured_run.py` extraction
   loop; `run_journal.py` failed request record). Discovery failures checkpoint
   `needs_retry` with an **empty** `failed_batches`.
2. Swift `SuggestionRunWireFailure` decodes only `kind` / `request_key` / `retryable`;
   `suggestionFailureMessage` returns a fixed string.
3. `LiveCutSuggester` returns `.recoverableFailure` for `needs_retry` without reading
   stderr or the exit code; the hard-failure path regex-classifies the raw stderr tail and
   shows `QIE_EVENT` JSON lines to the user.

The same pattern (generic constant, `reportIssue`-only, `try?` collapsing a real cause)
recurs across the app; see the audits.

## Rules (apply to every PR)

- Every user-facing error names **what failed**, keeps the **underlying cause**, and says
  **what the user can do**.
- A user-triggerable failure handled only by `reportIssue` is a bug: also surface
  model-owned state the view shows.
- Do not mechanically turn every `try?` into a log. If the failure changes correctness or
  what the user expects, propagate or surface it. Use `os.Logger` only for intentionally
  best-effort paths (cache reads, pruning, legacy migration, optional metadata).
- Display strings live on `@Observable` models (repo CLAUDE.md). Not in Python, not in
  wire structs, not in views.
- Never show raw stderr, `QIE_EVENT` / `QIE_ERROR` lines, tracebacks, or full provider
  bodies in the UI. Never log prompts, transcript text, headers, env vars, or API keys.

## Design decisions

### 1. Normalize provider failures in Python (`cut_suggester/llm.py`)

Add `LLMError` (+ category) raised by both `AnthropicClient` and `OpenAIClient`. Add one
small `failure_record(exc) -> dict` mapper used by `configured_run.py` so parser modules
(`extraction.py`, `configured_discovery.py`, `intro_refinement.py`) never import live
clients; their parse/validation errors map to `bad_response`.

| Condition | `category` | `retryable` |
|---|---|---|
| 401 / authentication error | `auth` | false |
| 400 whose message mentions credit / billing / balance / quota | `credits` | false |
| 429 | `rate_limit` | true |
| 529 or explicit overloaded error | `overloaded` | true |
| connection / DNS / TLS failure | `network` | true |
| timeout exception | `timeout` | true |
| other 5xx | `server` | true |
| other provider 4xx (incl. 403) | `bad_request` | false |
| invalid / empty / truncated / unparseable provider response | `bad_response` | true |
| local prompt-evidence limit | `input_size` | false |

Keep only safe data: provider message, status code, request id, retry-after seconds.
For network/TLS, include the root cause from `__cause__` (e.g. `CERTIFICATE_VERIFY_FAILED`)
in `message`; the SDK's own text is just "Connection error.". Do NOT add another retry loop:
the SDK already retries 429/5xx (`max_retries=2`).

### 2. Persist the record in `failed_batches[]` only

`failed_batches` entries are extensible (Swift ignores unknown keys; the checkpoint only
requires an array). Do **not** extend failed journal request records
(`SuggestionRecoveryArchive.validateRecord` allow-lists their keys and integrity-hashes
them); keep `error_type` there unchanged. Do **not** add checkpoint root keys.

Discovery fix (audit H3): in `validated_request`, catch the failure where `stage` and
`request_key` are known, append a `kind: "discovery"` record, re-raise; the outer handler
checkpoints `needs_retry`. If writing that checkpoint itself fails, keep the original
exception as the reported error (py-M8).

### 3. Stop extraction after terminal account/request failures

After `auth`, `credits`, or `bad_request`: checkpoint immediately and issue no further
provider requests. Keep going after transient categories and after a per-candidate
`input_size`. `retryable` means "the same request may succeed unchanged"; it is not the
Resume-button policy (see 4).

### 4. Swift: decode facts, render English on the model

- `SuggestionRunWire.swift`: decode the record into a forward-compatible enum
  (`SuggestionFailureCategory` with `case unknown(String)`; never a raw-value enum that
  rejects new categories) plus message / status / request id / retry-after.
- `SuggestionRunCheckpoint` (`Models/SuggestionRun.swift`) is **persisted in the `.pie`
  document** via `EditorDocumentState.unfinishedSuggestionRun`. Add an optional structured
  failure summary; keep decoding the legacy `failureMessage` so old documents still open;
  new checkpoints write the structured value and leave the legacy field nil.
- `SuggestionRunModel` owns all text and button policy: `recoveryMessage`, Resume
  visibility/title, Discard title. The view (`CutSuggestionsPageView`) only binds.
- Several failures: show the most actionable one, in this order:
  `auth, credits, bad_request, input_size, rate_limit, overloaded, timeout, network,
  server, bad_response, unknown`, plus "N requests failed" when N > 1. Never concatenate
  provider messages.
- Provider name comes from the run snapshot's model (Anthropic vs OpenAI), not hard-coded.

User-facing text. Append when available:
`Provider message: "{message}" (HTTP {status}; request {request_id}).`

| Category | Primary text | Resume |
|---|---|---|
| `auth` | {Provider} rejected your API key. Check or replace the key in Settings, then Resume. | yes |
| `credits` | Your {Provider} account is out of credits. Add credits at console.anthropic.com/settings/billing (Anthropic) / platform.openai.com/settings/organization/billing (OpenAI), then Resume. | yes |
| `rate_limit` | {Provider}'s rate limit was reached. Wait {retry_after}, then Resume. (No retry-after: "Wait a few minutes, then Resume.") | yes |
| `overloaded` | {Provider} is temporarily overloaded. Wait a few minutes, then Resume. | yes |
| `network` | The app could not reach {Provider}. Check your internet connection, VPN, or firewall, then Resume. | yes |
| `timeout` | {Provider} did not respond in time. Check your connection, then Resume. | yes |
| `server` | {Provider} returned a server error. Wait a few minutes, then Resume. | yes |
| `bad_request` | {Provider} rejected the suggestion request. Discard this search and start a new one. | no |
| `bad_response` | {Provider} returned a response the app could not read. Resume to try that request again. | yes |
| `input_size` | Some suggestion evidence is too large to send to {Provider}. Discard this search and shorten the transcript or naming instructions. | no |
| unknown | The suggestion search failed while {phase}: {message}. | per `retryable` |

Auth and credits keep Resume: the user needs it after fixing the account.

### 5. Structured hard failures: `QIE_ERROR`

Both `cut_suggester/cli.py` and `logic_markers/cli.py` top-level handlers emit exactly one
stderr line:

```text
QIE_ERROR {"schema_version":1,"domain":"cut_suggester","operation":"suggest","phase":"discovering","message":"...","error_type":"BadRequestError","provider_error":{"category":"credits","message":"...","status_code":400,"request_id":"req_...","retry_after":null,"retryable":false}}
```

(`provider_error` only when the cause is an `LLMError`; no traceback in the JSON;
tracebacks stay behind `QIE_DEBUG` / logs.) Swift scans backward for the last *valid*
`QIE_ERROR`; if none, falls back to the last non-protocol stderr text. Remove
`mapFailure`'s regex classification. Exit code comes from `waitForExit()`. For V2 suggest:
`ready` requires exit 0, `needs_retry` requires exit 1; any other combination is a hard
failure even if stdout decodes.

Add a cut-suggester diagnostic log (same bounded pattern as `LiveEngine`'s per-run log),
written only on nonzero exit or decode failure: subcommand, exit code, stdout, stderr,
parsed `QIE_ERROR`; never env or key; keep newest 20. The typed Swift error carries the
log path; show it as copyable detail, not in the primary sentence. Also fix
`logic_markers/whisperx_backend.py` so an `afconvert` failure includes its captured stderr
(match `logic_markers/audio.py`).

### Wire examples (`failed_batches[]`)

```json
{"kind":"extraction","request_key":"<digest>","candidate_ids":["uuid-1"],
 "category":"rate_limit","message":"...","status_code":429,"request_id":"req_01ABC",
 "retry_after":30,"retryable":true,"error_type":"RateLimitError"}
{"kind":"discovery","stage":"classify:110:239","request_key":"<digest>",
 "category":"credits","message":"Your credit balance is too low to access the Anthropic API.",
 "status_code":400,"request_id":"req_01ABC","retry_after":null,"retryable":false,
 "error_type":"BadRequestError"}
{"kind":"input_size","candidate_id":"uuid","category":"input_size","message":"...",
 "status_code":null,"request_id":null,"retry_after":null,"retryable":false,
 "error_type":"InputSizeDiagnostic","mandatory_characters":27120,"max_input_characters":24000}
```

## PR split (dependency order)

Codex proposed five PRs; its first two (Python record, Swift display) are merged into
PR A because neither is user-visible alone.

### PR A: `bugfix: explain why suggestion searches stopped`
Decisions 1-4. Python: `llm.py`, `configured_run.py`, parser error mapping. Swift:
`SuggestionRunWire.swift`, `SuggestionRun.swift`, `SuggestionRunModel.swift`,
`LiveCutSuggester.swift` (needs_retry path only), `CutSuggestionsPageView.swift` (bind only).
Audit IDs: H1-H4, H7, py-M2, py-M3, py-M4, py-M8, S14-S16, S18-S19.
Tests: `tests/test_cut_suggester_llm.py`, `tests/test_configured_run.py`,
`tests/test_suggestion_run_journal.py`; `LiveCutSuggesterTests`, `SuggestionRecoveryClientTests`,
`SuggestionRunModelTests`, `SuggestionRunTests`, `CutSuggestionWireTests`. Cover each
category, discovery persistence, early abort, continued transient batches, legacy
checkpoint (old `.pie` with `failureMessage`), unknown category, mixed failures, Resume
visibility.

### PR B: `bugfix: make helper process failures diagnosable` (after A)
Decision 5. Both Python CLIs, `whisperx_backend.py`, `LiveCutSuggester.swift`,
`LiveEngine.swift`, `CutSuggestClient.swift`, `EngineEvent.swift`.
Audit IDs: H5, H6, py-M1, py-L1 (log the frozen-entry setup misses), py-L8, py-L9, S1, S2,
S7-S13, S17. Tests: Python CLI + audio-conversion tests; `LiveCutSuggesterTests`,
`LiveEngineIntegrationTests`, `LiveEngineInjectTests`, `EngineEventTests`. Cover signals,
malformed `QIE_ERROR`, protocol-line filtering, exit/status mismatches, log paths.

### PR C: `bugfix: show errors from project, settings and playback actions` (independent)
User-visible swallowed errors: P1, P2, P3, P5, Y1-Y7, E3, E7, E8, E9, S30, S33.
Run the full pre-existing suites for Project, Settings, Editor transport/playback,
Waveform, Keychain, InstallLocation (touched-area regression rule).

### PR D: `bugfix: keep useful error details throughout the app` (independent)
Context-destroying mediums + behavior-affecting lows: S20, S21, S23, S24, S25, S26; K1-K6;
D1, D3, D4, D5, D6; E1, E2, E4 (verify each site), E5, E6; M1-M5, M8, M11, M13, M14;
P4, P6-P11. Logger for intentional best-effort paths.

**Leave alone:** S29 (preview gating; the real action reports), the documented cleanup
`try?` sites (audit-swift section 9), dev-only unconfigured-dependency assertions (M16, K7),
D2 (keeping only the final retry error is right; earlier attempts may be logged), lenient
compatibility decoding (K8) unless it can corrupt state.

## Do not

- Invent an app-wide `AppError`, error bus, or alert framework.
- Put structured provider data in both `failed_batches` and journal request records.
- Add checkpoint root keys.
- Hide Resume for auth or credits.
- Auto-retry auth, credits, or bad requests; add a retry loop on top of the SDK's.
- Convert benign cleanup failures into user alerts.

## Verification (each PR)

```bash
python3 -m pytest -q
cd QuickInterviewEditor && make test-fast && make format-check && make lint
```
