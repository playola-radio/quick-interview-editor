# Configurable suggestion types, fields, and naming

**Date:** 2026-09-07

**Status:** Design sections approved in conversation; written specification awaiting user review.

**Working branch:** `briankeane/suggestion-types`

**Baseline:** `d38c9d8ddfb14f0ca477ea23c6a559584475e5d9`

## Purpose and scope

Expand Suggestions to find Spotlights, Song Intros, and several kinds of Audio Images. Preserve the successful Spotlight discovery behavior. Let users create and edit app-wide suggestion types, extraction fields, discovery guidelines, and naming templates. Support numbering across multiple source tapes through project-specific starting numbers.

A rerun replaces the suggestion batch after confirmation and successful completion. Saved clips remain safe. This feature does not add audio splitting, automatic synchronization between projects, or a runtime Playola database dependency.

The prior implementation is archived at `temp/suggestion-types-unplanned-draft`, commit `558cda121e8ffcd3e6abc74534690783d2bb99bc`. It is reference material, not the implementation of this design. In particular, its mutually exclusive numbered/content naming modes do not satisfy the combined Song Intro template, and it lacks the approved confirmation and starting-number behavior.

## Default types and names

Ship three groups containing six editable types:

| Group | Type | Naming template | Sequence grouping |
| --- | --- | --- | --- |
| Spotlights | Spotlight | `Spotlight {Sequence}` | Type |
| Song Intros | Song Intro | `{Song Title} {Sequence}, {Artist Name}` | Type + Song Title + Artist Name |
| Audio Images | ID Image | `ID {Sequence}` | Type |
| Audio Images | Pre-commercial Image | `Pre-Com {Sequence}` | Type |
| Audio Images | Post-commercial Image | `Post-Com {Sequence}` | Type |
| Audio Images | Promo Image | `Promo {Sequence}` | Type |

Examples include `ID 7.aiff`, `Spotlight 12.aiff`, and `Nobody Wins 4, American Aquarium.aiff`. Content determines the imaging subtype, but it does not otherwise enter imaging or Spotlight names. Three takes of an original song are a common use case, not a quota: never manufacture suggestions to reach three.

### Default discovery guidance

- **Spotlight:** retain the current tuned paragraph-first discovery prompt and story-processing behavior. Its existing type description is “one self-contained story or anecdote (~40-120s).” Numbered output names must not replace descriptive topic labels used during discovery or merging.
- **Song Intro:** retain the established setup/handoff guidance for one named song, including introductions to another artist's recording. Accept short, complete handoffs. A song mention within a longer story alone is not sufficient to establish an intro.
- **ID Image:** a complete spoken artist/station identification or station-branding liner, including listening-to statements. A brief self-identification at the beginning of a longer anecdote is not automatically a separate ID. Prefer a more specific imaging subtype for explicit break transitions or direct promotions.
- **Pre-commercial Image:** introduces an upcoming commercial break, asks the listener to stay through ads, or explains that the upcoming commercials support musicians. Include short transitions about paying the musicians.
- **Post-commercial Image:** returns from a commercial break, welcomes the listener back, or explicitly resumes station programming after the break.
- **Promo Image:** directly promotes a website, subscription, event/tour, release, or other listener action. A passing factual mention within a story is not automatically promotional imaging.

Keep the current Spotlight duration targets and acceptance limits. Lower the Song Intro hard minimum from 12 seconds to 1 second while retaining the existing target and upper limit. For new image/custom types, start with a generous 1–240-second acceptance range; do not impose the Spotlight minimum or a narrow ID-like upper limit on promos. Keep separate repeated takes rather than merging them because their topic labels match. These internal duration bounds are not additional user settings in this feature.

## Configuration and filtering

**Configure Suggestions** opens an app-wide editor, also reachable from app Settings, with **Types** and **Fields** sections. Changes are drafted, validated, and explicitly saved or cancelled. A successful save makes them available in all open project windows for future searches. Failed persistence remains visible and must not be reported as a successful save.

Each type has a stable identity, display name, group, discovery guidelines, naming template, and sequence-grouping fields. Users can add types, edit defaults, and remove types they no longer want. A type chooses one of the three initial display groups; discovery behavior is determined by its identity/rules, not by the display group alone. Creating a separate group-management feature is outside this scope.

Each field has a stable identity, display name, and extraction instructions. Users can add fields and edit defaults. Removing a field referenced by a naming template or sequence-grouping rule is blocked until those references are changed; show the affected types. Removing a type affects future discovery, not historical results or clips.

The naming builder combines ordered literal text, extracted-field tokens, and a built-in **Sequence** token. It shows a clearly labeled example preview without calling the LLM. Field references use identities internally, so renaming a field does not break templates. Sequence grouping is selectable independently of token order: by type alone, or by type plus selected extracted fields.

