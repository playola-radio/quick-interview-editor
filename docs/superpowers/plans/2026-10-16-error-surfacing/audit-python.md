# Audit inventory: Python helpers (generated 2026-10-16, read-only audit)

IDs (H*, M*, L*) are referenced by the plan in ../2026-10-16-error-surfacing.md. Note: the Python M* IDs are distinct from the Swift mastering M* IDs; the plan prefixes them as py-M*.

# Error-swallowing audit: `cut_suggester` and `logic_markers`

I read the code only and edited nothing. `anthropic` is not installed in this checkout (`requirements.txt` pins 0.121.0), so the SDK behaviour in section 3 is from memory of that SDK, not verified here.

**Scope.** The app spawns three Python entry points:
- `cut_suggester.cli` (`suggest`, `name-clip`)
- `logic_markers.cli` (`plan`, `inject-markers`)
- the PyInstaller wrappers `packaging/cut_suggester_entry.py` and `packaging/engine_entry.py`

The Swift side only spawns `plan`, `inject-markers`, `suggest` and `name-clip`. The `markers`, `transcript`, `cut` and `render` subcommands and `logic_markers/transcribe.py` (the OpenAI Whisper engine) are CLI-only now, and `evals/` is not shipped. Findings there are marked "not on app path".

Paths below are relative to `/Users/brian/conductor/workspaces/logic-utils/santiago-v3`.

## 1. Current wire shape of failure information

### `suggest`, V2 requests (`schema_version` present, `--journal-dir`)

`_cmd_suggest` is at `cut_suggester/cli.py:201-226`.

**Success.** Exit 0, stdout:
```
{"schema_version":2,"run_id","checkpoint_revision","status":"ready","suggestions":[...],"failed_batches":[]}
```
There is no `meta` key in V2 (`configured_run.py:236-237`).

**Partial failure (extraction batches).** Exit 1 (`cli.py:226`), full JSON on stdout with `"status":"needs_retry"`. Each `failed_batches` entry is one of:
- `{"kind":"extraction","request_key","candidate_ids":[...],"retryable":true,"error_type":"<ClassName>"}`, built at `configured_run.py:211-213`.
- `{"kind":"input_size","retryable":false,"candidate_id","mandatory_characters","max_input_characters","message":"candidate evidence and required field instructions exceed the input limit"}`, built at `configured_run.py:196-197` from `asdict(InputSizeDiagnostic)`.

Nothing is emitted on stderr when a batch fails. The only per-batch event is the pre-call `QIE_EVENT {"type":"progress","phase":"extracting","message":"Naming batch i of n","index","total"}`. The exception message is never printed or stored.

**What Swift does with it.**
- `completedEvents` prefers non-empty stdout over the exit code (`LiveCutSuggester.swift:253-260`).
- `SuggestionRunWireFailure` decodes only `kind`, `request_key` and `retryable` (`SuggestionRunWire.swift:~182-187`). It ignores `error_type` and `message`.
- `suggestionFailureMessage` (`SuggestionRunWire.swift:188-195`) returns one of two hard-coded strings:
  - the input-limit text, when an `input_size` entry is non-retryable;
  - otherwise `"Some requests failed. Resume to retry the unfinished requests."`

**Hard failure (discovery, validation, journal, auth, network).**
- Stdout is empty.
- Exit is 1, via `cli.py:287-293`. Argparse errors and a missing request file exit 2.
- Stderr gets `QIE_EVENT {...}` progress and checkpoint lines, then one final line `error: <str(exc)>`. The traceback is printed only if `QIE_DEBUG` is set. The app never sets it; the only occurrences are the two `os.environ.get` checks in the Python CLIs.
- Swift calls `mapFailure(stderr: proc.stderrTail())` (`LiveCutSuggester.swift:197,261,293,336-357`). The tail is the last 40 stderr lines (`LiveEngine.swift:907-923`).
- `mapFailure` filters the `QIE_EVENT` lines out only when classifying. It then passes the unfiltered tail, `QIE_EVENT` lines included, to `.authMissing(stderr)` or `.suggestFailed(stderr)`.
- Classification matches the lowercased text against `openai_key`, `anthropic_api_key`, `api key`, `api_key`, `authentication`, `unauthorized`, `credential`, or `\b401\b`. Anything else becomes `suggestFailed`.

