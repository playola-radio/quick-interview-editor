# Prepare for Mastering

Status: approved by Brian on 2026-09-28. Includes the intro-only scope and the audio, eligibility, and saved-project defaults reviewed together. Proceed to implementation planning and multi-PR handoffs.

## Outcome and scope

Add an in-editor mastering workflow **for intros**: prepare combined WAVs, hand them to Masterchannel, accept the masters, split them, and save tagged m4a files. **Prepare for Mastering** is the primary action.

Spotlights keep their existing **Export → Logic → PlayolaAudioProcessor** workflow. Preserve the current AIFF export, Logic word markers, and filename review. Export remains available as a secondary action for all slices. Do not replace it with WAV-only export or retire the Python marker code. No changes to PlayolaAudioProcessor are included; retiring it is a future feature.

The intro workflow ends at local files. Direct upload to Playola is a later feature. Matching Playola's codec settings does not bypass its current upload normalizer, and preservation of embedded lyrics through a future server upload is not promised here.

## Confirmed product decisions

| Requirement | Decision |
| --- | --- |
| Primary action | **Prepare for Mastering** |
| Secondary action | Keep existing **Export**, including AIFF and Logic word markers |
| Source | Intro slices, including existing removals, crossfades, and declick fades |
| Boundaries | Preserve the editor's exact slice boundaries; no automatic silence trimming |
| Joining | Concatenate end to end; no inserted gaps |
| Intermediate format | Uncompressed WAV, 44,100 Hz, stereo |
| Final format | m4a container, AAC configured for 256,000 bps, 44,100 Hz, stereo |
| Mastering site | `https://masterchannel.ai/studio` |
| Handoff UI | Open-site button, draggable combined WAVs, drop target for mastered returns |
| Parts | Retain the existing nominal 50-minute limit, packing whole slices into parts |
| Alignment | Carry forward the existing assumption that mastering preserves audio timing; no automatic offset correction or time-stretch alignment |
| Artist tag | The interview artist's name, on every final file |
| Title tag | The generated title for the piece |
| Filename | `<generated title>.m4a`; no artist prefix |
| Destination | Always ask; default to `mastered/` beside the saved `.pie` project |
| Word mapping | Embedded in each final m4a; no sidecar and no mastered transcript view |
| Word format preference | Use an established format and existing parsers rather than inventing a JSON schema |
| Upload | Out of scope |

Preserve the existing app's intended chunking behavior: a slice that would take a nonempty part over 3,000 seconds starts the next part. A single slice longer than the limit remains intact in its own part with a warning. Never produce an empty trailing part. The limit is carried forward from the processor, not asserted to be Masterchannel's current published limit.

## Approved audio defaults

Brian leaned toward retaining normalization and asked for a recommendation. The approved policy is per-slice loudness matching toward **−16 LUFS**, using constant gain only. Retain the existing **−1.5 dBTP** ceiling; if the required gain would exceed it, use less gain and accept a quieter piece. Do not compress or limit merely to meet the target, and do not silently fall back to dynamic loudness processing. Leave dynamics processing to Masterchannel. Do not normalize again after mastering.

This intentionally differs from the old processor's `loudnorm ... linear=true`: FFmpeg can fall back to dynamic mode when its linear conditions are unmet. The approved change preserves dynamics while reducing level differences between pieces.

Retain **24-bit PCM** for WAV as the approved default. Playola's AAC settings establish sample rate, channels, and bitrate; they do not specify a PCM bit depth. Do not introduce a format picker for mastering.

Existing Export continues rendering the edited slices in its current AIFF format with Logic markers. The new mastering-preparation loudness and WAV settings apply only to the intro mastering path.

## Embedded text and metadata

Use plain **LRC text in the MP4/iTunes `©lyr` field**, one word per timestamped line:

```text
[00:01.23]Hello
[00:01.61]world
```

LRC is a de facto timed-lyrics convention. The lyrics atom itself is a text field; this is not an ISO-standard synchronized-lyrics atom. Existing lyrics-aware parsers understand it without a Playola-specific schema. Generic tag readers can retrieve the text even if they do not interpret the timestamps. Do not promise synchronized display in every music player.

Use centisecond timestamps relative to the final piece's playback timeline. Keep integer sample positions through editing, resampling, joining, and splitting; round to centiseconds only when serializing LRC. Preserve spoken order when several words round to the same timestamp. Store **word starts only**; LRC does not represent explicit word ends. This matches the existing marker data, and avoids inventing end times or gap rules.