Validate nonempty names/guidelines/extraction instructions, unique type names within each group, unique field names, valid template references, and at least one configured type. Templates must contain at least one meaningful text/field/sequence component. A Sequence token is optional for custom templates; any Sequence occurrences in one template use the same assigned number.

A **Types** menu offers **All Types**, group selection, and individual type selection. Group selection selects/deselects all its children; partial selection is visible. It filters both the suggestion list and pending transcript outlines. It does not change discovery settings, rerun the model, renumber candidates, or hide saved clips. Show an explicit no-matches state when the selected filter hides all results. Filters are local to the open editor window.

Historical result types absent from current settings remain visible and filterable using their saved labels. Changes to global rules never silently rename current suggestions or saved clips; rerunning uses the new definitions.

## Field extraction and correction

Ship these editable extracted fields:

| Field | Default extraction instructions |
| --- | --- |
| Song Title | Identify the title of the recording this clip introduces. Use the candidate and relevant context elsewhere in the source transcript. Distinguish the introduced recording from songs mentioned as background. Return missing when the text does not establish the title; do not invent it. |
| Artist Name | Identify the performer singing the introduced recording. Do not substitute the station DJ, the speaker, the songwriter, or the first musician mentioned. For explicit collaborations, include the established performers. Use speaker identity elsewhere in the transcript only when the text establishes that this is their performance. Return missing when the performer cannot be established. |
| Descriptive Title | Produce a concise 3–6-word description of this clip's complete thought or purpose, using only the source transcript. Do not make this output name control candidate merging. |

The LLM returns field values keyed by stable field IDs, with missing values represented explicitly. The app assembles names; the LLM does not format final filenames or assign sequence numbers. Only fields referenced by naming templates or sequence-grouping rules need extraction. Existing descriptive discovery labels provide the fallback without requiring a separate extraction call for a plain numbered type.

When a required field is missing, retain the suggestion, show a descriptive fallback name and the missing-field indicator, and allow the user to correct extracted values before acceptance. A malformed response or failed extraction request is an error, not evidence that a field is absent. Preserve both extracted and manually corrected values in the result record, with manual values taking precedence.

Applying a field correction is explicit and undoable. Recompute the affected pending suggestion's name. If its sequence-group key changes, allocate a safe number in the new group; do not renumber unrelated candidates. Missing sequence-group fields do not all collapse into one shared “unknown song” group: keep their provisional reservations distinct until corrected. Accepting an unresolved suggestion is allowed with its visible descriptive fallback name.

## Numbering and multiple tapes

Naming rules are app-wide. Starting numbers are saved in each `.pie` project, letting users continue a sequence manually across source tapes. Defaults are 1, adjusted for reservations already held by saved clips in the current project. The app does not inspect other projects to infer their counters.

Expose **Start at** for each type before generation. Once extraction identifies Song Title/Artist Name combinations, expose per-song sequence starts during review. A specific group override takes precedence over the type-level starting value. Inputs must be positive whole numbers within the supported integer range; reject a start whose candidate batch would overflow that range.

After discovery validation and deduplication, assign numbers in transcript order within each sequence group, with deterministic tie-breaking for identical spans. Ranking, filtering, accepting out of order, and rejecting suggestions never renumber existing results. Rejecting Spotlight 2 may leave Spotlight 1 and Spotlight 3.

Acceptance copies the displayed name and its structured sequence reservation into the saved clip. Preserve that reservation separately from the editable clip name; never recover it by asking the LLM or parsing a manually changed name. Undoing acceptance undoes both the clip and its reservation. Existing clips reserve their numbers even when renamed.

For a fresh rerun, discard reservations belonging only to the old suggestion batch. Within each group, allocate new suggestions after the highest saved-clip reservation, respecting the selected starting value. An automatic/default start can advance to the next safe number. If an explicit user-entered start would overlap or precede saved reservations, show the minimum safe value and require correction rather than silently overriding the user's input.

Applying a changed start is an explicit **Renumber Pending Suggestions** action. It renumbers only pending suggestions in the selected sequence, in transcript order. Keep reservations for other retained results, including rejected suggestions, and saved clips; skip occupied numbers. This explicit action is the only batch renumbering during review. It never changes saved clip names. Starting values and renumbering changes are undoable document state.

If another edit or undo restores a saved clip whose reservation now conflicts with a pending result, flag the conflict and require a safe renumber before accepting that result. Do not silently rename either item. The user can continue to rename ordinary clips manually; unrelated names without structured provenance are covered by filename collision protection.

## Discovery and naming pipeline