**On-disk journal.**
- `requests/<sha>.json` for a failed call is `{schema_version, request_identity, key, status:"failed", error_type, integrity}` (`run_journal.py:197-203`).
- `checkpoint.json` carries `failed_request_keys` and `failed_batches` (`run_journal.py:214-229`).

### `suggest`, V1 requests (no `schema_version`)
- Success is `{"suggestions":[...],"meta":{n_sentences,n_partitions,n_raw_clips,n_invalid_clips,n_dropped_duration}}` with exit 0.
- Failure is the same as the V2 hard failure.

### `name-clip` (`cli.py:229-239`)
- Success: exit 0, stdout `{"type_id": "<id>"|null, "fields": {fieldId: string|null}}`.
- Failure: exit 1 (or 2), empty stdout, one stderr line `error: <str(exc)>`.
- No `QIE_EVENT` lines are emitted. Swift drains stderr and keeps the tail (`LiveCutSuggester.swift:192,197`). The same `mapFailure` runs on it.
- Nothing is a per-clip failure payload; only success or an error line.

### Engine (`logic_markers.cli`)
- `plan` and `inject-markers` write JSON to stdout on success. For `plan`, stderr carries `QIE_EVENT {"type":"progress","phase","phase_index","phase_count","label","message","fraction"}`.
- Failure: exit 1, or 2 for a missing input or request file. The only failure text is `error: <str(exc)>` (`cli.py:736-745`). No `QIE_EVENT` of type `error` exists anywhere in `logic_markers/` or `cut_suggester/`.
- Swift throws `EngineClientError.engineFailed(stderrTail + logHint)` for `plan` (`LiveEngine.swift:230`) and `injectFailed` for inject (`LiveEngine.swift:374`). Both are surfaced as "Transcription failed: ..." / "Marker injection failed: ...".
- Swift writes a per-run log with the stderr tail and full stdout (`LiveEngine.swift:118-140`).

### Constraints for extending the wire
- **`failed_batches` entries are safe to extend.** `SuggestionRunWireFailure` ignores unknown keys. Swift's checkpoint validation only requires `failed_batches` to be an array (`SuggestionRecoveryArchive.swift:~121`).
- **Failed journal request records are not safe to extend.**
  - `SuggestionRecoveryArchive.validateRecord` (line 250) allows only `{schema_version, request_identity, key, status, integrity, error_type}` for failed records.
  - It also requires `error_type` to be a string (line 259) and verifies the integrity digest.
  - Adding `error_message` to the request record without updating that allow-list makes recovery reject the journal as "Invalid provider record".
  - Python's own loader (`run_journal.py:80-94`) tolerates extra keys. It still requires `error_type`, so keep that field.
- **Checkpoint top-level keys are also allow-listed** in `SuggestionRecoveryArchive.swift:115-118`. Put new data inside `failed_batches[]` entries, not at the checkpoint root.
- **Exit code 1 is overloaded** between "needs_retry with JSON" and "fatal, no JSON". Swift disambiguates by whether stdout is empty.

## 2. Findings

### HIGH

**H1. Extraction batch failure keeps only the exception class name.**
- `cut_suggester/configured_run.py:210-213`:
  ```python
  except Exception as exc:
      failed_batches.append({'kind': 'extraction', ..., 'retryable': True, 'error_type': type(exc).__name__})
  ```
- Lost: the message, HTTP status, request id and retry-after. That means "credit balance is too low", 429, 401, 529, and `ExtractionError` detail all collapse to a class name.
- Reaches the app as `failed_batches[].error_type` in stdout JSON and in `checkpoint.json`. Swift ignores it and shows the fixed "Some requests failed. Resume..." string.
- Nothing is written to stderr for the failure.

