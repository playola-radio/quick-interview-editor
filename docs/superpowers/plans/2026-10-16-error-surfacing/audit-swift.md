# Audit inventory: Swift app (generated 2026-10-16, read-only audit)

IDs (S*, P*, D*, Y*, E*, M*, K*) are referenced by the plan in ../2026-10-16-error-surfacing.md.

# Error-swallowing and generic-message audit: QuickInterviewEditor app sources (Swift)

Scope was `/Users/brian/conductor/workspaces/logic-utils/santiago-v3/QuickInterviewEditor/QuickInterviewEditor`, with Tests excluded. Nothing was edited or written. All paths below are relative to that root.

**Caveats**
- I read most sites in full. Some line numbers and exact strings come from the first-pass grep, and I did not re-open every file after that. These are the items marked "(grep-level)".
- Python-side generic errors are out of scope here. A separate background agent covers them.
- Entry counts at the end are per entry. An entry can cover several sites in one file.

**Format:** `ID  file:line — snippet. User sees: … Lost/available: … [severity]`

---

## 1. Subprocess boundary and cut-suggestion pipeline

**S1  Core/LiveEngine.swift:229-231**
- Snippet: `throw EngineClientError.engineFailed(proc.stderrTail() + logHint(logURL))`.
- User sees: the last 40 stderr lines, which include raw `QIE_EVENT` JSON lines, plus a log hint.
- Lost/available: the exit code is omitted, even though `SpawnedProcess` computes it (128+signal for crashes). A process killed by a signal with empty stderr gives a message with no cause. [M]

**S2  Core/LiveEngine.swift:373-374**
- Snippet: same pattern, `injectFailed`.
- Lost/available: same as S1. [M]

**S3  Core/LiveEngine.swift:141**
- Snippet: `guard (try? body.write(...)) != nil else { return nil }`.
- Effect: if the per-run job log cannot be written, there is no log. The "see log" hint is then silently absent, and nothing says why. [L]

**S4  Core/LiveEngine.swift:38**
- Snippet: `try? ModelLocations.installation()`.
- Effect: falls back to offline-only mode with no indication that the model install lookup failed. [L]

**S5  Core/LiveEngine.swift:97**
- Snippet: `(try? contentsOfDirectory) ?? []`. [L]

**S6  Core/LiveEngine.swift:878**
- Effect: `waitpid` ECHILD becomes exit code -1 with no explanation. [L]

**S7  Core/EngineEvent.swift:76-95**
- `EngineClientError` is a LocalizedError whose cases carry only a pre-flattened string. Callers cannot distinguish the cause or recover the exit code. [M]

**S8  Core/LiveCutSuggester.swift:336-357 (`mapFailure`)**
- Snippet: raw stderr is passed into `.authMissing(...)` / `.suggestFailed(...)`.
- User sees: stderr text including interleaved `QIE_EVENT` JSON noise.
- Lost/available: no exit code and no job-log path. The structured `QIE_EVENT` failure record already exists but is not parsed here. The message is often unreadable or empty. [H]

**S9  Core/LiveCutSuggester.swift:263**
- Snippet: `"The helper returned no result JSON."`.
- User sees: a fixed string.
- Lost/available: exit code, stderr tail and log path are all available and unused. [H]

**S10  Core/LiveCutSuggester.swift:252-298**
- With a snapshot and non-empty stdout, the code decodes before checking the exit code. `.recoverableFailure` ignores stderr entirely.
- Effect: a crash after partial output can be reported as a decode problem, or as a retry prompt with no reason. [M]

**S11  Core/LiveCutSuggester.swift:204-211 (clip naming)**
- Snippet: decode error mapped via `localizedDescription`.
- Lost/available: no output preview and no key path, unlike the main decode path, which has both. [M]

**S12  Core/LiveCutSuggester.swift:280, 416**
- Generic `decodeFailed("...")` strings. The underlying `DecodingError` is not included. [M]

**S13  Core/CutSuggestClient.swift:84-121**
- `CutSuggestClientError` descriptions wrap bare strings. No error category, exit code or request id is carried. [M]