Use the existing Swift dependency boundary and Python helper. The app captures a configuration snapshot and version/hash at search start, so edits in another window apply to the next search.

1. Build the existing transcript/paragraph evidence.
2. Run the tuned Spotlight/Song Intro discovery pass with unchanged default discovery text. An explicit user edit to those guidelines intentionally changes that pass.
3. Run a separate pass for image and custom types using their configured guidance. Group all these types in that pass rather than issuing a call per type. Use bounded overlapping transcript windows when input is too long, retaining stable sentence/word coordinates and deduplicating overlap.
4. Validate candidate ranges and types, derive sample bounds from transcript evidence, and apply the relevant duration/deduplication rules. Do not let image candidates participate in Spotlight story merging. Within the imaging family, choose the most specific matching subtype for a take instead of returning duplicate ID/pre-commercial/promo copies of the same take. Cross-family overlap can remain valid, such as an intro within a longer Spotlight.
5. Extract required naming fields in batches with relevant source context, using the snapshot's field instructions. Match outputs by candidate and field identities. Reject missing/duplicate result identities and undeclared fields rather than accidentally assigning values to another clip.
6. In Swift, validate current sequence reservations, assign numbers, and assemble names. Commit the completed suggestion batch together.

Skip unused passes when their type set is empty and skip extraction when no extracted fields are required. Preserve descriptive/topic labels separately from final display names throughout.

Keep model, discovery-prompt, extraction-prompt, configuration, transcript, and source provenance sufficient to identify the inputs used. Cache keys include the actual prompt and relevant configuration. Manual reruns bypass existing responses for all passes. Automatic initial searches can use caches and retain the existing safeguard against overwriting suggestions that appeared while a background run was in flight.

Separate passes add model requests and latency. This is the approved trade-off for keeping new classification and naming instructions out of the successful default Spotlight prompt.

## Rerun lifecycle and errors

When existing suggestions are present, show:

> **Replace existing suggestions?**
>
> This will run a new search and replace the current suggestions. Your saved clips will not be changed.
>
> **Cancel** · **Replace Suggestions**

Cancelling this dialog does not start a request. While searching, retain the old results and show progress. Disable candidate accept/reject, field edits, starting-number application, and additional search actions until the search ends. Saved clips remain editable, so recheck their reservations immediately before assigning new numbers. Provide a Cancel Search action that cancels all active helper/model work.

A valid successful result replaces the entire candidate batch, including prior accepted/rejected suggestion records. A valid empty result clears it and shows “No matching suggestions found.” Saved clips remain in the document. Malformed output, provider/helper failure, extraction failure, or cancellation preserves the previous batch and starting-number state. If numbering conflicts require user correction after extraction, retain the previous batch and present the correction before applying the replacement; do not make the user pay for the completed search again.

No partial batch replaces the old results. Guard against late events from cancelled/superseded runs. Preserve the existing non-undoable background-analysis transaction behavior for generated batches, rebasing it through document history so undoing an earlier edit cannot resurrect discarded suggestions. Normal acceptance, rejection, local field correction, and explicit renumber actions continue through the editor's undoable document mutation path.

## Export behavior

For clips accepted from this feature, export the stored clip name plus `.aiff`, without the source recording prefix. A later manual rename becomes the clip's export name. Keep legacy/manual clips without the new naming provenance on their existing export behavior; merely opening a project must not rename existing deliverables.

Retain filename sanitization, UTF-8 filename length limits, and case-insensitive collision protection against both existing files and the current export batch. Retain the exporter's numeric disambiguation suffix when necessary. That suffix prevents overwrite; it does not update the editorial sequence or stored clip name. Never renumber saved clips just because export order or destination contents changed.

## State, compatibility, and implementation boundaries

Use focused units consistent with the existing Swift observable-model/dependency architecture:

| Unit | Responsibility |
| --- | --- |
| Configuration models/store | App-wide type and field definitions, templates, grouping rules, validation, atomic persistence |
| Configuration model/view | Draft Types/Fields editing, reference validation, sample previews, save/cancel |
| Pure naming/sequence logic | Template assembly, normalized sequence keys, reservations, start validation, collision diagnostics |
| Suggestions page model/view | Filter state, starts and field-correction UI, confirmation, progress/cancellation, result presentation |
| CutSuggestClient / Python helper | Versioned request/response contract, discovery, extraction, caching, validated candidate evidence |
| Editor document mutation path | Persisted project starts, candidate changes, acceptance/renumber undo, saved-clip reservations |
| Export naming | Exact generated names and filesystem-safe disambiguation |

Persist app-wide configuration under the app's Application Support directory with an explicit configuration schema version. Absence seeds the defaults; invalid stored data surfaces a recoverable settings error instead of silently overwriting user rules. Saving configurations from multiple windows must detect an outdated draft before replacing newer settings.