**H2. The journal's failed request record keeps only `error_type`.**
- `cut_suggester/run_journal.py:201-204`:
  ```python
  except Exception as exc:
      record.update(status='failed', error_type=type(exc).__name__)
  ```
- The record also does not distinguish a provider error from a validation error. `ExtractionError`, `DiscoveryError`, `RateLimitError` and `AuthenticationError` are all just a name.
- `run_journal.py:92-93` requires `error_type` to be a string when loading.
- Reaches the app only on disk, in the recovery archive. Swift never reads `error_type` (it only checks it exists, `SuggestionRecoveryArchive.swift:259`).
- Extending this record needs the Swift allow-list change noted in section 1.

**H3. Discovery failure persists a `needs_retry` checkpoint with an empty `failed_batches`.**
- `cut_suggester/configured_run.py:163-167`:
  ```python
  except Exception:
      checkpoint('needs_retry')   # failed_batches is only ever appended in extract()
      raise
  ```
- On a stage1 partition, classify or configured-discovery failure, the checkpoint has `phase:"needs_retry"` and `failed_batches: []`. Only the opaque key is in `failed_request_keys`.
- On the live run, Swift gets the stderr line `error: ...` (which keeps the message for status errors, see M2). On later recovery from the archive, `suggestionFailureMessage([])` (`SuggestionRunWire.swift:164`) yields only the generic "Some requests failed..." text. The cause is gone.
- A second problem sits in the same block. If `checkpoint('needs_retry')` itself raises (`JournalStorageError`), it replaces the original provider error. The original survives only in `__context__`, and `main` prints `str(exc)` only.

**H4. `retryable: True` is hard-coded, and a systemic failure does not stop the loop.**
- `cut_suggester/configured_run.py:212` (inside the `for index, batch` loop at 200-220).
- Every exception is labelled retryable, including auth, credit exhausted, bad request and `ExtractionError`.
- The loop does not abort. After the first 401 or credit failure it keeps calling the provider for every remaining batch. Each call is recorded as a failed request, and the SDK adds its own retries.
- The app gets `retryable:true`, so it offers "Resume" for a failure that retrying cannot fix. Swift also ignores `retryable` except for `input_size`.

**H5. The `afconvert` stderr in the transcription decode step is discarded.**
- `logic_markers/whisperx_backend.py:38-43`:
  ```python
  subprocess.run(["afconvert", ...], check=True, capture_output=True)
  ```
- `CalledProcessError.__str__` reads `Command '[...]' returned non-zero exit status 1.` It does not include the captured `.stderr`, which holds the actual afconvert reason (unsupported or corrupt format, permissions).
- This is the first thing the `plan` path does for every file (`_aligned_segments` at line 84). The user sees only the generic status text via `error: ...`, exit 1, and `engineFailed`.
- The sibling `audio.py:29-33` handles this correctly: it uses `capture_output=True, text=True` and includes `result.stderr.strip()` in the message.

**H6. The engine's top-level handler reduces everything to `str(exc)`.**
- `logic_markers/cli.py:736-745`:
  ```python
  except Exception as exc:
      if os.environ.get("QIE_DEBUG"): traceback.print_exc(...)
      print(f"error: {exc}", file=sys.stderr); return 1
  ```
- The code's own comment says chained causes from transformers/pyannote hide behind a terse message. The app never sets `QIE_DEBUG`, so the cause chain, exception type and traceback never reach Swift or its log.
- Empty or opaque messages result. `KeyError` prints `error: 'position'`, and `struct.error`, `CalledProcessError` and `OSError` carry little context.
- The failure carries no phase, such as transcribe vs align vs convert.
- It reaches Swift as stderr text, exit 1, then `engineFailed(stderrTail)`.