**S14  Models/SuggestionRunWire.swift:188-195 (`suggestionFailureMessage`)**
- Snippet: `"Some requests failed. Resume to retry the unfinished requests."`.
- User sees: that fixed text.
- Lost/available: the Python checkpoint records per-provider failures with `error_type`, and `requestKey` is decoded. Neither is used. Auth, rate-limit, network and schema failures all look identical. [H]

**S15  Models/SuggestionRunWire.swift:178-186**
- `SuggestionRunWireFailure` decodes only `kind`, `requestKey` and `retryable`. Any message or detail the wire carries is dropped at decode. This is the root cause of S14. [M]

**S16  Models/SuggestionRunWire.swift:31, 37**
- Candidate-level errors carry no candidate id or index. [M]

**S17  Views/Pages/CutSuggestions/SuggestionRunModel.swift:414**
- Snippet: `"The cut-suggester stopped before returning results."`.
- User sees: that text, with no cause.
- Lost/available: exit code, stderr and log path. [H]

**S18  Views/Pages/CutSuggestions/SuggestionRunModel.swift:170-171, 217, 525-527, 578**
- Snippet: `.failed(message: error.localizedDescription)`.
- Effect: quality depends on the error type. Non-LocalizedError types (see S30) produce "The operation couldn't be completed. (… error 1.)". [M]

**S19  Views/Pages/CutSuggestions/SuggestionRunModel.swift:401, 535, 540**
- Snippet: `failureMessage ?? message`.
- Effect: falls back to the generic S14 message whenever the specific one is absent. [M]

**S20  Core/SuggestionRecoveryArchive.swift:52-317**
- Many `SuggestionRecoveryError.invalid("...")` constants. They do not say which field or record was bad, or its value. [M]

**S21  Core/SuggestionRecoveryArchive.swift:250-260**
- Failed provider records carry `error_type`. It is validated but never surfaced to any user message or log. [M]

**S22  Core/SuggestionRecoveryClient.swift:31-52**
- `SuggestionRecoveryError` descriptions are mostly constant text. [L]

**S23  Core/SuggestionRecoveryStore.swift:153-154**
- Snippet: `try? Data(contentsOf: .../project.json)` and `try? ...decode(ProjectFile...)`, with `else { throw .notSaved }`.
- Effect: an unreadable file, a decode failure and an owner/run mismatch all become the same `notSaved`. [M]

**S24  Views/Pages/Editor/EditorModel+ManualClipNaming.swift:122, 144, 152, 165**
- Snippet: `try? keychain.load()`, `try? await suggestionConfiguration.load()`, `try? await cutSuggest.nameClip(...)`, each followed by `else { return }`.
- User sees: nothing. Auto-naming simply never happens.
- Lost/available: auth, config and network errors are all swallowed. They should at least be logged. [L]

**S25  Models/SuggestionRun.swift:104**
- `SuggestionRunValidationError` has two generic messages ("saved naming details are invalid") with no candidate or type id, though the cases carry ids. (Grep-level for lines 90 and 109.) [M]

**S26  Models/CutSuggestionPresentation.swift:177-180 (`cutSuggestionInvalidMessage`)**
- Five `InvalidReason` cases are collapsed to "couldn't be turned into a clip … Try regenerating." The reason is not shown. [M]

**S27  Models/SuggestionDocumentMutation.swift:56**
- `"This suggestion is unavailable."` [L]

**S28  Views/Pages/CutSuggestions/SuggestionReviewModel.swift:244, 255, 285**
- `reviewErrorMessage` falls through to `error.localizedDescription` (see S30). [L]

**S29  Views/Pages/CutSuggestions/SuggestionReviewModel.swift:116, 121, 125, 174, 259, 266, 269**
- `try? suggestionReviewChange / parseSuggestionStartingNumber / suggestionForAcceptance` used for button enablement and previews. This is acceptable UI gating; the real error surfaces on apply. [L]

**S30  Core/SuggestionConfigurationClient.swift:6**
- A non-LocalizedError type is shown via `localizedDescription`, which yields the "operation couldn't be completed" string in SuggestionSettingsModel and CutSuggestionsPageModel. Lines 112 and 116 use `reportIssue` only, in unconfigured test paths. [M]