Persist project-specific starts, extracted/corrected values, configuration/type/field label snapshots, generated names, and structured sequence provenance. Sequence keys use stable type/field IDs plus trimmed, Unicode-normalized, case-insensitive values; do not strip meaningful song-title punctuation or infer that similar titles are identical.

Retain legacy `intro` and `spotlight` identifiers. New built-in and custom types use stable string IDs, and valid historical identities remain decodable after removal from global settings. Unknown configuration references in a new request fail validation; historical records use their saved snapshots.

Extend `EditorDocumentState` and the editor's snapshot/restore/mutation paths together so new project state participates in save, undo, redo, revert, and duplication. Add optional fields with backward decoding defaults to existing suggestion/slice records. Existing `.pie` files and legacy imported sidecars keep their contents and names. On loading an old accepted suggestion whose UUID matches an existing slice, mark only its known type association; do not guess missing sequence reservations from its title. That association does not opt a legacy clip into the new export naming. Users can supply a safe Start at value for older projects.

Do not make newly written projects silently consumable by an older app that would discard the new state: introduce project schema version 2, continue reading version 1, and retain the existing unsupported-version rejection for newer versions. Saving a loaded version-1 project writes version 2 through the normal document save path.

The transcription/rendering engine and `edit-plan.json` remain raw evidence. Do not move editorial configuration or suggestion state into that contract. New source files must be registered with the Xcode project as part of implementation, with focused models/views/tests rather than growing unrelated page files.

## Validation before implementation is considered complete

- Prove that adding default imaging types and naming fields leaves the default Spotlight discovery prompt unchanged; retain existing cached regression evaluations and compare candidate spans before naming.
- Cover all six defaults, custom types/fields, template composition, settings validation, save failure, stale drafts, rename/remove references, and persistence across windows/relaunch.
- Exercise short complete intros and IDs, separate repeated takes, longer promos, imaging-subtype specificity, cross-type overlap, and invalid spans/identities.
- Verify Song Title/Artist Name extraction where the speaker introduces another artist, where multiple artists are mentioned, and where required evidence is absent. Use synthetic examples based on the researched editorial distinctions.
- Cover sequence grouping, same song/different performers, per-type/per-song starts, multi-tape continuation, gaps after rejection, filter independence, field corrections, pending-only renumbering, overflow, and saved reservations surviving reruns/manual renames.
- Exercise confirmation cancellation, search cancellation, provider failure, malformed output, extraction failure, valid zero matches, background/manual races, late events, and reservation changes during a search. Assert that clips and previous results remain safe where required.
- Round-trip old and new project fixtures; cover save/reopen, undo/redo, revert/duplicate, deleted global definitions, and original clip-name preservation.
- Test exact export names, unchanged legacy naming, unsafe characters, long Unicode names, case-insensitive collisions, and no overwrite.
- Run the appropriate Python tests, the Swift model suite via `make test-fast`, format-check, and SwiftLint. Use mocked clients for deterministic tests. Live discovery quality review uses representative ID/pre/post/promo/intro/Spotlight material before claiming editorial quality; a prompt regression test alone is not proof of live quality.

## Research and evidence limits

Read-only Playola MCP inspection on 2026-09-07 found 951 `audioimage` blocks, only 13 with nonempty transcripts. All 13 were inspected, together with sampled intros and Spotlight-style commentary. Categories are useful discovery clues but are not clean ground truth.

Representative examples:

- `27b52464-5391-47ff-9c9e-b05520fd8d96`: Radney Foster introduces American Aquarium's recording of Nobody Wins. Speaker/block artist metadata must not replace the introduced performer.
- `0742551d-3373-4a65-91d0-687137797313`: a complete song intro around 8 seconds, below the old 12-second minimum.
- `3674e5c3-359f-42e7-bbd8-06c7922f9c52`: a subscription/artist-support promo around 38 seconds.
- `fd220a12-fa36-4a2b-87d2-278ba60a267a`: a recording-session anecdote labeled Spotlight but stored in Intros.
- `6b13b4c7-46e8-463a-bc52-5014567a2deb`: a station identification stored as a Spotlight production piece.

Matching post-commercial records had no transcripts, so that default is based on its editorial purpose and remains subject to review of real spoken examples. No audio was downloaded/transcribed and no database data was changed during this design work.

This design extends the existing [LLM cut-suggester design](2026-08-04-llm-cut-suggester-plan.md). After written-spec review, create the implementation plan at `docs/superpowers/plans/2026-09-07-suggestion-types.md`. Implementation begins only after the planning workflow is complete.