**H7. The Anthropic client has no handling, so connection and TLS causes are hidden.**
- `cut_suggester/llm.py:111,127`: `client = anthropic.Anthropic()` and `client.messages.create(**create_kwargs)` have no `try/except`.
- Per the SDK, `APIConnectionError` and `APITimeoutError` stringify to `"Connection error."` and `"Request timed out."`. The real cause, such as an httpx or `ssl.SSLCertVerificationError` / `CERTIFICATE_VERIFY_FAILED`, is only in `__cause__`.
- That matters for the frozen app, whose CA wiring is best-effort (L1 below). With no wrapper and `QIE_DEBUG` unset, the app sees only "error: Connection error.", or on the extraction path just `APIConnectionError`.
- The SDK retries internally (default `max_retries=2`, honouring retry-after). Retry count and elapsed time are not reported.

### MEDIUM

**M1. The cut-suggester top-level handler keeps only `str(exc)`.**
- `cut_suggester/cli.py:287-293`, plus `:284-286` for `CacheMiss`.
- Same pattern as H6: no exception type, no `__cause__`, traceback only under `QIE_DEBUG`.
- It goes to stderr as `error: <msg>`, exit 1, and Swift shows it as `suggestFailed` or `authMissing`.
- The message is usually informative for SDK status errors (see M2), so this is medium rather than high.

**M2. Structured fields on Anthropic status errors are not extracted. Only `str(exc)` survives, and only on the hard-failure path.**
- Not extracted: `status_code`, `body["error"]["type"]` and `["message"]`, `request_id`, `response.headers["retry-after"]`.
- Present in the exception, from memory of the SDK, but not extracted anywhere in `llm.py`.
- Per the SDK, `str(APIStatusError)` is `Error code: <status> - <body dict>`. On the hard-failure path (discovery, classify, `name-clip`) it already carries the status, error type and message, and usually the request id.
- That text is classified only by the substring heuristic in `mapFailure`. The Anthropic "credit balance is too low" case is a 400 `invalid_request_error`. It matches none of the auth signals, so it becomes a generic `suggestFailed`.
- On the extraction path (H1, H2) all of it is dropped.
- A structured error would need `LLMError(status, error_type, message, request_id, retry_after, retryable)` or similar, raised from `AnthropicClient.complete`.

**M3. The OpenAI path discards the HTTP error body.**
- `cut_suggester/llm.py:76`: `urllib.request.urlopen(req, timeout=...)` is not wrapped.
- `HTTPError` stringifies to `"HTTP Error 429: Too Many Requests"`. The JSON body with `insufficient_quota`, the message and the retry-after header are never read.
- `URLError` and `TimeoutError` carry no `purpose`.
- `_provider_for` routes any `gpt-*`, `o1`, `o3` or `o4` model here, so it is reachable if the app sends such a model.

**M4. JSON-parse errors lose their detail in V2 parsers.**
- `cut_suggester/extraction.py:63-66` → `"extraction response is not valid JSON"`.
- `cut_suggester/intro_refinement.py:64-67` → `"refinement response is not JSON"`.
- `cut_suggester/configured_discovery.py:251-254` → `"configured discovery response is not JSON"`.
- Compare the V1 parsers at `cutter.py:61-67` and `:96-102`, which include `exc.msg`, `exc.pos` and a 240-character preview.
- The `from exc` chain is kept, but `str(exc)` shows none of it.
- For extraction the error is then reduced to `ExtractionError` by H1.
- Other `ExtractionError` and `IntroRefinementError` messages (`extraction.py:68-107`, `intro_refinement.py:69-97`) omit the offending candidate_id, proposal_id and field_id.

**M5. Discovery validation errors lack location.**
- `cut_suggester/configured_discovery.py:164-175`, e.g. `"clip bounds are outside the requested transcript window"` or `"clip label must be a nonblank string"`.
- They give no window start/end, no clip index and no raw clip. One bad clip in a window fails the whole window and run (`validate` returns `[_validate_clip(raw...)]`).
- They are fatal, so they go out as `error: <msg>` on stderr with exit 1.