Reuse the slice-local edited-timeline mapping and current tie-nudge. Words whose starts were removed or lie outside the slice are omitted under the existing policy. Metadata generation must use the same frozen slice snapshot and offsets used for audio preparation and splitting. Do not add AAC encoder priming to the timestamps.

Write ordinary Artist (`©ART`) and Title (`©nam`) tags. Do not add album, artwork, comment, or custom metadata fields. Filename sanitization and collision suffixes must not change the Title tag.

### Spike evidence

Two AVFoundation-written m4a fixtures containing 5 and 5,000 timestamped entries passed:

- Exact lyrics text readback through AVFoundation and ffprobe.
- Unmodified `music-metadata` recovered every word and its timestamp.
- Artist and Title read back unchanged.
- The 5,000-entry Unicode fixture occupied 138,890 UTF-8 bytes.

The large fixture tested metadata transport, not alignment: its timestamps exceed the short synthetic audio's duration. Earlier custom JSON tag attempts were omitted by the tested writer, while JSON in `©lyr` survived; that JSON approach was superseded by LRC to follow Brian's preference for an established format.

A separate timing follow-up used AVAudioConverter to resample a two-second 48 kHz source to exactly 88,200 frames before AAC encoding, then explicitly ended the writer session at the intended duration. AVAudioFile read exactly 88,200 frames and AVURLAsset reported 2.0 seconds. Five impulse peaks matched their expected 44.1 kHz positions exactly in both AVAudioFile and ffmpeg decoding. This resolves the first spike's resampling loss and one-frame shift for that fixture.

Some readers still expose trailing AAC padding: ffmpeg produced 89,024 raw decoded frames, and ffprobe/music-metadata reported the encoded track duration rather than the 2.0-second gapless playback duration. Word starts matched in both decoders. Production tests must distinguish playback duration from raw AAC packet duration and cover varied lengths, rates, and real speech. No synthetic test proves what Masterchannel does to timing.

Reproduction artifacts in this workspace: `.context/mastering-spike/lrc/` and `.context/mastering-spike/timing/`. These are disposable experiments, not production code or a portable dependency of the implementation plan. The plan must carry the relevant fixture recipes and assertions forward.

## Eligibility and user flow

The eligibility rule is every currently exportable slice with the built-in type ID `intro`, in the order shown by the editor. Resolve explicit `suggestionTypeID` first, then `suggestionNaming.typeID` when the explicit field is missing. Where both are missing, use a surviving accepted suggestion with the same slice identity as a legacy provenance fallback; preserve that backfill before retranscription drops old suggestions. Existing explicit IDs take precedence over legacy data. Do not classify from title text or group labels.

A renamed or resized intro stays an intro; a spotlight renamed to include “Intro” does not become one. The built-in type's ID remains authoritative even when its display name or guidelines change. A custom type placed in the Song Intros group is not automatically included. Unknown/custom types and untyped manual slices remain exportable but are excluded from this new path. This is the approved conservative default; no new classification editor is included. `editingComplete` does not add a gate beyond current exportability. An eligible slice with a blank/whitespace title must be named before preparation so its file and required Title tag have a meaningful value.

1. **Prepare for Mastering** opens a dedicated mastering sheet. Its model owns the flow; it is not another large section of `EditorModel`.
2. Show the eligible intro count and which slices are excluded. Reuse the existing pending-edit and invalid-timeline guards. Fully removed slices are skipped and reported as in current Export. With no eligible intros, explain why preparation is unavailable.
3. Require the project to be saved and the interview artist field to be nonempty before starting. These defaults ensure saving gives the run a durable home and the artist is required in every final file. Finish any pending title edit before taking the snapshot.
4. Prepare the parts and show progress/cancel. The old prepared run, if any, remains usable until the replacement finishes. Starting over with a completed prepared run requires confirmation because it replaces the run's files.
5. Show **Open Masterchannel**, one draggable WAV row per part, and one drop target accepting one or more mastered files. Rows show each part's duration and whether its return is still needed. Reopening the sheet or project restores the prepared run.
6. As each master arrives, validate it, split it and encode that part's final m4as. Commit a part only after all of its final files succeed. Failed parts remain retryable without repeating completed parts.
7. When all parts are ready, ask where to save them. Default to `mastered/` beside the current `.pie` location. If that folder does not exist, offer it as the default and create it only when the destination is accepted. Cancelling the chooser keeps the final files ready for a later save.
8. Copy the finished files to the chosen destination, preserving the existing collision-review/no-overwrite behavior. Show completion and **Show in Finder**. Finished files remain available in the project for saving again.