**S31  Views/Pages/SuggestionSettings/SuggestionSettingsModel.swift:248-251, 371-372, 319**
- "Could not load/save rules … \(error.localizedDescription)" does include the cause. Line 319, "This preset is unavailable.", does not. [L]

**S32  Views/Pages/CutSuggestions/CutSuggestionsPageModel.swift:394-395, 423, 436**
- Messages include the cause, subject to S30. [L]

**S33  Views/Pages/CutSuggestions/CutSuggestionsPageModel.swift:604**
- Snippet: `keychain: (try? keychain.load()) ?? nil`.
- Effect: a Keychain failure is treated as "no key". The user then gets an auth-missing message that misdirects them. [M]

**S34  Views/Pages/Editor/EditorModel+DraftEditing.swift:38-39, 78-79, 118-120**
- Plain `localizedDescription` passthrough. [L]

---

## 2. Project import, transcription and launch

**P1  Views/Pages/Project/ProjectModel.swift:277**
- Snippet: `reportIssue("Audio import failed: ...")` is the only handling.
- User sees: nothing. `reportIssue` is dev/test only.
- Lost/available: the full error is available. [H]

**P2  ProjectModel.swift:445-450**
- Snippet: `try? resourceValues` → `missingCanonicalAudioMessage`.
- Lost/available: the file error (permission, missing, I/O) is dropped and replaced by a fixed message. [M]

**P3  ProjectModel.swift:466-468**
- `uncomputableFingerprintMessage` is a fixed message. The underlying read error is lost (see P6). [M]

**P4  ProjectModel.swift:610**
- Snippet: `catch { return }` in `savedProjectObserved`. A silent bail with no log. [L]

**P5  ProjectModel.swift:415, 555, 750-753, 791, 807-813**
- `error.localizedDescription` into UI state. Quality depends on the error type. [M]

**P6  Core/SourceFingerprint.swift:19-23**
- Snippet: `try? Data(contentsOf:)`, falling back to a `path:` fingerprint.
- Effect: a read failure silently changes the identity scheme, which can cause later false "changed" results. [L]

**P7  Core/TranscriptionClient.swift:57, 76**
- `try?` on the canonical store and the cache store. Failures are silent and the code falls back to recomputing. [L]

**P8  Core/TranscriptCache.swift:33, 52-57, 69, 80, 91-93, 109, 139**
- Cache read, write and prune `try?`. A cache failure is silent. This is probably fine, but it should log. [L]

**P9  Views/Pages/AppLaunch/AppLaunchModel.swift:44**
- Snippet: `try? TranscriptCache.baseDirectory()`. [L]

**P10  Core/EngineFingerprint.swift:95, 116, 118**
- Snippet: `try? Data(contentsOf:)` returns nil, and resource-value reads default to 0.
- Effect: the fingerprint is silently weaker. [L]

**P11  Core/AppDirectories.swift:30, 37, 66, 73, 89, 93, 105**
- Legacy folder migration is entirely `try?`. A failed move leaves data behind with no signal. [L]

Core/TranscriptionQueueClient.swift forwards errors unchanged, so there is no finding there. Core/CanonicalAudioStore.swift has only benign cleanup.

---

## 3. Model download and setup

**D1  Core/LiveModelDownloader.swift:230-237, 250**
- Snippet: `catch { deliveredURL = nil }`, later `URLError(.cannotWriteToFile)`.
- Lost/available: the move/copy error (disk full, permission, path) is replaced by a generic URLError. [M]

**D2  Core/LiveModelDownloader.swift:129-136**
- Only `lastError` is kept across retries, so earlier distinct failures are lost. [M]

**D3  Core/LiveModelDownloader.swift:19-20, 59, 145**
- Assorted `try?` and fallbacks. (Grep-level.) [L]

**D4  Core/ModelDownloadClient.swift:76-87**
- `errorDescription` drops expected and actual hashes and the URL. A checksum failure says only that it failed. [M]