**M6. V2 results have no diagnostics, and V1 drops the reason a clip was invalid.**
- `cut_suggester/configured_run.py:236-237` returns no `meta`. Swift shows `meta.diagnosticDescription` only when it exists (`LiveCutSuggester.swift:262-264,291-292`). A V2 run that finds zero candidates gets none.
- `cut_suggester/cutter.py:230` reads `ok, _reason = validate_clip(raw)`, and `:233-235` only increments `invalid`. The reason (unknown type, start > end, missing label) is never recorded. It reaches the app only as the `n_invalid_clips` count.
- `enforce_duration_window` dropped candidates are likewise only a count (`n_dropped_duration`, `cutter.py:253`).

**M7. WhisperX silently drops words, and an empty transcript is a success.**
- `logic_markers/whisperx_backend.py:124-128`:
  ```python
  if not text or start is None:
      continue  # alignment dropped this token; skip
  ```
- There is no count or warning, and no check that the transcript is non-empty. `run_plan` (`cli.py:409-483`) returns a plan with zero words and exit 0 for silent or no-speech audio, with no diagnostic.

**M8. A secondary exception can mask the original in `RunJournal.request`.**
- `cut_suggester/run_journal.py:201-204`: if `_save_record` raises `JournalStorageError`, it replaces the provider error.
- The original is in `__context__` only. Together with H3's `checkpoint()` call, a disk problem hides the API error.

### LOW

**L1. The frozen-bundle entry points swallow setup problems silently.**
- `packaging/cut_suggester_entry.py:33-34` (`except ModuleNotFoundError: return`) and `:36-37` (missing CA file → `return`). The result is a later "Connection error" / `CERTIFICATE_VERIFY_FAILED` with no hint (see H7).
- `packaging/engine_entry.py:28` skips silently if the bundled `nltk_data` is missing.
- Import-time failures in these wrappers bypass the CLI's `error:` handler. They surface as a raw traceback on stderr, which Swift keeps in its 40-line tail.

**L2. KeyError and struct errors become cryptic `error: <key>` lines.**
- Not on the `plan` or `inject-markers` request paths from the app, which build well-formed requests.
- `logic_markers/cli.py:504-507` (`m["position"]`, `m["name"]`), `:551` (`spec["id"]`), `:586` (`entry["path"]`), `:310` (`dict(_chunks)[b"COMM"]`).
- `logic_markers/audio.py:49,56` (`by_id[b"COMM"]`, `by_id[b"SSND"]`).
- `aiff_markers.py:30-34` and `struct.unpack` on short data give no file name.

**L3. JSON decode errors do not name the file or purpose.**
- `cut_suggester/cli.py:174-178` (`_read_request`), `logic_markers/cli.py:160,180,211,295,499,583`, and `cut_suggester/cache.py:66-68` (corrupt cache file → bare `JSONDecodeError`/`KeyError` with no path).

**L4. Usage and request identifiers are not carried.**
- `llm.py:128-136`: usage is computed and then lost if a `max_tokens` or empty-text error is raised next (`:137-146`). The message does include `stop_reason`, which is good.
- `LLMResponse` has no `request_id`.

**L5. Silent filters that only affect counts.**
- `cutter.py:74,79`: non-dict or malformed paragraphs skipped (error only if none remain).
- `cutter.py:202-212`: empty `specs` or empty `sentences` returns an empty success.
- `configured_discovery.py:266`: candidates outside 1-240 s are dropped with no trace.
- `extraction.py:127-128`: `completed_extraction_values` ignores unreadable journal responses (intentional).
- `postprocess.py` dedupe and absorb steps, and `run_journal.py:168-170` (`except OSError: pass` on temp-file cleanup, intentional).
- `transcript.py:25` skips segments with no `word_ids` (`sentences_from_dict`, used by evals; the app uses `sentences_from_units`).

**L6. `name-clip` collapses two different outcomes into one.**
- `cut_suggester/clip_naming.py:167-169`: an `intro` with null artist and null song becomes `{"type_id": null, "fields": {}}`, the same as "no type fits".
- `ClipNamingError` messages at `:130-159` carry no response preview, unlike the V1 partition parser.