A prepared run is immutable with respect to editor changes. Freeze the artist, titles, rendered audio, slice offsets, and LRC text together. Editing, renaming, deleting a slice, undoing, or retranscribing later does not rewrite or delete that run. Show a notice when relevant current inputs differ; **Prepare Again** includes those changes. This version stores one run, not a run history.

## Preparation and return processing

### Preparation

Use the existing slice-local render plan and shared pure audio rendering primitives through a dedicated mastering render path. Preserve the existing ExportRenderClient contract and AIFF/marker defaults; do not route preparation through the engine export CLI. Preserve the current sample-exact removal, crossfade, and declick behavior. Do not render a new set of fades at internal edits or trim silence.

For preparation, convert rendered audio to 44.1 kHz stereo as needed; mono is duplicated into left and right. Perform measurement after channel conversion so the meter sees the same stereo signal that will be written. Keep intermediate processing in floating point; quantize to 24-bit PCM when writing the WAV. Channels beyond mono/stereo are rejected with a clear message rather than silently downmixed.

Use an established loudness meter: the recommended implementation is a pinned, vendored build of **libebur128** behind a `LoudnessClient`. It supplies integrated loudness and true-peak measurement; do not implement BS.1770 from scratch. Package its source and licence with the app's build. A Homebrew ffmpeg can serve as an independent test reference but is not a runtime dependency.

Given measured integrated loudness `L` and true peak `P`, the fixed gain in dB is `min(-16 - L, -1.5 - P)`. For silence or an unmeasurably short clip, do not amplify it toward an undefined loudness; use unity gain unless attenuation is needed to meet the peak ceiling. No compressor, limiter, or silence-removal stage is added. Recheck the final prepared audio's peak ceiling within the meter's documented tolerance.

Append the prepared pieces without gaps. Maintain one authoritative integer frame count for each actual written piece. Its part offset is the sum of preceding written piece lengths. Derive final word starts from the same slice-local mapping and sample-rate conversion. No separate time-seeking offsets, loose CSV, or guessed durations.

### Returned masters

Keep the existing lossless return formats: WAV, AIFF, and FLAC. Decode and inspect the actual audio, not only the extension. Conform the whole return to 44.1 kHz stereo once before slicing, flushing the converter. Do not apply another loudness pass.

Use the processor's **strictly less than five seconds** duration tolerance against unreturned parts. With exactly one candidate, assign it automatically. With several candidates, show those part names and durations for the user to choose; do not silently choose between similarly sized parts. With none, show the mismatch and keep the run intact. An already completed part is not silently replaced by a duplicate drop; the user can explicitly retry/replace that part, and its current files stay until the replacement succeeds.

Before encoding, every saved slice range must exist in the conformed audio. A file shorter than the last required frame is rejected; never silently shorten or pad the user's slices. Extra trailing audio beyond the saved part length is not included in any final piece. There is no leading-silence detection, correlation, time stretching, or offset adjustment. The duration tolerance is a part-matching aid and does not prove alignment; this follows the user's working experience with the processor.

Cut by the saved sample ranges. Encode each final piece once with AVFoundation's AAC writer, configured for 256 kbps, 44.1 kHz, stereo. Establish the piece's intended presentation duration explicitly. Use its frozen Artist, Title, and LRC metadata. Keep all pre-encode stages lossless. AAC padding handling follows the playback-timeline contract described in the spike evidence, not raw packet counts.

## Durable run and file ownership

### Choice of approach

- **Recommended: project-owned prepared WAVs and final m4as.** The run survives closing, moving, duplicating, and reopening the `.pie`. It costs package disk space but avoids another durable storage system or a regeneration subsystem.
- **Manifest plus rebuildable cache.** Smaller project, but regeneration must reproduce the exact uploaded audio across edits and software versions; returned-part progress also needs durable storage. This is extra machinery for this workflow.
- **Memory-only state like the processor.** Simplest initially, but closing the document loses the handoff state. It does not meet the resume requirement.

Add an optional mastering run to `ProjectFile`, alongside its undoable `content`. `ProjectModel` remains the owner that commits through `ProjectDocumentSink`; `ProjectDocument`/`ProjectPackage` remain the only writers of the `.pie` tree. Do not have a background audio task modify the live package directory.

The durable manifest contains only values needed to resume or export:

- Run identity, frozen artist, and a deterministic digest of the preparation inputs for the stale-run notice.
- Per part: identity, prepared WAV reference, frame count, and byte count.
- Per piece: identity, frozen title, start and length in part-relative 44.1 kHz frames, frozen LRC text, and its finished m4a reference/byte count once available.