**D5  Views/Pages/ModelSetup/ModelSetupModel.swift:139-143**
- Error mapped to a UI string, relying on D4's text. [M]

**D6  Models/ModelManifest.swift:85-135 (`ModelLocations`)**
- Lookup failures are swallowed by callers, as in S4. [L]

---

## 4. Settings, Keychain and install location

**Y1  Views/Pages/Settings/SettingsModel.swift:82**
- Snippet: generic "Could not save … Please try again." plus `reportIssue(error)`.
- Lost/available: the Keychain `OSStatus` is dropped from the user message. [H]

**Y2  SettingsModel.swift:95**
- Same pattern for remove. [H]

**Y3  SettingsModel.swift:106**
- Same pattern for clear. [H]

**Y4  SettingsModel.swift:113**
- Snippet: `try? keychain.load()`. A Keychain error is shown as "no key saved". [M]

**Y5  Core/KeychainClient.swift:127-135**
- `KeychainError.unexpectedStatus(OSStatus)` surfaces a raw number or generic text. It has no `SecCopyErrorMessageString` mapping. [M]

**Y6  Core/InstallLocation.swift:95-100, 120-129**
- Snippet: `NSLog(...)`, then `presentMoveFailed()` with the text "Couldn't move to the Applications folder … drag it into Applications".
- User sees: a fixed alert.
- Lost/available: the move error (permission, volume, existing copy) appears only in NSLog. [H]

**Y7  Core/InstallLocation.swift:110-113**
- The relaunch failure is only `NSLog`'d. The user sees nothing, and the app just fails to relaunch. [H]

---

## 5. Editor, export, playback and waveform

**E1  Views/Pages/Editor/EditorModel.swift:4157-4159, 4177-4180**
- Snippet: `exportPhase = .failed(error.localizedDescription)`.
- Effect: depends on the error type. No slice or clip identity is attached. [M]

**E2  EditorModel.swift:4292**
- Snippet: "Rendered X of Y slices."
- Effect: on failure the progress string does not say which slice or why. [M]

**E3  EditorModel.swift:3485-3487**
- Snippet: playback failure is `reportIssue(error)` only.
- User sees: nothing. [H]

**E4  EditorModel.swift:2333-2334, 611, 1380, 4149**
- Silent `try?` or `reportIssue` sites that I did not fully re-verify. (Grep-level.) [L]

**E5  Core/ExportRenderClient.swift:88-110**
- Some `errorDescription` cases are generic. `bufferAllocationFailed` has no sizes or context. [M]

**E6  Core/ExportCopyClient.swift:70, 89**
- Snippet: `"A rendered clip is missing. Export again."`.
- Lost/available: the clip name or index and the underlying file error. [M]

**E7  Views/Pages/Editor/WaveformModel.swift:214-217**
- Snippet: `catch { reportIssue(error) }`. The waveform silently fails to render. [M]

**E8  Core/WaveformClient.swift:113-117, 177-282**
- `WaveformClientError` is not a LocalizedError, so `localizedDescription` gives "The operation couldn't be completed". [M]

**E9  Core/AudioPlayerClient.swift:625-626**
- `engine.start()` failure goes to `reportIssue`. Playback fails with no user signal. [H]

Benign `try?` in ExportRenderClient.swift (lines 48, 147) and ExportReviewModel is cleanup only. Both are listed in section 9.

---

## 6. Mastering

**M1  Views/Pages/Mastering/MasteringPageModel.swift:20 (`MasteringArtifactValidationClient`), 150-151, 364, 662**
- Snippet: `try? AVAudioFile(forReading:)` and a failed `AudioFileOpenURL` both throw payload-less `MasteringArtifactError.corrupt`.
- User sees: "A saved mastering file is damaged or has the wrong audio format. Prepare or return that part again."
- Lost/available: whether the file was unreadable, had the wrong frame count, wrong sample rate or wrong channel count. The part name is also not shown. [M]

**M2  Core/Mastering/LoudnessMeter.swift:18, 25, 40, 54, 59, 65, 71, 78; LoudnessClient.swift:38**
- `MasteringPreparationError.meterUnavailable` is thrown from 9 sites.
- User sees: "The loudness meter could not start."
- Lost/available: the site and the underlying cause are indistinguishable. [M]