**L7. `model_config.py:60-69` gives one message for any missing model dir.**
- It says "Speech models are not installed yet" for whisper, align or NLTK alike, though it does name the env var.

**L8. Exit codes are coarse.**
- 1 means both "needs_retry with JSON" and "fatal"; 2 means a missing file. Nothing distinguishes auth, network or validation failures by exit code.

**L9. Swift-side note (not a Python finding).**
- `mapFailure` passes the unfiltered stderr tail, `QIE_EVENT` JSON lines included, into the user-visible `.suggestFailed` / `.authMissing` detail (`LiveCutSuggester.swift:354,356`). The filter at `:341-343` only affects classification.

**L10. Not on the app path (not counted).**
- `logic_markers/transcribe.py:45-48` truncates the Whisper error body to 500 characters (OpenAI engine, `markers` command only).
- `logic_markers/editplan.py:155-160`: unresolvable edit lines are skipped with a warning or `continue` (`cut` command only).
- `evals/cut_suggestions/aligner.py:53,76-78,100` and `editorial_runner.py:65,83,85` have `continue` and `except (JSONDecodeError, TypeError)` paths.
- Model download is Swift-side (`LiveModelDownloader.swift`), outside this audit.

## 3. What the Anthropic SDK exposes versus what `llm.py` passes on

| Available on the exception (from memory of the SDK) | Propagated today |
|---|---|
| `APIStatusError.status_code`, `.response` (headers incl. `retry-after`), `.request_id`, `.body` (`error.type`, `error.message`) | Nothing structured. Only `str(exc)` (`Error code: N - {body}`), and only on the hard-failure path. Dropped on the extraction path (H1, H2). |
| Subclasses `BadRequestError` (400, includes credit exhausted), `AuthenticationError` (401), `PermissionDeniedError`, `RateLimitError` (429), `InternalServerError` (5xx and overloaded) | Only the class name, and only in `error_type`. |
| `APIConnectionError` and `APITimeoutError` with `__cause__` (httpx or ssl) | `"Connection error."` / `"Request timed out."` only (H7). |
| Success `msg._request_id`, `msg.usage` | Usage only, kept on success; no request id. |
| Retry behaviour (`max_retries=2`, default) | Not configured, observed or reported. |

## 4. Counts

- **High: 7** (H1 to H7)
- **Medium: 8** (M1 to M8)
- **Low: 10** (L1 to L10, of which L10 is not on the app path and L9 is Swift-side)

## 5. Key files

- `/Users/brian/conductor/workspaces/logic-utils/santiago-v3/cut_suggester/configured_run.py`
- `/Users/brian/conductor/workspaces/logic-utils/santiago-v3/cut_suggester/run_journal.py`
- `/Users/brian/conductor/workspaces/logic-utils/santiago-v3/cut_suggester/llm.py`
- `/Users/brian/conductor/workspaces/logic-utils/santiago-v3/cut_suggester/cli.py`
- `/Users/brian/conductor/workspaces/logic-utils/santiago-v3/logic_markers/cli.py`
- `/Users/brian/conductor/workspaces/logic-utils/santiago-v3/logic_markers/whisperx_backend.py`
- Swift consumers that constrain the wire change:
  - `/Users/brian/conductor/workspaces/logic-utils/santiago-v3/QuickInterviewEditor/QuickInterviewEditor/Models/SuggestionRunWire.swift`
  - `/Users/brian/conductor/workspaces/logic-utils/santiago-v3/QuickInterviewEditor/QuickInterviewEditor/Core/SuggestionRecoveryArchive.swift`
  - `/Users/brian/conductor/workspaces/logic-utils/santiago-v3/QuickInterviewEditor/QuickInterviewEditor/Core/LiveCutSuggester.swift`
  - `/Users/brian/conductor/workspaces/logic-utils/santiago-v3/QuickInterviewEditor/QuickInterviewEditor/Core/LiveEngine.swift`