The preparation digest includes the canonical source identity, ordered eligible slice identities/ranges/titles/type provenance, applicable removals, transcript word starts/text, and artist. Use canonical stable serialization, not Swift's randomized `Hasher`. It exists only to detect that current inputs differ; it does not drive cache regeneration or audio alignment. Ignore unrelated spotlight-only naming changes.

Store prepared WAVs and completed m4as under a package-owned `mastering/` child. Internal file names use identities rather than user titles, so duplicate titles cannot collide inside the package. Relative references must resolve to the owned regular files; do not follow arbitrary paths outside the run.

The returned master itself is transient: read it from the dropped location while splitting/encoding, then commit the finished part. On failure or cancellation, that part stays as it was and the user can drop the file again. Previously completed parts remain available across relaunch. Do not retain a second full copy of every mastered WAV after its final pieces are committed.

### Saving and lifecycle

Build artifacts in session staging outside the package. Commit complete values and immutable artifact references together, then let the document system save them. A partial file must never appear in a saved ready/finished run. Busy progress and tasks are memory-only; reopening reflects the last committed prepared/finished artifacts.

Follow the existing canonical-audio wrapper model: reuse unchanged file wrappers on ordinary saves and lazily wrap completed session files. Explicitly reconcile `mastering/` when a run or part changes; checking only the run ID is insufficient because returning a part adds files to that same run. Replacing a run removes the old run's children without disturbing canonical audio or suggestion recovery files.

Save As and Duplicate must carry all referenced artifacts, including files not yet saved at the old location. Keep source artifacts alive until outstanding snapshots have finished using them. Use clones where available, ordinary copies otherwise; do not assume every volume provides APFS cloning. Do not require opening the mastering sheet before Save As can work.

Expose session-owned copies for dragging, not paths inside the live package that a safe-save may replace. Their lifetime must cover the browser's file read. Verify closing/reopening behavior and clean up abandoned session files through the app's existing session lifecycle.

Missing or malformed mastering artifacts must not prevent opening an otherwise valid project. A missing prepared part makes that part unavailable for dragging and offers **Prepare Again**. Missing finished pieces make their part require a new master return; existing valid parts remain usable. Validate file type, recorded size, and the audio properties actually needed before using artifacts. Do not silently mark missing work complete or invent replacement audio.

A run with mastering data writes project schema version 3. Projects without a run remain version 2. Continue reading versions 1 and 2 with no mastering run. Older builds should reject version 3 clearly rather than silently drop the new manifest while leaving orphaned media files. This requires updating the document's current unconditional version stamp.

One 50-minute 24-bit stereo WAV at 44.1 kHz is approximately 794 MB before filesystem overhead; final 256 kbps AAC adds roughly 96 MB. Accept this disk cost for resumability. Replacing the run removes its previous artifacts after saves no longer need them. No automatic deletion of the current run and no separate archival/cleanup feature are included.

## Integration boundaries

- A dedicated `@MainActor @Observable` mastering model owns state, labels, progress, validation, and actions. Views render it and forward user actions, following the repo's MV conventions.
- Pure functions decide intro eligibility, whole-slice chunking, frame offsets, LRC formatting, and whether current preparation inputs differ.
- Reuse existing render-plan and pure audio-render primitives behind the new mastering path; preserve the AIFF export and marker-injection path and its contracts.
- Side effects go through small `Sendable` dependency clients: loudness measurement, mastering audio preparation/conformance, AAC encoding, and staged artifact file operations. Use existing clients where their responsibilities fit rather than creating a generic job framework.
- Extend the workspace boundary with a suggested destination and caller-supplied prompt text, and a browser-opening operation. Existing Export keeps its current behavior.
- Reuse collision-safe copying/name review with a final-master naming policy and `.m4a` extension. Proposed filenames are sanitized generated titles; conflicts use the existing reviewed numeric suffix approach. Titles in metadata stay unchanged. Do not globally replace `.aiff` naming or remove source-prefix rules from legacy Export.
- Cancellation must reach actual render/convert/encode work, and project teardown waits for workers before releasing their input files. Concurrent stale completions cannot commit into a replaced run or another document.

## Verification and release acceptance

Model tests use Swift Testing, dependency overrides, and custom-dump. Tests cover observable outcomes and failure recovery, not view layout or implementation-shaped assertions.