**M3  Core/Mastering/MasteringConformer.swift:27, 81, 87, 115; MasteringAudioClient.swift:132, 148, 243, 252**
- `conversionFailed("…")` with constants ("Could not initialize converter", "Converter stopped before consuming input", "Prepared WAV is empty").
- Lost/available: the `AVAudioConverterStatus` and the piece or part identity. [M]

**M4  MasteringConformer.swift:127; LoudnessMeter.swift:46; LoudnessClient.swift:15**
- `invalidLoudnessMeasurement`: "The audio loudness measurement was invalid."
- Lost/available: which sample, channel or part. [M]

**M5  MasteringPageModel.swift:~305**
- Snippet: `"The project changed while preparing; prepare again."`.
- Lost/available: `host.commit` returns a Bool with no reason. [M]

**M6  MasteringPageModel.swift:365, 401, 572, 666**
- "Could not stage / retain / create destination: \(error.localizedDescription)". These include the cause but use a generic prefix. [L]

**M7  MasteringPageModel.swift:319, 458, 547**
- `message = error.localizedDescription` passthrough. [L]

**M8  Core/Mastering/MasteringReturnClient.swift:143, 219-220, 243**
- Snippet: `try? AVAudioFile(...)`, and `catch { throw unreadable(fileName:) }`.
- User sees: "X is not readable audio."
- Lost/available: the underlying AVFoundation error (permission, unsupported, truncated, I/O). [M]

**M9  MasteringReturnClient.swift:165, 190-192, 254-264**
- `encodeFailed(reason:)` is built from `localizedDescription` or a constant. The duration-changed message (165) has no values. [L]

**M10  MasteringReturnClient.swift:98, 102**
- `unreadable(fileName: "")` in the unconfigured path gives " is not readable audio." with an empty name. [L]

**M11  Core/Mastering/MasteringAACEncoder.swift:26, 34, 45, 48, 55, 60, 71, 80**
- Constants: "AAC writer rejected its input", "Could not start AAC writer", "Could not allocate audio buffer", "Conformed source ended during encoding", "AAC writer did not finish", "Could not read AAC output size".
- Lost/available: `writer.error` is used on some paths with a constant fallback, but the other paths have no cause. [M]

**M12  MasteringAACEncoder.swift:108, 125, 132**
- Raw `OSStatus` ints in the text, with no symbolic name. [L]

**M13  Core/MasteringStaging.swift:58, 64, 67**
- `CocoaError(.fileWriteInvalidFileName)` and `CocoaError(.fileWriteUnknown)`.
- Lost/available: `errno` from `open()` is not captured. [M]

**M14  Core/MasteringStaging.swift:88, 98-105, 115**
- Garbage-collection `try?` on stale staging directories. It is silent and should log. [L]

**M15  MasteringAudioClient.swift:~110 (`truePeakCeilingExceeded`)**
- The `errorDescription` drops the measured dBTP. The page model's special case (MasteringPageModel.swift:315) re-adds it, but only on that path. [L]

**M16  MasteringAudioClient.swift:75-76; LoudnessClient.swift:37-38; MasteringReturnClient.swift:97-102**
- `reportIssue` and then a misleading domain error when no live or test client is installed. This is dev-only. [L]

**M17  MasteringConformer.swift:72, 106**
- The `NSError` from `AVAudioConverter` is flattened to `localizedDescription` inside `conversionFailed`. [L]

---

## 7. Document package (.pie) and persistence

**K1  Core/ProjectPackage.swift:102, 106, 122**
- Snippet: `try JSONDecoder().decode(SchemaProbe/ProjectFile/EditPlan...)`.
- User sees: Foundation's `DecodingError` text (for example "The data couldn't be read because it is missing") in the open alert.
- Lost/available: which file (`project.json` or `plan.json`) failed, and the key path. [M]

**K2  ProjectPackage.swift:23, 369-376; Documents/ProjectDocument.swift:320**
- Snippet: `try? resourceValues` → `ProjectPackageError.audioMismatch`.
- User sees: "The project's bundled audio does not match the project."
- Lost/available: the expected vs actual byte count, the fingerprint, and the read error. [M]

