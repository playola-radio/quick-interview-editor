# Design: Step 3 — Slices + Export (macOS app)

**Status:** approved (brainstorm); ready for implementation plan
**Date:** 2026-07-06
**Depends on:** `plans/roadmap-macos-app.md` (Phase 3 back half + the "run-together
red" feature), Step 2 spec (`docs/superpowers/specs/2026-07-04-step2-import-live-engine-design.md`),
`CLAUDE.md`, `ux-prototype/README.md` (Slices panel + "Export all").
**Architecture reviewed with Codex** (consult, session `019f2d79`).

## Goal

Make the app **do its job** and kill the Terminal (roadmap Phase 3's "smallest
useful app"): turn word selections into **slices** and export **Logic-ready
AIFFs** with embedded word markers.

1. **Slice from selection** — the two-click transcript selection becomes a slice
   `{name, startSample, endSample, wordIDs, snippet, warnings}`.
2. **Slices panel** (match the ux-prototype) — collect slices; rename, reorder,
   delete, and **play**.
3. **Export** — render each slice's sample range into a Logic-ready AIFF with
   embedded word markers, individually and **"Export all"**, then **reveal in
   Finder**.
4. **Carry the tight-join warning through** — a slice whose cut points land where
   there's no silence is flagged (panel + export summary), the user's cue to add a
   fade in Logic.

**Out of scope (unchanged from the roadmap):** the waveform (Phase 4),
interactive drag-to-move / fine-tune insets (Phase 5), app packaging/notarization
(Phase 1). Also out for Step 3 (YAGNI): **undo/redo** of the slice list (prototype
only), markers/transport/zoom, transcription queueing changes.

## The split: 3a (slices UI) then 3b (engine render + export)

Codex verdict: one PR is too wide (UI state + playback + a new CLI command +
subprocess streaming + file copy + collision handling + reveal). Split into two
independently-shippable PRs, both from this workspace (3b in a fresh context after
3a merges, per CLAUDE.md "Context Hand-off"):

- **3a — Slices model + panel (pure Swift, no engine change).** `Slice` value
  type, tight-join warnings from `editPlan.silences`, an `EditorModel` that owns
  the loaded editor (transcript + slices), the slices panel UI, and **play** via a
  new `AudioPlayerClient`. Testable against the committed `edit-plan.json` fixture
  with no subprocess and no audio.
- **3b — Engine render + export/reveal.** A new engine `render` subcommand, a
  streaming `EngineClient.renderSlices`, export progress/cancel, destination
  folder + copy + Finder reveal via a `WorkspaceClient`, and Python + Swift
  integration tests.

---

# 3a — Slices model + panel (pure Swift)

## `Slice` — a sample-native value type

`Models/Slice.swift`. Everything in **samples** (roadmap decision 4), so Swift and
the engine share one coordinate system.

```swift
struct Slice: Identifiable, Equatable, Codable {
  var id: UUID
  var name: String
  var startSample: Int          // inclusive
  var endSample: Int            // exclusive
  var wordIDs: [Word.ID]
  var snippet: String           // joined word text, quoted + truncated for display
  var warnings: [SliceWarning]
}

enum SliceWarning: String, Equatable, Codable {
  case tightStart               // no silence before the first word's cut
  case tightEnd                 // no silence after the last word's cut
}
```

Display values are **computed on the model**, never in the view:
`durationLabel` (`"3.2s"`, from `(endSample - startSample) / sampleRate`),
`rangeLabel` (`"0:05.9 – 0:12.4"`, `M:SS.d`), `isTight` (`!warnings.isEmpty`),
`warningLabel` (e.g. `"Tight join — add a fade in Logic"` or `""`).

## Tight-join warnings from `editPlan.silences` (not the gap slider)

Decision 2 (settled): the transcript's red run-together words stay a **reading
aid** driven by the sensitivity slider (`runTogetherMaxGapMs`, unchanged). A
slice's **export warning** is about **cut safety** and comes from the engine's
detected **silence regions** — the same signal the real `cut` uses.

`Models/SliceWarnings.swift` (pure function, unit-tested):

```swift
func sliceWarnings(
  startSample: Int, endSample: Int, silences: [EditPlan.Silence]
) -> [SliceWarning]
```

- `tightStart` unless some silence region **touches/overlaps** `startSample`
  (i.e. the cut sits in or immediately at a silent gap).
- `tightEnd` unless some silence region touches/overlaps `endSample`.

No new audio analysis, no snapping, no fades. A cut at the very start (sample 0)
or very end (`durationSamples`) is treated as clean (no predecessor/successor to
join). **Caveat (accepted):** a word can be red in the transcript (gap heuristic)
while its slice reports no tight-join (silence present), or vice-versa — they
answer different questions and are labeled accordingly.

## `EditorModel` — owns the loaded editor

`Views/Pages/Editor/EditorModel.swift`. Codex verdict: do **not** overload
`SongTabModel` (it owns the transcription lifecycle + queue). Introduce an
`EditorModel` that `SongTabModel` holds once loaded.

```swift
@MainActor @Observable
final class EditorModel: ViewModel {
  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.audioPlayer) var audioPlayer
  // (3b adds \.engine and \.workspace)

  // MARK: - Initialization
  let sourceURL: URL
  let editPlan: EditPlan
  init(sourceURL: URL, editPlan: EditPlan) { … ; super.init() }

  // MARK: - Properties
  var transcript: TranscriptPageModel          // pure selection/transcript renderer
  var slices: IdentifiedArrayOf<Slice> = []
  var playingSliceID: Slice.ID?
  // (3b adds: exportPhase, destinationURL, presentedAlert for export errors)

  // MARK: - View Helpers
  var sliceCountLabel: String                  // "3 clips" / "1 clip"
  var canAddSlice: Bool                         // transcript.selectedSampleRange != nil
  var addSliceLabel, exportAllLabel, emptyStateMessage: String

  // MARK: - User Actions
  func addSliceTapped()                         // reads transcript.selectedWords/range
  func renameSlice(_ id: Slice.ID, to: String)
  func moveSlices(fromOffsets:toOffset:)        // reorder
  func deleteSlice(_ id: Slice.ID)
  func playSliceTapped(_ id: Slice.ID)          // AudioPlayerClient on source range
  func stopPlaybackTapped()
}
```

`addSliceTapped()`:
1. Guard `transcript.selectedSampleRange` and `transcript.selectedWords` non-empty.
2. Validate: `startSample < endSample`, both within `0...editPlan.source.durationSamples`.
3. Build `snippet` from selected word text (quote + truncate ~68 chars, matching
   the prototype's `snip`).
4. Compute `warnings` via `sliceWarnings(...)`.
5. Append; auto-name `"Slice N"` (N = count + 1). Clearing the transcript
   selection after add is a UX nicety (match prototype: selection resets).

`TranscriptPageModel` stays **selection/transcript-only** — no callback closures.
The Add-slice button lives in the selection panel area but calls
`editor.addSliceTapped()`, and the model reads `transcript.selectedWords` /
`selectedSampleRange` directly (both already exist; `selectedWords` may need to be
exposed non-privately or a small `selectionSnippet`/`selectedWordIDs` accessor
added).

`SongTabModel` change: `.loaded` state holds `var editor: EditorModel?` instead of
`transcript: TranscriptPageModel?`. On `.completed`, build
`EditorModel(sourceURL:, editPlan:)` (which builds its own `TranscriptPageModel`).

## `AudioPlayerClient` — play a slice's source range

`Core/AudioPlayerClient.swift`. A `Sendable` dependency (liveValue/testValue),
mockable so `playSliceTapped` is unit-tested with no audio.

```swift
struct AudioPlayerClient: Sendable {
  var play: @Sendable (URL, Range<Int>, Int) async throws -> Void  // url, sampleRange, sampleRate
  var stop: @Sendable () async -> Void
}
```

Play the **source** audio range (`[startSample, endSample)`), **not** a rendered
AIFF — rendering just to preview is waste (Codex). `liveValue` uses AVFoundation
(`AVAudioPlayerNode.scheduleSegment` over an `AVAudioFile`, or `AVAudioPlayer` with
`currentTime` + a stop at the range end). **Play/stop only** — no scrub/speed
(that's Phase 4). `testValue` fails cleanly (`reportIssue` + throw when not
overridden). The model tracks `playingSliceID` for the panel's play/stop button
state.

## Views (dumb)

- `SlicesPanelView` — binds `EditorModel.slices`; each card renders `name`
  (editable), `durationLabel`, `rangeLabel`, `snippet`, tight-join warning styling,
  Play, and ✕ (delete), plus reorder. All copy/flags from the model. Matches the
  ux-prototype tokens (Playola red `#cc6666`, run-together `#e39393`, card `#151515`,
  etc.).
- `EditorView` — composes `TranscriptPageView(model: editor.transcript)` + the
  selection/Add-slice affordance + `SlicesPanelView(model: editor)`.
- `SongTabView` `.loaded` renders `EditorView(model: editor)`.
- **No dead controls:** 3a ships the panel with create / rename / reorder / delete /
  play only. The per-slice **Export**, **"Export all"**, and the export-tint styling
  are added in 3b — 3a ships zero non-functional export buttons.

## Fix-now (Step-1 follow-up, while in this code)

`TranscriptPageView.color(for:)` still contains display-priority logic. Move it
onto the model as `WordViewState.displayRole` (`.selected/.runTogether/.normal`);
the view only maps role → color. Removes the last view-logic seam.

## 3a testing (Swift Testing, colocated, fixture-backed)

- `Slice` / `sliceWarnings`: tightStart/tightEnd correctly derived from synthetic
  silences (touching, overlapping, absent, boundary at 0 / durationSamples).
- `EditorModel`: add-slice from a selection produces the expected
  `startSample/endSample/wordIDs/snippet/warnings`; empty/invalid selection is
  rejected (`canAddSlice == false`, no append); rename/reorder/delete mutate
  `slices` as expected; `sliceCountLabel` pluralization.
- Play: `playSliceTapped` calls `audioPlayer.play` with the slice's source range +
  sample rate (assert via a recording `testValue`); `stopPlaybackTapped` calls
  `stop`; `playingSliceID` tracks state.
- Value comparisons via `expectNoDifference`; no `Task.sleep`; mock deps via
  `withDependencies`.

---

# 3b — Engine render + export/reveal

## Engine: the `render` subcommand (stateless)

Codex verdict: **stateless render**, no persistent per-song work dirs (they create
cleanup/stale-cache/privacy/lifecycle problems and don't fit Step 2's
delete-after-job model). `render` is deterministic from a written **request file**
(the `SpawnedProcess` stdin is hardwired to `/dev/null`, so stdin JSON is not free
— a `--request` file is simpler, debuggable, and deadlock-free).

```bash
.venv/bin/python -m logic_markers.cli render <audio> \
    --request <request.json> --work-dir <dir> [--sample-rate 44100]
```

**Request JSON** (written by Swift into the work-dir):

```json
{
  "sample_rate": 44100,
  "markers": [ { "position": 54772, "name": "So" }, … ],
  "slices": [ { "id": "<uuid>", "start_sample": 54772, "end_sample": 1729337 }, … ]
}
```

- **`markers`** are passed **from Swift/EditPlan with absolute sample positions** —
  the engine does **not** rebuild them from seconds (avoids reintroducing rounding
  drift; Codex's key correction). One global array of word markers; `slice_aiff`
  already filters markers to `[start, end)` and rebases/renumbers per slice.
- Steps: `convert_to_aiff(source, work/render.aiff, sample_rate)` (deterministic;
  no transcript reuse needed), read bytes once, then per slice call
  `slice_aiff(aiff_bytes, start_sample, end_sample, markers)` and write
  `<work-dir>/<id>.aiff`.
- **stdout:** one result JSON, keyed by **id** (not array order):
  `{"slices":[{"id":"<uuid>","path":"<work-dir>/<id>.aiff","start_sample":…,"end_sample":…}]}`.
- **stderr:** `QIE_EVENT` progress lines, reusing the Step-2 protocol
  (`rendering` phase, e.g. `{"type":"progress","phase":"rendering","message":"Rendering slice 2 of 3"}`).

The engine writes only to its **work-dir** (temp/Caches), never beside the source
and never to a user folder. Existing `markers`/`transcript`/`cut`/`plan` commands
are untouched.

### Engine tests (pytest)

- `render` writes N valid AIFFs to the work-dir; each decodes; frame counts match
  the requested ranges; markers within each slice are rebased (position relative to
  slice start) and renumbered from 1.
- Result JSON is keyed by request `id` and paths exist.
- `render` writes nothing beside the source.
- `QIE_EVENT` progress lines appear on stderr in order.
- Reuse a tiny real WAV + a hand-built request (no WhisperX, no models).

## Swift: `EngineClient.renderSlices`

Mirror `transcribe` (streaming, cancellable, mockable):

```swift
struct EngineClient: Sendable {
  var loadPlan: @Sendable (URL) async throws -> EditPlan
  var transcribe: @Sendable (URL) -> AsyncThrowingStream<EngineEvent, Error>
  var renderSlices: @Sendable (RenderRequest) -> AsyncThrowingStream<RenderEvent, Error>
}

struct RenderRequest: Equatable, Sendable {
  var sourceURL: URL
  var sampleRate: Int
  var markers: [RenderMarker]           // {position, name} from EditPlan words
  var slices: [RenderSliceSpec]         // {id, startSample, endSample}
}

enum RenderEvent: Equatable, Sendable {
  case progress(RenderProgress)         // phase + message (spinner + "Rendering slice i of n")
  case completed([RenderedSlice])       // {id, url} keyed by request id
}
```

`LiveEngine.render(...)`: make a temp/Caches work-dir, **write `request.json`**,
spawn `python -m logic_markers.cli render <audio> --request … --work-dir …`
(reusing `SpawnedProcess` — process-group cancel already handled; **no stdin
needed**), stream `QIE_EVENT` progress, decode the stdout result JSON on exit 0.
`testValue.renderSlices` fails cleanly (`reportIssue` + `unimplemented`);
`previewValue` yields fixtures.

## Output location, copy, reveal (Swift owns user-facing FS)

Codex verdict confirmed: **engine → app-owned temp/Caches**, then **Swift copies →
user-chosen folder**, then reveal. One owner for user-facing filesystem; avoids
relying on murky child-process TCC for a non-sandboxed direct-download app.

- **Destination:** first export opens an `NSOpenPanel` (choose directory),
  remembered on `EditorModel.destinationURL` for that song's subsequent exports
  (user can change it). No security-scoped bookmarks needed (non-sandboxed; the
  panel grant is process-wide for the app).
- **Filename scheme (Swift model logic, tested):** default
  `"<source stem> - Slice 001.aiff"` (zero-padded index). **Sanitize** the slice
  name (strip path separators / illegal chars); never use a raw slice name as a
  path component. **Resolve collisions** with `2`, `3`, … suffixes against the
  destination folder.
- **Copy** each rendered temp AIFF to `destination/<final name>`; **reveal** the
  set via `WorkspaceClient` (`NSWorkspace.activateFileViewerSelecting`).
- **Delete** the temp work-dir after copy (and on cancel).

## `WorkspaceClient` — Finder reveal

`Core/WorkspaceClient.swift`. A `Sendable` dependency wrapping the
`NSWorkspace.activateFileViewerSelecting([URL])` side effect so the model's export
flow is testable (`testValue` records the revealed URLs).

## Export flow on `EditorModel` (added in 3b)

```swift
enum ExportPhase: Equatable {
  case idle
  case exporting(current: Int, total: Int)     // drives progress copy
  case done(count: Int)
  case failed(String)
}
var exportPhase: ExportPhase = .idle
var destinationURL: URL?

func exportSliceTapped(_ id: Slice.ID) async   // export one
func exportAllTapped() async                    // export all, in panel order
func cancelExportTapped()
```

Each export: ensure a destination (prompt if nil) → build a `RenderRequest` from
the target slice(s) + the plan's word markers → consume `engine.renderSlices` →
copy results to destination with the filename scheme → reveal → surface a summary
including any **tight-join warnings** carried from the slices (panel + summary
copy; **not** written into the AIFF marker lane — markers stay pure word markers).
**Cancellable:** cancelling kills the process group and deletes the temp dir;
already-copied destination files are left (report partial explicitly).

### 3b testing

- Python `render` tests (above).
- `renderSlices` stream: mock `withDependencies { $0.engine.renderSlices = … }`;
  `.progress` → `exportPhase` walks `exporting → done`; a throwing stream → `.failed`.
- Filename scheme: default name, sanitization, collision suffixes (unit-tested pure
  function).
- Export model: `exportAllTapped` requests all slices keyed by id; results mapped
  back by id (not order); `WorkspaceClient.reveal` called with the copied URLs
  (recording `testValue`); missing-destination path prompts.
- No subprocess/audio in unit tests; a `LiveEngine` render integration test is
  opt-in (gated like the Step-2 `QIE_RUN_LIVE_ENGINE` test).

---

## Build / tooling facts (do not rediscover)

- Build/test: `cd QuickInterviewEditor && xcodebuild test -scheme QuickInterviewEditor
  -destination 'platform=macOS' -allowProvisioningUpdates` (or `bundle exec
  fastlane mac test`). After any file add/rename under `QuickInterviewEditor/`, run
  `xcodegen generate` and commit the regenerated `.xcodeproj`.
- Test target must **not** directly link `swift-dependencies` (transitive via app
  target + `@testable import`); direct linking breaks `withDependencies`.
- Signing team `FSRSPV9N9Q`; always `-allowProvisioningUpdates`.
- Lint/format (CI-enforced): `make lint` (SwiftLint `--strict`) / `make format-check`.
- Engine env `.venv` (Homebrew python3.12; `afconvert`, not ffmpeg). Engine tests:
  `python3 -m pytest -q`.
- Live run prereq: a `.venv` at the compiled repo root (this worktree) **or**
  `QIE_ENGINE_REPO` pointed at a checkout with a working `.venv` and the `render`
  (and Step-2 `plan`) commands.

## Risks / open questions

- **Sample agreement.** `render` re-converts the source with the same canonical
  rate (44100) `plan` used — deterministic, so slice samples agree. If a source's
  native rate ever differs, the plan's `source.sampleRate` is the source of truth;
  pass it through in the request.
- **Tight-join semantics diverge from transcript red** (accepted, see 3a) — the
  panel warning copy must make clear it's about the cut, not the words.
- **Export cancel partial state** — copied files remain; report "N of M exported"
  rather than silently.
- **AVFoundation range playback** — stopping precisely at the range end; keep the
  `AudioPlayerClient` interface small and put the mechanism in `liveValue`.
- **Destination TCC** — if the user picks Desktop/Documents/Downloads, macOS may
  prompt once; the panel grant covers the app (Swift does the copy, not the child).

## Out of scope / deferred

Waveform, drag/fine-tune cut points, undo/redo of slices, markers/transport/zoom,
packaging/notarization, native inference, `@Shared` promotion, transcription-queue
changes. The `Slice` sample-native model, `EditorModel`, and stateless `render`
leave room for Phases 4–6.