1. Mixed projects prepare only eligible intros; renamed/resized intros still qualify, custom group membership does not qualify, and spotlights never qualify by name. Cover legacy provenance backfill before retranscription, missing/conflicting type fields, blank titles, and untyped manual slices. Zero eligible intros explains the disabled action. Existing Export still handles all its prior targets and injects Logic markers.
2. Chunking handles exact limits, overlong single slices, and no empty trailing part. Offsets equal actual cumulative PCM frame counts with no gaps or trim.
3. Render regressions preserve removals, crossfades, fades, and word-start mapping. Mono/stereo conversion and supported input rates produce expected frame counts; peak-limited gain does not change the timeline.
4. Meter fixtures agree with published/reference measurements. Silence, short clips, unusable measurements, and insufficient peak headroom do not generate invalid or excessive gain.
5. Return validation covers ambiguous parts, short files, extra tails, duplicate returns, rate conversion, decode failure, and cancellation. No incomplete m4a set marks a part finished.
6. Tags and LRC round-trip through AVFoundation and an independent parser. Cover Unicode, repeated/rounded timestamps, punctuation, normalized internal line breaks, and 5,000-entry payloads. Do not promise unsupported explicit end times. Document parser limits for unusually long individual clips; do not silently wrap timestamps at 100 minutes.
7. AAC tests use known frame lengths and impulses at beginning/middle/end, inspect the intended playback duration, and independently verify word positions without assuming every decoder strips trailing padding. Include varied-length 44.1→48→44.1 return fixtures so a rounding shortfall is caught before release.
8. Run persistence round-trips old/new schemas, partial multi-part completion, missing derived files, editor undo, retranscription, Save As, Duplicate, close during work, and overlapping autosaves. Preparing again swaps only after success; old artifacts stay alive while snapshots need them.
9. Destination default follows the current project location. Cancelling preserves ready files. Filename collisions and partial copy failures do not overwrite existing files or lose completed work.

Run the full pre-existing suites for every changed shared area, especially editor export, render plans, project/package saving, and export copying/naming. Inner loop: `make test-fast` in `QuickInterviewEditor/`. Before a product PR: the repo's `make test`, `make format-check`, and `make lint`; regenerate Xcode only when `project.yml` changes. If engine code changes despite the preserve-markers scope, run its full pytest suite. Each nontrivial implementation PR receives the configured Claude review, challenge, and separate concurrent Excess Audit before PR creation.

Manual QA before shipping: an actual browser drag into Masterchannel, a real intro mastering round trip with checks at two joins, resume a partially returned multi-part project, and package disk/save behavior with large WAVs. These are release checks, not claims established by the synthetic spike. No Masterchannel upload or subscription action has been performed during design.

## Planning handoff

Following Brian’s approval, write the implementation plan and split it into dependency-ordered PRs using `orchestrate-feature`. Suggested review boundaries are the intro preparation/audio primitives, durable run/document integration, and return/encode/save workflow; the architect should choose independently shippable boundaries against the final plan. There is **no marker-retirement PR** and no processor-retirement PR in this feature.

Use the workspace's explicit base `origin/main`; do not rename its existing branch. PR titles retain the global plain-English prefixed-title rules. PR creation and review-fix chores follow the configured Claude delegation workflow. No product code or PR has been created as part of this design work.

## Sources and inspected contracts

- `Core/ExportRenderClient.swift`, `Models/SliceRenderPlan.swift`, and `Views/Pages/Editor/EditorModel.swift`: existing slice rendering/export and marker mapping.
- `Models/Slice.swift`, `Models/SuggestionDocumentMutation.swift`, and `Models/EditorDocumentState.swift`: persisted suggestion type provenance.
- `Documents/ProjectDocument.swift`, `Core/ProjectPackage.swift`, and `Models/ProjectDocumentSink.swift`: snapshot-based package persistence.
- `Core/WorkspaceClient.swift`, `Core/ExportCopyClient.swift`, and `Models/ExportNaming.swift`: destination and collision handling.
- `~/playola/PlayolaAudioProcessor/PlayolaAudioProcessor/ProcessorViewModel.swift:97` and `Resources/mastering-split.sh:129`: existing duration matching and uncompensated sample/time splitting. `Resources/mastering-prep.sh:298` provides the chunking policy.
- `~/playola/playola/sst/functions/audio-normalizer/handler.ts`: MP4/AAC 256000 bps, 44100 Hz, stereo; separate server normalization remains in place.
- [FFmpeg loudnorm documentation](https://ffmpeg.org/ffmpeg-filters.html#loudnorm): dynamic fallback conditions.
- [libebur128](https://github.com/jiixyj/libebur128): established integrated-loudness and true-peak implementation.
- [music-metadata](https://github.com/Borewit/music-metadata) and its [LRC parser](https://raw.githubusercontent.com/Borewit/music-metadata/master/lib/lrc/LyricsParser.ts): existing MP4 lyric extraction and timestamp parsing.