**K3  Documents/ProjectDocument.swift:~50-54 (`missingPackageAudio`)**
- "The project's audio could not be found. Reopen the project and try again." The path and cause are missing. [M]

**K4  ProjectPackage.swift:313**
- Snippet: `try? FileWrapper(url: artifact.url, ...)` → `MasteringReconcileError.missingArtifact(name)`.
- Lost/available: missing vs permission vs I/O error. [M]

**K5  ProjectDocument.swift:194, 200, 222**
- Snippet: `staged[name] = try? stageMasteringWrapper(...)`.
- Effect: a staging failure is silently dropped. It later surfaces as K4's `missingArtifact` or as silently omitted mastering media. [M]

**K6  Models/ProjectFile.swift:33**
- Snippet: `(try? container.decodeIfPresent(MasteringRun.self, ...)) ?? nil`.
- Effect: the manifest decode error is discarded. Only the `masteringManifestCorrupt` Bool survives, with no message. [M]

**K7  ProjectDocument.swift:~391**
- `reportIssue("First commit to an empty project must carry a plan and audio")` is a developer-only assertion. [L]

**K8  Models/EditPlan.swift:105; Models/TimelineRemoval.swift:40**
- Lenient `try?` decodes that silently default. [L]

Positive notes: the `ProjectPackageError` messages for missing project.json, plan.json and audio, and for an unsupported schema, are specific. `CutSuggestionWire` decode errors include a preview.

---

## 8. Alert and dialog audit

- NSAlert is used only in Core/InstallLocation.swift, at lines 62 ("Move to the Applications folder?", a prompt rather than an error) and 122. The line 122 alert is Y6.
- The `.confirmationDialog` calls in MasteringPageView.swift:91 and CutSuggestionsPageView.swift:106 are confirmations, not error surfaces.
- No `PlayolaAlert` usage exists in this app. Errors surface as inline `message`, `statusMessage`, `actionMessage` or phase strings.

---

## 9. Benign cleanup `try?` (no action needed)

These are temp-file or best-effort removals and moves where failure does not matter:
- Core/MasteringStaging.swift:15, 82, 91
- Core/Mastering/MasteringAACEncoder.swift:85
- Core/Mastering/MasteringReturnClient.swift:82, 171, 188
- Core/ExportRenderClient.swift:48, 147
- Views/Pages/Editor/ExportReviewModel.swift (cleanup sites)
- Core/CanonicalAudioStore.swift (cleanup sites)
- Core/SuggestionRecoveryStore.swift:411
- Core/AppDirectories.swift:106 (removing an empty legacy directory)

---

## 10. Counts by severity

| Severity | Entries |
|---|---|
| High | 12 |
| Medium | 47 |
| Low | 33 |
| Total | 92 |

- **High (12):** S8, S9, S14, S17, P1, Y1, Y2, Y3, Y6, Y7, E3, E9.
- **Medium (47):**
  - Section 1: S1, S2, S7, S10-S13, S15, S16, S18-S21, S23, S25, S26, S30, S33.
  - Section 2: P2, P3, P5.
  - Section 3: D1, D2, D4, D5.
  - Section 4: Y4, Y5.
  - Section 5: E1, E2, E5-E8.
  - Section 6: M1-M5, M8, M11, M13.
  - Section 7: K1-K6.
- **Low (33):**
  - Section 1: S3-S6, S22, S24, S27-S29, S31, S32, S34.
  - Section 2: P4, P6-P11.
  - Section 3: D3, D6.
  - Section 5: E4.
  - Section 6: M6, M7, M9, M10, M12, M14-M17.
  - Section 7: K7, K8.

**Biggest wins**
- Fix S8, S9, S14 and S17 together: they are the same missing link between the subprocess exit/stderr/`error_type` data and the user message.
- Fix Y1-Y3 (generic Settings messages) and Y6/Y7 (install-location alert and relaunch failure).
- Fix P1, E3 and E9, where a user-visible failure is routed only to `reportIssue`.