# Prepare for Mastering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare edited intros for Masterchannel, resume the handoff from the project, and save tagged final m4a pieces while preserving the existing spotlight export workflow.

**Architecture:** Native streaming audio clients produce immutable staged artifacts. `ProjectModel` owns the durable run and publishes it through the document sink; `ProjectDocument` and `ProjectPackage` alone write the package. A dedicated mastering sheet model coordinates the workflow without adding another subsystem to `EditorModel`.

**Tech Stack:** Swift 6, macOS 15, SwiftUI MV, AVFoundation, pinned libebur128 C source, Point-Free Dependencies/IdentifiedCollections/CustomDump, Swift Testing, XcodeGen.

---

## Authority and execution

The approved spec is `docs/superpowers/specs/2026-09-28-prepare-for-mastering-design.md` (approved 2026-09-28). It supersedes the original attachment wherever they differ. In particular: intros alone use this path; spotlight AIFF export, Logic markers and PlayolaAudioProcessor remain. No upload, format picker, silence trimming, inserted gaps, time alignment, marker retirement or processor retirement is included.

Run this as separate PRs in fresh local Conductor workspaces. The explicit base is **`origin/main`**, with PRs against **`main`**, overriding generic develop defaults. Do not rename the current branch. Existing user approval covers the written design and proceeding to these implementation handoffs.

Design workflow exception recorded for every brief: **`--no-design` — Brian explicitly requested and approved the written brainstorming spec under `docs/superpowers/specs/`, followed by writing-plans/orchestrate-feature.** No separate Pen/design-PR approval is required for this handoff.

Read `CLAUDE.md` and `AGENTS.md` when present. Use the applicable `pfw-*` skills before planning/writing Swift: dependencies, observable-models, testing, custom-dump, modern-swiftui, identified-collections, sharing and issue-reporting. Use case-paths if tests inspect associated-value cases. Follow the current agent's mirrored outside-review pipeline: Codex workers consult Claude; Claude workers consult Codex. Do not delegate back recursively. Product PR creation and review-fix chores go to the outside CLI, including the explicit `main` base override in its prompt.

## Checks for every product PR

Use TDD for behavior: add one failing behavior test, run it, implement the smallest change, rerun that suite, commit. Test values with `expectNoDifference`/`expectDifference`; no sleep-based tests. Audio integration tests intentionally use tiny synthetic PCM files; page-model tests use dependency overrides and never launch Python or real panels.

From `QuickInterviewEditor/`, focused commands below follow this pattern:

```sh
make test-fast ONLY=PlayolaInterviewEditorTests/MasteringPreparationTests
```

A new API should fail to compile or fail its behavioral assertion on the first run; after implementation the suite must pass. If the test already passes before a change, verify that it exercises the intended missing behavior instead of inventing a red failure. Run full pre-existing suites for every changed shared area, then the full app checks before pushing:

```sh
xcodebuild build -scheme PlayolaInterviewEditor -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
make test
make format-check
make lint
```

All commands must exit zero. Run `make generate` only when `project.yml` changes; never regenerate between ordinary test runs. If Python changes despite the preservation scope, run `python3 -m pytest -q` from the repository root.

Before declaring a nontrivial PR complete: commit the intended diff; run the configured outside review PASS/FAIL gate, then challenge and a separate Excess Audit concurrently. Adjudicate both reports together, apply one fix wave, rerun affected checks and re-review nontrivial fixes. Trace the actual audio-client → model → document contracts, not just mocks. Every excess finding is deleted or defended by naming its spec requirement.

Delegate PR creation and review fixing according to the worker's current global instructions. Require a plain-English title with exactly one allowed prefix. Address all actionable Greptile findings on the non-release head branch; do not request re-review at confidence ≥4/5. Do not merge without authorization. Report any blocked external review rather than claiming it passed.

## Portable evidence and shipping gate

Use `docs/superpowers/plans/2026-09-28-mastering-validation-recipes.md` for the 5/5,000-word metadata fixtures, impulse positions, converter flushing, AAC padding distinction, libebur128 pin and manual QA. Nothing depends on `.context/mastering-spike/` being available to workers.

The initial two-second fixture passed exact word-position checks through AVFoundation and ffmpeg, but that does not establish Masterchannel timing. Before shipping the integrated flow, perform the recipe's actual browser drag, real mastering return, partial-run reopen and large-package save checks. Record which manual checks remain outstanding in the final report.

## PR graph and ownership

```text
A — preparation audio ───────> C — return audio ──┐
                                                ├──> D — editor workflow
B — durable project storage ────────────────────┘
```

A and B may start together. C starts after A merges. D starts after B and C merge. Do not stack C on an unreviewed A or D on unfinished storage; use merged `origin/main` for each dependent handoff.

| PR | Plain-English title | Branch to create if needed | Worker | Review boundary |
| --- | --- | --- | --- | --- |
| A | `feature: prepare intro audio for mastering` | `briankeane/mastering-preparation` | Codex · `gpt-5.6-sol` · high | Pure preparation policy and streaming audio; preserves AIFF behavior |
| B | `feature: keep mastering work inside saved projects` | `briankeane/mastering-project-storage` | Codex · `gpt-6-astra` · high | Immutable manifest/media, schema compatibility and save lifetime |
| C | `feature: split returned masters into tagged audio files` | `briankeane/mastering-returns` | Codex · `gpt-5.6-sol` · high | Return conformance, strict range validation and tagged AAC |
| D | `feature: master intros from the interview editor` | `briankeane/mastering-workflow` | Codex · `gpt-5.6-terra` · high | Sheet, project wiring, browser handoff and destination/collision review |

These Codex workers follow the current Codex-main-loop/Claude-outside-voice instructions. B is escalated for snapshot ownership and concurrent saves. C receives extra review attention on converter flushing, presentation duration and metadata. D receives extra review attention on stale completions and all user-visible model states. Preserve an existing Conductor feature branch rather than renaming it; the named branch is for a workspace that still needs one.

**Build-project overlap:** the source responsibilities are independent, but this repository tracks an explicit `project.pbxproj`, not synchronized filesystem groups. Every new Swift file must enter its target. A changes `project.yml` for the C target and regenerates once after adding A's files. B/C/D register their new Swift sources and tests in the tracked Xcode project without repeated XcodeGen runs. Use the existing locked `xcodeproj` Ruby gem or equivalent Xcode project editing; preserve both sides' additions when merging generated-project conflicts. This is a mechanical merge seam, not an audio/storage dependency. On this Mac, `rbenv exec bundle exec ruby -e 'require "xcodeproj"; puts Xcodeproj::VERSION'` succeeds (1.27.0); bare `bundle` selected system Ruby and failed. Use `rbenv exec make test` if the shell lacks rbenv shims. Do not update Gemfile.lock to fix that PATH issue.

The first PR carries the committed planning documents into main. B reads the pinned planning commit without cherry-picking the documents, avoiding duplicate ownership. Later briefs use the documents merged with A. The live orchestration state, PR URLs and reports belong in `.context/orchestrate-feature/graph.md`; that file is not product state.

## File map

Paths below are repository-relative. Keep new test suites in the existing app test target.

| PR | Create | Modify |
| --- | --- | --- |
| A policy | `QuickInterviewEditor/QuickInterviewEditor/Models/Mastering/MasteringFormat.swift`; `MasteringEligibility.swift`, `MasteringSnapshot.swift`, `MasteringInputsDigest.swift`, `MasteringParts.swift` in that same directory | `QuickInterviewEditor/QuickInterviewEditor/Models/SliceRenderPlan.swift`; `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` (shared exportability helper only) |
| A audio | `QuickInterviewEditor/QuickInterviewEditor/Core/Mastering/LoudnessClient.swift`; `LoudnessMeter.swift`, `MasteringConformer.swift`, `MasteringAudioClient.swift` in that same directory; `QuickInterviewEditor/Vendor/libebur128/ebur128/ebur128.c`, `ebur128.h`; `QuickInterviewEditor/Vendor/libebur128/include/module.modulemap`; `QuickInterviewEditor/Vendor/libebur128/COPYING`; `QuickInterviewEditor/Vendor/libebur128/VENDORED.md` | `QuickInterviewEditor/QuickInterviewEditor/Core/ExportRenderClient.swift`; `QuickInterviewEditor/project.yml`; `QuickInterviewEditor/PlayolaInterviewEditor.xcodeproj/project.pbxproj` |
| A tests | `QuickInterviewEditor/QuickInterviewEditorTests/Mastering/LoudnessMeterTests.swift`; `MasteringConformerTests.swift`, `MasteringEligibilityTests.swift`, `MasteringPartPackingTests.swift`, `MasteringLRCTests.swift`, `MasteringInputsDigestTests.swift`, `MasteringPreparationTests.swift`, `MasteringPolicyTests.swift` in that same directory | `QuickInterviewEditor/QuickInterviewEditorTests/Core/ExportAudioRendererTests.swift`; existing export/render-plan suites when adding regressions |
| B | `QuickInterviewEditor/QuickInterviewEditor/Models/MasteringRun.swift`; `QuickInterviewEditor/QuickInterviewEditor/Core/MasteringStaging.swift`; `QuickInterviewEditor/QuickInterviewEditor/Core/MasteringStagingClient.swift`; `QuickInterviewEditor/QuickInterviewEditorTests/Mastering/MasteringRunTests.swift`; `QuickInterviewEditor/QuickInterviewEditorTests/Mastering/MasteringStagingTests.swift` | `QuickInterviewEditor/QuickInterviewEditor/Models/ProjectFile.swift`; `Models/EditorDocumentState.swift`, `Models/ProjectDocumentSink.swift`, `Core/ProjectPackage.swift`, `Documents/ProjectDocument.swift`, `Views/Pages/Project/ProjectModel.swift`, `Views/Pages/Project/ProjectHostView.swift`, `Views/Pages/AppLaunch/AppLaunchModel.swift` under the same app source root; `QuickInterviewEditor/QuickInterviewEditorTests/Models/ProjectFileTests.swift`; `QuickInterviewEditor/QuickInterviewEditorTests/Core/ProjectPackageTests.swift`; `QuickInterviewEditor/QuickInterviewEditorTests/Documents/ProjectDocumentTests.swift`; `QuickInterviewEditor/QuickInterviewEditorTests/Project/ProjectModelTests.swift`; `QuickInterviewEditor/QuickInterviewEditorTests/Project/ProjectDocumentSinkRecorder.swift`; tracked Xcode project |
| C | `QuickInterviewEditor/QuickInterviewEditor/Core/Mastering/MasteringReturnClient.swift`; `MasteringAACEncoder.swift` in that directory; `QuickInterviewEditor/QuickInterviewEditor/Models/Mastering/MasterReturnMatching.swift`; `QuickInterviewEditor/QuickInterviewEditorTests/Mastering/MasterReturnMatchingTests.swift`; `MasteringReturnTests.swift`, `MasteringAACEncoderTests.swift` in that test directory | A's converter only if a demonstrated return fixture exposes a bug; tracked Xcode project |
| D | `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Mastering/MasteringPageModel.swift`; `MasteringPageView.swift` in that directory; `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Mastering/MasteringPageTests.swift` | `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Project/ProjectModel.swift`; `Views/Pages/Project/ProjectView.swift`, `Views/Pages/Editor/EditorView.swift`, `Core/WorkspaceClient.swift`, `Core/ExportCopyClient.swift`, `Models/ExportNaming.swift`, `Views/Pages/Editor/ExportReviewModel.swift` under the same app root; existing `QuickInterviewEditor/QuickInterviewEditorTests/Models/ExportNamingTests.swift`, `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/ExportReviewTests.swift`, project-model tests; tracked Xcode project |

A's snapshot must be Sendable without introducing unchecked mutable audio state. Prefer carrying `AudioEditRenderPlan`, edited duration and frozen markers as values across the worker boundary; the `SliceRenderPlan` local timeline can stay on the snapshot-building side. Check actual compiler conformance before dispatching; do not add `@unchecked Sendable` to a mutable converter or AVAudioFile.

## Acceptance coverage map

| Approved requirement | Primary PR | Required evidence |
| --- | --- | --- |
| Built-in intro eligibility, explicit-ID precedence, legacy fallback | A, B | Pure selection tests; legacy backfill before retranscription clears suggestions |
| Saved-project/artist/title guards; counts/exclusions; pending edit guard | D | Model tests for each guard and no side effects on failure |
| Exact removals/crossfades/declicks; mono/stereo; arbitrary supported source rates | A | Existing renderer suites plus native-rate and converted PCM fixtures |
| Constant loudness gain, peak ceiling, no trim/gaps, 50-minute packing | A | Meter reference, gain cases, boundary lengths, written offsets, joined peak validation |
| LRC starts, same rounded timestamp order, Unicode and large payload | A, C | Pure serialization tests; production writer and independent parser round trip |
| Lossless return formats, <5-second matching, ambiguity and replacement | C, D | Decode fixtures, candidate tests, serialized drop queue and explicit replacement tests |
| No alignment, exact saved ranges, reject shortfall, ignore extra tail | C | Rate-roundtrip and one-frame-short fixtures; no offset compensation |
| AAC 256k/44.1k/stereo; Artist/Title/LRC; playback duration | C | Settings inspection, independent metadata readback and impulse tests |
| Durable single run, part-atomic progress, editor changes do not rewrite it | B, D | Save/reopen partial run, editor undo/retranscription, failed replacement tests |
| Old schemas, conditional schema 3, malformed derived files recover locally | B | Full package/document/project regressions and malformed manifest/media fixtures |
| Save As/Duplicate without opening sheet; safe saves; snapshot lifetime | B | Real package writes with retained old snapshots and immutable media identities |
| Stable browser drag sources; cancellation/teardown | B, D | Lifetime tests, awaited worker cancellation and actual browser QA |
| Asked destination/default sibling folder, no overwrite, retry partial copy | D | Existing naming/review/copy suites and model cancellation/race tests |
| Spotlight route preserved | A, D | Full existing export suites, marker-injection assertions and manual AIFF export |

No network client or database change belongs to any PR. The final contract trace is local: frozen edited inputs → actual PCM frames → manifest ranges → returned PCM → AAC metadata → document artifacts → reviewed destination copy.

## Implementation contracts and algorithms

The declarations below specify the interfaces owned by each PR; function signatures are contracts, with behavior and TDD steps defined alongside them. Each Swift implementation file imports the frameworks its declarations use (Foundation, AVFoundation, CryptoKit, Dependencies as applicable). They are not a generated application or a substitute for compiling against the repository. All dependency clients require live/test values and DependencyValues accessors following existing clients.

## Shared constants (A, `Models/Mastering/MasteringFormat.swift`)

```swift
enum MasteringFormat {
  static let sampleRate = 44_100
  static let channels = 2
  static let partLimitFrames = 3_000 * sampleRate
  static let targetLUFS = -16.0
  static let truePeakCeilingDBTP = -1.5
  /// Initial acceptance tolerance; validate against the independent reference in A6. Never silently widen.
  static let truePeakToleranceDB = 0.1
  static let aacBitRate = 256_000
  static let masterDurationToleranceSeconds = 5.0  // strictly less than
  /// AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) — deinterleaved Float32.
  static var processingFormat: AVAudioFormat { .init(standardFormatWithSampleRate: 44_100, channels: 2)! }
}
```

## Contracts

### A — pure intro model (`Models/Mastering/`)

```swift
// MasteringEligibility.swift
enum MasteringExclusionReason: Equatable, Sendable { case notIntro, fullyRemoved }
struct MasteringExclusion: Equatable, Sendable { var sliceID: Slice.ID; var name: String; var reason: MasteringExclusionReason }
struct MasteringEligibility: Equatable, Sendable {
  var intros: [Slice]              // exportable intros, editor (document) order
  var blankTitledIntroIDs: [Slice.ID]  // subset of intros; blocks preparation
  var excluded: [MasteringExclusion]
}
enum MasteringEligibilityRule {
  /// Explicit `suggestionTypeID`, then `suggestionNaming?.typeID`, then (legacy, read-only) an
  /// accepted `cutSuggestions[id: slice.id]` → `naming?.typeID ?? productType.rawValue`.
  static func typeID(of slice: Slice, in document: EditorDocumentState) -> String?
  static func evaluate(_ document: EditorDocumentState) -> MasteringEligibility   // typeID == ProductType.intro.rawValue
}
```

- The legacy fallback here is read-only.
- `EditorDocumentState.init(from:)` already backfills `suggestionTypeID` on decode for accepted suggestions with `naming == nil`. Task B5 adds the one missing persisted backfill, at the only place suggestions are dropped: `rekeyed(to:)`.
- "Exportable" means the same thing as `EditorModel.sliceIsExportable`. A adds `SliceRenderPlanBuilder.hasAudio(sliceRange:removals:) -> Bool` and turns `sliceIsExportable` into a one-line delegation to it, so the two can't drift.

```swift
// MasteringSnapshot.swift — the frozen input, built on the main actor, consumed off it
struct MasteringPieceInput: Equatable, Sendable {
  var sliceID: Slice.ID
  var title: String                // frozen original text; validate trimmed nonempty, never sanitize tags
  var render: AudioEditRenderPlan  // SliceRenderPlanBuilder.plan(...).plan
  var editedDurationSamples: Int
  var sourceRange: Range<Int>
  var localRemovals: [TimelineRemoval] // rebased snapshot values used by the stable digest
  var wordStarts: [RenderMarker]   // SliceRenderPlanBuilder.markers(...) — edited-local, source-rate, tie-nudged
}
struct MasteringSnapshot: Equatable, Sendable {
  var artist: String
  var canonicalAudioURL: URL       // the session copy (ephemeral)
  var sourceSampleRate: Int        // ProjectSource.sampleRate / EditPlan.source.sampleRate
  var sourceDurationSamples: Int
  var pieces: [MasteringPieceInput]
  var inputsDigest: String
}
enum MasteringBlocker: Error, Equatable, Sendable {
  case notLoaded, unsaved, missingArtist, pendingEdit, invalidTimeline, noIntros, blankTitles([Slice.ID])
}
enum MasteringSnapshotBuilder {
  static func build(
    document: EditorDocumentState, plan: EditPlan, source: ProjectSource, canonicalAudioURL: URL
  ) -> Result<MasteringSnapshot, MasteringBlocker>   // covers missingArtist/noIntros/blankTitles only
}

// MasteringInputsDigest.swift
enum MasteringInputsDigest {
  /// "v1:" + SHA256 hex (CryptoKit) of JSONEncoder(.sortedKeys) over a private Codable:
  /// canonicalFingerprint, artist, and per eligible intro in order:
  /// sliceID, range, title, typeID, the rebased local removals (range + crossfade), and the
  /// mapped wordStarts (position + text). Nothing outside eligible intro ranges.
  static func make(source: ProjectSource, artist: String, pieces: [MasteringPieceInput],
                   typeIDs: [Slice.ID: String]) -> String
}

// MasteringParts.swift
enum MasteringPartPacking {
  /// Start a new part when the current one is nonempty and adding `next` would exceed `limit`.
  static func pack(_ frameCounts: [Int], limit: Int = MasteringFormat.partLimitFrames) -> [Range<Int>]
}
enum MasteringFrames {
  /// Round-half-up rescale used for word starts: (x * 44_100 + rate/2) / rate, in Int64.
  static func conformed(_ frames: Int, fromRate rate: Int) -> Int
}
enum MasteringLRC {
  /// One line per word, "[m+:ss.cc]text\n". Centiseconds = (frame*100 + 22_050) / 44_100.
  /// Minutes are unbounded (no wrap at 100). \r\n, \r, \n and U+2028/2029 become " "; text is trimmed; empty text lines are dropped.
  static func text(wordStarts: [(frame: Int, text: String)]) -> String
}
enum MasteringGain {
  /// min(-16 - L, -1.5 - P); undefined L never amplifies. Negative-infinite P is silence; NaN/+infinity fails.
  static func decibels(integratedLUFS: Double, truePeakDBTP: Double) throws -> Double
}
```

### A — audio (`Core/Mastering/`)

```swift
// LoudnessClient.swift — injected boundary; the C meter below is its private live implementation.
struct LoudnessMeasurement: Equatable, Sendable {
  var integratedLUFS: Double
  var truePeakDBTP: Double
}
struct LoudnessClient: Sendable {
  var measure: @Sendable (URL) async throws -> LoudnessMeasurement
}
// LoudnessMeter.swift — non-Sendable C-state owner, used on one worker only.
final class LoudnessMeter {
  enum Mode { case integratedAndTruePeak, truePeakOnly }
  init(channels: Int, sampleRate: Int, mode: Mode) throws  // MasteringPreparationError.meterUnavailable
  func add(_ buffer: AVAudioPCMBuffer) throws              // ebur128_add_frames_float (interleaves)
  func integratedLUFS() throws -> Double                   // may be -.infinity
  func truePeakDBTP() throws -> Double                     // max over channels, 20*log10
}

// MasteringConformer.swift — shared by A (render→44.1 stereo) and C (return→44.1 stereo)
final class MasteringConformer {
  init(inputFormat: AVAudioFormat) throws   // channelCount ∉ {1,2} → .unsupportedChannelCount
  /// Pushes one input chunk; emitted output chunks go to `sink` in MasteringFormat.processingFormat.
  func push(_ input: AVAudioPCMBuffer, sink: (AVAudioPCMBuffer) throws -> Void) throws
  /// Signals end of stream and drains until the converter reports .endOfStream.
  func finish(sink: (AVAudioPCMBuffer) throws -> Void) throws
  private(set) var outputFrameCount: Int
}
// Same rate and stereo → copy through with no converter. Mono → channelMap [0, 0].
// Each input buffer is supplied exactly once (the recipes doc, step 1).

// ExportAudioRenderer refactor (ExportRenderClient.swift). ExportRenderClient/ExportRenderJob unchanged.
extension ExportAudioRenderer {
  /// Validates the file against expected frames/rate (same errors as today) and returns it open.
  static func openCanonical(_ url: URL, sampleRate: Int, sourceDurationSamples: Int) throws -> AVAudioFile
  /// The existing segment/seam/declick loop, emitting processing-format chunks instead of writing a file.
  static func renderEdited(
    from file: AVAudioFile, plan: AudioEditRenderPlan, editedDurationSamples: Int, sampleRate: Int,
    emit: (AVAudioPCMBuffer) throws -> Void) throws -> Int   // frames emitted; throws shortRender
}
// render(_ job:) becomes openCanonical + AVAudioFile(forWriting:) + renderEdited(emit: output.write).

// MasteringAudioClient.swift
struct MasteringPreparationRequest: Equatable, Sendable {
  var snapshot: MasteringSnapshot
  var workDirectory: URL   // caller-owned, empty; the client writes only inside it
  var partLimitFrames: Int = MasteringFormat.partLimitFrames // deterministic small packing fixtures
}
struct PreparedPiece: Equatable, Sendable {
  var sliceID: Slice.ID; var title: String
  var startFrame: Int; var frameCount: Int     // part-relative, 44.1 kHz, actual written counts
  var lrc: String
}
struct PreparedPart: Equatable, Sendable {
  var wavURL: URL; var frameCount: Int; var byteCount: Int; var pieces: [PreparedPiece]
}
enum MasteringPreparationWarning: Equatable, Sendable {
  case overlongPiece(title: String, seconds: Double)
  case peakLimitedGain(title: String, appliedDB: Double, loudnessDB: Double)
}
struct MasteringPreparationResult: Equatable, Sendable {
  var parts: [PreparedPart]; var warnings: [MasteringPreparationWarning]; var inputsDigest: String
}
struct MasteringPreparationProgress: Equatable, Sendable { var completedPieces: Int; var totalPieces: Int }
struct MasteringAudioClient: Sendable {
  var prepare: @Sendable (MasteringPreparationRequest,
                          @escaping @Sendable (MasteringPreparationProgress) -> Void) async throws
    -> MasteringPreparationResult
}
enum MasteringPreparationError: Error, Equatable, LocalizedError {
  case unsupportedChannelCount(Int)
  case invalidLoudnessMeasurement
  case conversionFailed(String)
  case meterUnavailable
  case meterFailed(title: String)
  case truePeakCeilingExceeded(part: Int, measuredDBTP: Double)
  case partTooLarge(part: Int)          // > 4 GiB RIFF limit
  case noPieces
}
// ExportRenderError from the shared renderer propagates unchanged.
```

**Live `prepare` algorithm.** Run detached with cancellation forwarded as in `ExportRenderClient.liveValue`. Capture dependency clients before detaching. Never retain a whole piece or part in RAM.

1. For each frozen piece, `renderEdited` emits bounded buffers through `MasteringConformer` into a temporary Float32 stereo 44.1 kHz CAF. Flush and finalize it. The converter's actual written frame count is authoritative.
2. Stream that CAF through `LoudnessClient.measure`. Validate measurements and compute fixed gain. A non-finite integrated loudness never triggers amplification; NaN or positive-infinite peak is an error, negative-infinite peak is digital silence.
3. Use actual frame counts to pack whole pieces into parts. Stream the CAF through fixed linear gain into a native 24-bit PCM WAV writer; delete the CAF after consumption. Do not implement a second hand-written quantizer. Keep source silence and rendered boundaries. The first piece starts at zero and each subsequent piece starts at the previous piece's written end.
4. Finalize each part WAV, then stream-read the actual written samples with a fresh meter, including joins. Reject a peak above −1.5 dBTP plus the validated 0.1 dB tolerance. Do not insert a limiter, change gain silently or widen tolerance to pass a fixture. This readback also verifies rate, channels, PCM depth, frame count and file byte count.
5. Rescale mapped word starts using the source rate and round-half-up arithmetic. Omit any rounded position outside the actual piece, rather than moving it to another time. Serialize LRC after this mapping; the part offset never enters piece-local lyrics.
6. Return all completed parts together. On any error/cancellation, return no success; the caller removes its work directory and retains the previous durable run. Emit overlong-piece and peak-limited-gain warnings for the model to display.

Reject unsupported channel counts, invalid source geometry, non-finite PCM, converter failure, a RIFF-size limit exceeded by a single overlong piece, short reads/writes and disk failures. Never report ready based only on a path existing. Check cancellation between buffers, conversion calls and parts.

### B — durable manifest (`Models/MasteringRun.swift`)

```swift
struct MasteringArtifactRef: Codable, Hashable, Sendable {
  var fileName: String   // "<lowercased UUID>.wav" | ".m4a": fresh UUID per written artifact, never reused
  var byteCount: Int
  var isWellFormed: Bool { get } // implementation below
}
struct MasteringPiece: Codable, Equatable, Sendable, Identifiable {
  var id: UUID; var sliceID: UUID; var title: String
  var startFrame: Int; var frameCount: Int; var lrc: String
  var finished: MasteringArtifactRef?
}
struct MasteringPart: Codable, Equatable, Sendable, Identifiable {
  var id: UUID; var frameCount: Int
  var prepared: MasteringArtifactRef?   // nil = unavailable for drag → offer Prepare Again
  var pieces: [MasteringPiece]
  var isReturned: Bool { !pieces.isEmpty && pieces.allSatisfy { $0.finished != nil } }
}
struct MasteringRun: Codable, Equatable, Sendable {
  var id: UUID; var artist: String; var inputsDigest: String; var parts: [MasteringPart]
  var referencedArtifacts: Set<MasteringArtifactRef> { get }
  /// Clears every ref that is malformed or whose name/size isn't in `available`. Parts and pieces
  /// are kept, so a missing derived file heals individually.
  func healed(available: [String: Int]) -> MasteringRun
}
extension ProjectFile {
  // Stored property on the struct: `var masteringRun: MasteringRun? = nil` (the default keeps every
  // existing memberwise call site compiling). The lenient `init(from:)` goes in an EXTENSION so the
  // memberwise init survives: `masteringRun = (try? c.decodeIfPresent(MasteringRun.self, forKey: .masteringRun)) ?? nil`.
  static let maximumReadableSchemaVersion = 3
  static func writtenSchemaVersion(for file: ProjectFile) -> Int   // run == nil ? 2 : 3
}
```

**Immutable identity.** Every artifact written gets a fresh UUID file name. A package path therefore never changes content. Matching on name plus byte count is then enough, because the same name always means the same bytes. A same-size replacement always has a new name.

### B — staging owners (`Core/MasteringStaging.swift`, `Core/MasteringStagingClient.swift`)

```swift
/// Scoped owner of one session file. It is deleted when the last holder (the document's `Content`,
/// a save `Snapshot`, or a model's drag/save copy) releases it. Swift ARC does the counting; there is no framework.
final class StagedMasteringArtifact: Sendable, Equatable {
  let url: URL
  init(url: URL) { self.url = url }
  deinit { try? FileManager.default.removeItem(at: url) }
  static func == (lhs: StagedMasteringArtifact, rhs: StagedMasteringArtifact) -> Bool { lhs === rhs }
}
enum MasteringStagingStore {  // Caches/<AppDirectories.folderName>/Mastering/<session UUID>/
  static func baseDirectory() throws -> URL
  static func reapStale(olderThan: TimeInterval = CanonicalAudioStore.staleAfter, in: URL? = nil, now: Date = Date())
}
struct MasteringStagingClient: Sendable {
  var makeWorkDirectory: @Sendable () throws -> URL
  /// Moves `url` into the session dir as `name` (a UUID artifact name) and returns its owner.
  var adopt: @Sendable (_ url: URL, _ name: String) throws -> StagedMasteringArtifact
  /// Clones (APFS) or copies into its own dir under `displayName`; used for drag and final save.
  var sessionCopy: @Sendable (_ source: URL, _ displayName: String) async throws -> StagedMasteringArtifact
  var removeDirectory: @Sendable (URL) -> Void
}
```

`AppLaunchModel` calls `MasteringStagingStore.reapStale()` next to `CanonicalAudioStore.reapStale()` (AppLaunchModel.swift:39).

### B — document boundary

```swift
struct Content: Equatable, Sendable {           // ProjectDocument.Content
  var file: ProjectFile; var plan: EditPlan; var audio: CanonicalAudioSource; var recoveryArchive: Data?
  var masteringStaged: [String: StagedMasteringArtifact] = [:]   // fileName → owner; only referenced names
}
struct Snapshot: Sendable { var content: Content; var editGeneration: Int }
// makeFileWrapper retains its existing snapshot/existingFile signature.
// ProjectDocumentSink gains:
var commitMastering: @MainActor @Sendable (ProjectFile, [String: StagedMasteringArtifact]) -> Void = { _, _ in }
```

**Save As / Duplicate without opening the mastering sheet.** At the document read boundary, copy each valid referenced mastering child into owned session staging, then put its owner in `Content.masteringStaged`. Document reading runs off the main actor. Use the existing lazy `FileWrapper` file-writing path into staging; never request a large child's `regularFileContents`. If an actual source URL is available, clone when supported and fall back to copying. ReadConfiguration does not promise a source URL, so cloning is an optimization, not a prerequisite.

All mastering artifacts, including ones loaded from a package, now have stable session owners before any snapshot can need them. `Content`, `Snapshot`, active workers and drag/export leases retain the relevant owners. Replacing a run removes names from the current content but old snapshots retain old owners. Save As/Duplicate writes from these session files; it never depends on a path inside a live package surviving a safe-save. Ordinary saves still reuse matching existing child wrappers. No mastering-sheet hydration or new package-location fallback is needed. Preserve the canonical-audio path's existing hydration/lifetime contract; do not fold an unrelated canonical-audio redesign into B.

A read failure in one derived artifact heals that reference only and reports its part as needing preparation/return. A staging-volume failure must not silently delete a valid run; surface it and prevent publishing a false ready/saved result. Exercise copy failure and large-file memory behavior in B's tests/manual check. Do not promise zero-copy behavior on non-APFS volumes.

### Reconcile algorithm (`ProjectPackage.reconcileMastering`)

```
input: run: MasteringRun?, existingRoot: FileWrapper?, staged: [String: StagedMasteringArtifact]
available := {}                                   // name → wrapper to place
existingDir := existingRoot?["mastering"] if isDirectory else nil
for ref in run?.referencedArtifacts ?? []:
  if let child = existingDir?[ref.fileName], child.isRegularFile, size(child) == ref.byteCount → available[name] = child (same object)
  elif let s = staged[ref.fileName], fileSize(s.url) == ref.byteCount → available[name] = FileWrapper(url: s.url, options: [])
  // else: missing; clear only the unavailable reference, never invent media
healedRun := run?.healed(available: available.mapValues(size))   // encoded into project.json
in place (existingRoot != nil):
  if existingRoot["mastering"] exists and is not a directory → remove it
  if available empty → remove "mastering" child entirely
  else ensure directory; remove every child whose name ∉ available (junk, old runs, replaced pieces);
       add the wrappers not already parented there (preferredFilename = name)
fresh encode: FileWrapper(directoryWithFileWrappers: available) when nonempty
```

- `size(child)` uses file attributes for disk-backed wrappers. Small in-memory test wrappers may use their already-resident bytes. Never load an on-disk WAV into Data merely to count it. Validate regular-file type and reject symlinks before copying or resolving a reference.
- `ProjectPackage.decode` never throws for mastering. It computes `available` from the `mastering` dir's regular children, using attributes only, and returns `file` with `masteringRun?.healed(available:)`.
- It forces `masteringRun = nil` when `schemaVersion < 3`.
- It accepts versions `1...maximumReadableSchemaVersion`.
- The `unsupportedSchema` messages compare against `maximumReadableSchemaVersion`.
- `makeFileWrapper` stamps `writtenSchemaVersion(for: healed file)`.
- Keep the version-1 suggestion gate independent of the highest readable schema. `currentSchemaVersion` may remain the legacy edit-upgrade value 2; add `maximumReadableSchemaVersion = 3` for decode/error messages, and compute 2/3 at the save boundary from the actual run. Audit every stamp in `wireEditor`, `onExplicitSuggest`, retranscription and recovery so ordinary projects still write 2 and v1 automatic-suggestion behavior stays unchanged.

### C — return and encode (`Core/Mastering/MasteringReturnClient.swift`)

```swift
struct MasterInspection: Equatable, Sendable {
  var fileName: String; var sampleRate: Double; var channels: Int; var sourceFrames: Int
  var durationSeconds: Double { Double(sourceFrames) / sampleRate }
}
struct MasteredPieceTarget: Equatable, Sendable {
  var pieceID: UUID; var startFrame: Int; var frameCount: Int; var artist: String; var title: String; var lrc: String
}
struct MasteredPartTarget: Equatable, Sendable { var partFrameCount: Int; var pieces: [MasteredPieceTarget] }
struct EncodedPiece: Equatable, Sendable { var pieceID: UUID; var url: URL; var byteCount: Int }
struct MasteringReturnClient: Sendable {
  var inspect: @Sendable (URL) async throws -> MasterInspection
  /// Conforms the whole master once (streaming → work/<uuid>.caf, flushed count authoritative),
  /// validates ranges, then AAC-encodes each piece into workDirectory. Deletes the CAF.
  var encodePart: @Sendable (_ master: URL, _ target: MasteredPartTarget, _ workDirectory: URL) async throws -> [EncodedPiece]
}
enum MasteringReturnError: Error, Equatable, LocalizedError {
  case unreadable(fileName: String)                       // not decodable audio
  case unsupportedContainer(fileName: String)             // kAudioFilePropertyFileFormat ∉ WAVE/RF64/AIFF/AIFC/FLAC
  case unsupportedChannelCount(fileName: String, count: Int)
  case tooShort(fileName: String, frames: Int, required: Int)
  case encodeFailed(title: String, reason: String)
  case encodedLengthMismatch(title: String, expected: Int, actual: Int)
}
enum MasterReturnMatching {
  /// Unreturned parts with |seconds - partSeconds| < 5 (strict). For an explicit replace, `parts` is that one part.
  static func candidates(durationSeconds: Double, parts: [(id: UUID, frameCount: Int)]) -> [UUID]
}
```

**AAC writer.**
- `AVAssetWriter(.m4a)`. Input settings: `kAudioFormatMPEG4AAC`, 44,100 Hz, 2 channels, `AVEncoderBitRateKey: 256_000`.
- Metadata: `writer.metadata` gets `.iTunesMetadataArtist`, `.iTunesMetadataSongName` and `.iTunesMetadataLyrics`.
- Session: `startSession(atSourceTime: .zero)` … `endSession(atSourceTime: CMTime(value: frames, timescale: 44_100))`, then `markAsFinished`, then `await finishWriting()`. Check that `status == .completed`.
- Verify by reading back with `AVAudioFile(forReading:).length == frames`; otherwise throw `.encodedLengthMismatch`.
- On cancel or throw: `cancelWriting()` and delete the partial file.
- `required = max(start + count)` over the pieces. If `conformedFrames < required`, throw `.tooShort`. Audio past the end of the saved part is ignored.

### D — model, host wiring, UI extensions

```swift
// WorkspaceClient gains (existing chooseDirectory/reveal untouched):
var chooseDirectoryNear: @Sendable (_ suggested: URL?, _ prompt: String, _ message: String) async -> URL?
var createDirectory: @Sendable (URL) throws -> Void
var open: @Sendable (URL) -> Void   // NSWorkspace.shared.open

// ExportNaming / ExportCopyClient
struct ExportFileKind: Equatable, Sendable {
  var fileExtension: String; var forcesExactNames: Bool
  static let logicAIFF = ExportFileKind(fileExtension: "aiff", forcesExactNames: false)
  static let masteredM4A = ExportFileKind(fileExtension: "m4a", forcesExactNames: true)
}
// requestedExportName/exportFileName/preflightExportNames take `kind: ExportFileKind = .logicAIFF`;
// "exact" := kind.forcesExactNames || slice.suggestionNaming != nil (both for policy and for the
// confirmation/generated set, and in ExportCopyState.requiresNewApproval). ExportCopyRequest gains
// `var kind: ExportFileKind = .logicAIFF`. Mastering passes pseudo targets built with Slice's
// memberwise init: Slice(id: piece.id, name: piece.title, startSample: 0, endSample: 0, wordIDs: [], snippet: "").

// Views/Pages/Mastering/MasteringPageModel.swift
@MainActor @Observable final class MasteringPageModel: ViewModel, Identifiable {
  struct Host {                                   // supplied by ProjectModel; closures, never the sink
    var finishTitleEdit: @MainActor () -> Void
    var inputs: @MainActor () -> Result<MasteringSnapshot, MasteringBlocker> // pure read; safe for stale notice
    var eligibility: @MainActor () -> MasteringEligibility?
    var run: @MainActor () -> MasteringRun?
    var packageURL: @MainActor () -> URL?
    var artifact: @MainActor (MasteringArtifactRef) -> StagedMasteringArtifact?
    /// Returns false (no-op) when the current run id != expectedRunID.
    var commit: @MainActor (_ run: MasteringRun?, _ staged: [String: StagedMasteringArtifact], _ expectedRunID: UUID?) -> Bool
  }
  enum Activity: Equatable { case idle, preparing(completed: Int, total: Int), inspecting(fileName: String), returning(partID: UUID), copying }
  struct AmbiguousReturn: Equatable { var master: URL; var candidatePartIDs: [UUID] }
  struct DestinationPrompt: Equatable { var suggested: URL; var message: String }  // "Save to “mastered” next to “X.pie”?"
  private(set) var activity: Activity = .idle
  private var pendingMasterURLs: [URL] = [] // FIFO batch, retained through ambiguity resolution
  private(set) var confirmingPrepareAgain = false
  private(set) var ambiguousReturn: AmbiguousReturn?
  private(set) var replaceTargetPartID: UUID?
  private(set) var destinationPrompt: DestinationPrompt?
  var exportReview: ExportReviewModel?
  private(set) var savedFiles: [URL] = []
  private(set) var message: String?

  func prepareTapped() async            // blockers → message; existing run → confirmingPrepareAgain
  func prepareAgainConfirmed() async
  func prepareAgainCancelled()
  func cancelTapped() async              // cancels the active task and awaits it
  func openMasterchannelTapped()         // workspace.open(URL(string: "https://masterchannel.ai/studio")!)
  func dragURL(for partID: UUID) async -> URL?   // session copy "<project> – Part k of n.wav"
  func mastersDropped(_ urls: [URL]) async
  func ambiguousPartChosen(_ partID: UUID) async
  func ambiguousReturnCancelled()
  func replacePartTapped(_ partID: UUID)
  func saveFinalsTapped()                // → destinationPrompt
  func destinationSaveTapped() async     // createDirectory(mastered/) then copy
  func destinationChooseOtherTapped() async
  func destinationCancelTapped()         // files stay ready
  func showInFinderTapped()
  func teardown() async                  // cancel + await; drop drag/save copies
}
```

`ProjectModel` (D) owns `var mastering: MasteringPageModel?`:
- It's created in `hydrate()` / `loadCompletedTranscription` only if nil, so it survives editor rebuilds.
- `isMasteringSheetPresented` and `prepareForMasteringTapped()` present the sheet.
- `viewDisappeared` awaits `mastering?.teardown()` before `releaseSessionAudio()`. `tearDownEditor` also cancels and awaits current mastering work before rebuilding the editor for retranscription. Keep the durable run and model; invalidate task generations so cancelled progress/returns cannot publish afterward.
- `inputs` is:
  ```
  guard packageURL != nil                → .unsaved
  guard !editor.hasUncommittedSliceEdit  → .pendingEdit
  guard editor.editedTimeline.isValid    → .invalidTimeline
  MasteringSnapshotBuilder.build(document: editor.documentState, plan: loadedPlan, source: file.source,
                                 canonicalAudioURL: loadedAudio.sessionURL)
  ```

## Commit and ownership rules (B's API; D's use)

- **Source lookup.** `ProjectModel.masteringArtifact(_ ref: MasteringArtifactRef) -> StagedMasteringArtifact?` supplies retained owners to the host; no model resolves package paths directly. Pass initial `masteringStaged` through `ProjectHostView` into `ProjectModel`.
- **One writer path.** All run commits go through `ProjectModel.commitMastering(run:staged:expectedRunID:)`:
  - It checks `file?.masteringRun?.id == expectedRunID`.
  - It sets `self.file!.masteringRun = run`.
  - It computes `masteringStaged = (old ∪ new).filter { run.referencedArtifacts names contains key }`.
  - It calls `sink.commitMastering(file, masteringStaged)` and then `sink.registerChange()`.
- **Editor commits preserve the run.** Editor commits (`onDocumentStateChanged`, `onExplicitSuggest`, recovery) start from `self.file`, so the run is kept automatically.
- **Retranscription preserves the run.** It builds `ProjectFile(..., content:, masteringRun: file?.masteringRun)`. `ProjectDocument.commit` never touches `masteringStaged`.
- **Undo.** The run isn't part of `EditorDocumentState`, so editor undo can't touch it.
- **Old artifacts after a replacement.** Once the manifest and staged map change, the old run's staged owners live only as long as some in-flight `Snapshot` holds them. Package children disappear at the next reconcile.
- **Close during save.** `Snapshot.content.masteringStaged` retains all owners, including artifacts originally loaded from the package, so the close/`viewDisappeared` cleanup can't delete a file a save is still writing. This replaces relying on unverified close-save ordering for mastering files.

## Model state and cancellation (D)

- **Prepare.** One active task at a time.
  - Sequence: finish the title edit through the host action (existing `EditorModel.finishSliceNameEdit()`), then `inputs()` → `staging.makeWorkDirectory()` → `audio.prepare`, with progress hopping to the main actor → `adopt` each WAV as `<uuid>.wav` → build `MasteringRun(id: uuid(), …)` with `prepared` refs and `finished = nil` → `host.commit(expectedRunID: runAtStart?.id)`.
  - On cancel: activity `.idle`, message "Preparation cancelled. Your previous prepared run is unchanged.", work dir removed.
  - On `.truePeakCeilingExceeded`: message "Part k peaks at X dBTP, above the −1.5 dBTP ceiling. Nothing was changed." The old run stays.
  - If the commit returns false: delete the adopted owners (they are released) and show "The project changed while preparing; prepare again."
- **Drop.** An inspection/encoding/ambiguity sequence owns one serial batch queue. Rejected while another batch or activity is active ("Wait for the current step to finish."). Each URL is handled sequentially:
  - Set `.inspecting(fileName:)` before awaiting `inspect`. The view forwards URLs; a dependency boundary resolves drop-provider file URLs and retains or stages temporary representations while they are valid. Release transient masters only after their encode/cancel finishes.
  - Candidates = the replace target, if one is armed; otherwise the unreturned parts.
  - Zero candidates: "“x.wav” is 12:03, which doesn't match any part still needed (Part 1 12:40…)."
  - More than one: set `ambiguousReturn` and retain the rest of the batch. Choosing or cancelling this file resumes that queue; candidates are recomputed against the latest run before each assignment. Validate decoded container/rate/channels and duration again at encode time so a changed dropped file cannot bypass inspection.
  - Exactly one: `encodePart` → `adopt` each as `<uuid>.m4a` → commit with `expectedRunID: run.id`, setting all that part's `finished` refs at once. Commit only after every piece has succeeded.
  - A completed part is never matched unless the user explicitly chose to replace it.
- **Save.** The whole sequence:
  1. `saveFinalsTapped` requires every part `isReturned`.
  2. It sets `destinationPrompt(suggested: packageURL.deletingLastPathComponent()/mastered)`.
  3. **Save**:
     - `createDirectory` (only now).
     - Resolve each finished piece through the retained staged-owner map; clone/copy from that stable source when a separate display-named file is needed. Never read a drag/save source from inside the live package.
     - `ExportReviewModel(request: .init(targets: pseudoSlices, sourceStem: "", renderedByID:, destination:, kind: .masteredM4A), scratchDirectory: nil)`. `nil` is required: its `deinit` deletes the scratch dir.
     - Wire it like `EditorModel.finishExport`.
  4. **Choose Other…**: `chooseDirectoryNear(suggested, "Save Here", "Choose a folder for the mastered m4a files")`.
  5. **Cancel**: the prompt clears and the files stay ready.
  6. On completion: `savedFiles`, then **Show in Finder** (`workspace.reveal`).
- **Stale notice.** Compare the current pure snapshot digest with the frozen run; an unavailable/invalid current snapshot also produces the notice. Computing this display value must never finish edits or mutate document state.
- **Stale completion guard.** Every async continuation checks `runIDAtStart == host.run()?.id` and a model `generation` that `teardown` bumps.

## Tasks

Commands below run from `QuickInterviewEditor/`; the exact focused suites are listed with each PR.
- Before a PR: `make format-check && make lint && make test`.
- `make generate` only in A1.
- Every task uses `pfw-testing`, `pfw-custom-dump` and `pfw-dependencies`. Model tasks also invoke `pfw-observable-models`; the view task invokes `pfw-modern-swiftui`.

### PR A — "feature: prepare loudness-matched intro audio for mastering" (no UI)

**A1. Vendor libebur128.**
- `Vendor/libebur128/`: `ebur128/ebur128.c`, `ebur128/ebur128.h`, `COPYING`, `VENDORED.md` (URL, tag v1.2.6, commit `67b33abe1558160ed76ada1322329b0e9e058b02`), and `include/module.modulemap` (`module CEbur128 { header "../ebur128/ebur128.h" export * }`).
- `project.yml` adds target `CEbur128` (type `library.static`, sources = the `.c`). The app depends on it with `SWIFT_INCLUDE_PATHS: $(SRCROOT)/Vendor/libebur128/include`.
- Meter fixture: 997 Hz sine, stereo, 48 kHz, 20 seconds, amplitude 0.1. Independently measure and record the expected integrated loudness (approximately −20 LUFS for this stereo fixture); do not label it an EBU reference case without the actual reference. Use the verified expected value and tolerance in `LoudnessMeterTests`. On macOS upstream uses the system `<sys/queue.h>`; do not vendor an unused queue implementation.

**A2. `LoudnessMeter` + `MasteringGain`.** Tests:
- `expectNoDifference(try MasteringGain.decibels(integratedLUFS: -20, truePeakDBTP: -6), 4.0)`
- Peak-limited: `(-30, -3)` → `1.5`
- `(-.infinity, -10)` → `0`
- `(-.infinity, 0.5)` → `-2.0`
- `(-.infinity, -.infinity)` → `0`
- A 200 ms tone's `integratedLUFS()` is not finite, and `decibels` then never exceeds 0.
- Reference test: speech-like pink noise at a fixed seed checked against `ffmpeg -af ebur128=peak=true`. Record the version and value in the test comment. Tolerance ±0.1 LU and ±0.2 dBTP.

**A3. Renderer sink refactor.** No behaviour change. Run `ExportAudioRendererTests`, `SliceRenderPlanTests`, `CrossfadeRendererTests`, `DeclickFadeTests`, `EditorExportRemovalTests` and `ExportReviewTests` in full. Add `testRenderEditedEmitsSameSamplesAsRenderSlice` (render both ways over a fixture with a removal and a crossfade, then compare sample arrays).

**A4. `MasteringConformer`.** Tests:
- The recipe's 48 kHz impulse fixture gives exactly 88,200 frames, with peaks at `[441, 11025, 33075, 55125, 86877]` (±0).
- Mono 44.1 kHz input: L == R, and the count is unchanged.
- A 3-channel format throws `.unsupportedChannelCount(3)`.
- Lengths `{1023, 1024, 1025, 44_099, 44_101}` at 48 kHz give `outputFrameCount == MasteringFrames.conformed(n, fromRate: 48_000)` ±1. Use the observed exact value as the assertion, and document any ±1.

**A5. Pure intro model.**
- `MasteringEligibilityTests`:
  - `intro` explicit is included.
  - `suggestionNaming.typeID == "intro"` with a nil explicit ID is included.
  - Explicit `"spotlight"` with naming `"intro"` is excluded (explicit wins).
  - A spotlight named "Intro to Jazz" is excluded.
  - A custom type in `.songIntros` group is excluded.
  - Untyped manual → `.notIntro`.
  - A legacy accepted suggestion where `naming != nil` and the slice has neither field is included.
  - A fully removed intro → `.fullyRemoved`.
  - `"  "` title → `blankTitledIntroIDs`.
  - Order follows the document.
- `MasteringPartPackingTests`: `pack([a,b])` where a + b == limit → one part. a + b == limit + 1 → two parts. `[limit*2]` → one part. `[]` → `[]`. No empty trailing part.
- `MasteringLRCTests`:
  - `[(0,"Hello"),(26_901,"world")]` → `"[00:00.00]Hello\n[00:00.61]world\n"`.
  - Two frames rounding to the same centisecond keep their order.
  - `"a\nb"` → `"a b"`.
  - 6000 s → `"[100:00.00]"`.
  - 5,000 entries keep their count.
- `MasteringInputsDigestTests` (the private digest descriptor also records explicit/naming/legacy provenance used for the selection):
  - Renaming a spotlight doesn't change the digest.
  - Adding a removal inside a spotlight doesn't change it.
  - Renaming an intro changes it.
  - Changing the artist changes it.
  - Two calls produce identical strings with a `"v1:"` prefix.

**A6. `MasteringAudioClient.liveValue` integration** (`MasteringPreparationTests`, real files in a temp dir, no mocks):
- 48 kHz mono, two intros of 3 s and 4 s → one part:
  - `frameCount == sum(pieces.frameCount)`.
  - `pieces[1].startFrame == pieces[0].frameCount`.
  - The WAV reads back at 24-bit, 44.1 kHz, 2 channels, with `length == frameCount`.
- A marker whose rescaled position equals the piece length is omitted (exclusive end), never clamped onto its last frame.
- A tiny `partLimitFrames` override on the request (internal parameter, default `MasteringFormat.partLimitFrames`) splits into two parts.
- A deterministic high-crest-factor transient fixture (and an injected `LoudnessMeasurement(-30 LUFS, -3 dBTP)` unit test) exercises peak-limited gain. Reading back the quantized WAV and measuring it with a fresh `LoudnessMeter(.truePeakOnly)` gives ≤ −1.5 + `truePeakToleranceDB`. **This locks the tolerance.**
- Validation path: a piece whose written TP exceeds the ceiling makes `prepare` throw `.truePeakCeilingExceeded`.
- Cancel after the first progress callback → `CancellationError`. Only `workDirectory` contents exist, and the caller's cleanup removes them.

### PR B — "feature: keep mastering work inside saved projects" (no UI)

**B1. `MasteringRun` + `ProjectFile` field + schema split.** `ProjectFileTests`:
- A v2 JSON decodes with a nil run.
- v3 with a run round-trips.
- A malformed `masteringRun` value decodes as a nil run.
- `writtenSchemaVersion`: 2 with no run, 3 with one.
- `MasteringRunTests.healedClearsOnlyMissingRefs`: part 1's WAV is present and one of its two pieces is missing, so exactly that piece's `finished` becomes nil. Malformed `fileName: "../x.wav"` → nil.

**B2. `StagedMasteringArtifact` + staging store/client.**
- `testSnapshotKeepsReplacedArtifactReadable`: hold a source in a save snapshot, release the current run and model ownership, then complete a real package write from the old snapshot. Verify original bytes survive; releasing the final owner cleans the staged file.
- `reapStale` follows the `CanonicalAudioStoreTests` pattern but excludes live session directories; an old, still-open document must not lose its staged files when another process launches.

**B3. Package reconcile + decode heal.** `ProjectPackageTests`:
- An in-place save with an unchanged run returns the **identical** `mastering` child wrapper objects (`===`).
- A replaced run removes old names and adds new ones. `audio/canonical.aiff` and `suggestion-recovery.json` are untouched.
- A same-size replacement with a new UUID name gets the new name, and the old one is removed.
- A `mastering` regular file at the root is removed, and the open does not throw.
- A run of nil removes `mastering`.
- Decode with a missing piece gives a healed file.
- Version 4 → `unsupportedSchema(4)`.

**B4. Document boundary.** `ProjectDocumentTests`:
- **`testSaveAsWithoutMasteringSheetCarriesMastering`**:
  1. Write a real package (valid tiny canonical audio plus a `mastering/<uuid>.wav`) to a temp dir.
  2. Run `ProjectDocument(reading: FileWrapper(url: pkg, options: []))`.
  3. Supply canonical audio through the existing document hydration seam, without creating a mastering page. Call `makeFileWrapper(snapshot: content, existingFile: nil)` and `write(to: newURL, options: .atomic, originalContentsURL: nil)`.
  4. Assert that both files exist byte-equal at `newURL`, and that the decoded manifest is unchanged.
- `testSnapshotSurvivesOldPackageReplacement`: snapshot a loaded run, replace it and safe-save the live project, then save the old snapshot to a different package. Its original mastering files still exist through their retained owners. Delete the original package and repeat Save As from retained session artifacts.
- `testSnapshotKeepsStagedArtifactAliveAfterDocumentReleased`: take a snapshot, set `document.content = nil` and release the model, then `makeFileWrapper` from the snapshot still writes the staged bytes.
- `ProjectHostView` passes `content.masteringStaged` into `ProjectModel`, which retains and forwards these owners. No package-URL snapshot fallback is added.

**B5. ProjectModel API + carry-forward + legacy backfill.** Uses `ProjectModelTests` / `ReTranscribeIdentityTests` with `ProjectDocumentSinkRecorder`:
- `commitMastering` with a matching `expectedRunID` records one `commitMastering` plus one `registerChange`. A mismatched ID records nothing and returns false.
- A run, then an editor rename (`onDocumentStateChanged`), then `editor.undoTapped()`: the last committed file still has the same run.
- A bundled retranscribe keeps `masteringRun` on the committed `ProjectFile`.
- `EditorDocumentStateTests.testRekeyedPersistsLegacyIntroProvenanceBeforeDroppingSuggestions`: an accepted suggestion with `naming.typeID "intro"` and a slice with neither field. After `rekeyed(to:)`, `slices[id:].suggestionTypeID == "intro"` and `cutSuggestions` is empty.
- Run the full `Project/`, `Documents/`, `ProjectPackageTests`, `ProjectFileTests` and `EditorDocumentStateTests` suites.

### PR C — "feature: split mastered audio into tagged m4a files" (after A)

**C1. `MasterReturnMatching`.**
- 600 s vs parts 604.9 s and 700 s → `[p1]`.
- A difference of exactly 5.0 → `[]`.
- Two parts within 5 s → both.
- Returned parts are excluded unless passed as a replace target.

**C2. `inspect`.**
- WAV, AIFF and FLAC fixtures (written with AVAudioFile, FLAC via `kAudioFormatFLAC`) all pass.
- Renaming an m4a to `.wav` → `.unsupportedContainer`.
- Random bytes → `.unreadable`.
- 6-channel WAV → `.unsupportedChannelCount`.

**C3. AAC writer + `encodePart`.**
- Recipe fixture: playback length is exactly 88,200 frames and all five impulses match the recorded expected positions. Keep this measured fixture distinct from unverified claims about every lossy decode.
- `AVURLAsset` duration is 2.0 s.
- Metadata round-trips `©ART`, `©nam` and `©lyr` byte-exactly, including a 5,000-entry Unicode LRC.
- Lengths `{1023, 1024, 1025, 2047, 44_100}` each read back exactly.
- A 44.1 → 48 → 44.1 round trip of a 3-piece part: every piece's impulse lands in the expected piece-local frame.
- The same master with its last frame removed → `.tooShort(required:)`.
- An extra 2 s tail is ignored (the lengths are unchanged).
- Cancelling mid-encode cancels the writer and removes partial outputs; caller cleanup removes the batch work directory. No durable part commit occurs.
- Independent development check, recorded with the PR (Node/ffmpeg need not be CI dependencies): the recipe's `music-metadata@11.16.1` script and `ffmpeg` impulse decode, recorded in the PR body.

### PR D — "feature: prepare intros for mastering and save the finished m4a files" (after B + C)

**D1. Drag spike first.**
- The row uses `.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }` with the model-supplied session copy.
- Manually verify a drop into masterchannel.ai/studio in Safari and Chrome.
- If rejected, replace the modifier with an `NSViewRepresentable` drag source that writes an `NSURL` to the pasteboard. Record which one shipped.
- Do this before building the rest of the sheet.

**D2. Naming/copy extension.**
- `ExportNamingTests`:
  - `.masteredM4A` gives `"Title.m4a"` with no stem prefix.
  - A collision gives `"Title 2.m4a"` with `requiresConfirmation`.
  - The 255-byte budget uses `.m4a`.
  - The `.logicAIFF` default output is byte-identical to today's for the existing cases.
- Run `ExportReviewTests` and every `Editor*Export*` suite in full.

**D3. `WorkspaceClient` additions.** Live `chooseDirectoryNear` sets `panel.directoryURL` to the nearest existing ancestor of `suggested`.

**D4. `MasteringPageModel` tests** (`MasteringPageTests`, all clients stubbed, `withMainSerialExecutor`):
- Blockers map to literal messages:
  - `.unsaved` → "Save the project before preparing for mastering."
  - `.missingArtist` → "Enter the interview artist first."
  - `.noIntros` → "No intro clips to prepare. Only clips typed as Intro are included."
  - `.blankTitles` → "Name every intro before preparing."
- `prepareTapped` with an existing run → `confirmingPrepareAgain`. It never calls `audio.prepare` until confirmed.
- A cancelled prepare commits nothing, and the old run is unchanged.
- A `.truePeakCeilingExceeded` stub gives the literal message, commits nothing, and removes the work dir.
- An ambiguous drop sets `ambiguousReturn` with both IDs. Choosing one encodes exactly that part. Choosing or cancelling resumes later files in the batch in FIFO order; a second drop during inspection cannot race the first.
- A drop matching only a returned part → mismatch message, no encode.
- `replacePartTapped` then a drop re-encodes, and the commit replaces the refs.
- If the encode stub throws on piece 2 of 2, nothing is committed and the part is still needed.
- If the run is replaced while encoding, the commit returns false and the encoded files are released.
- Destination:
  - `destinationSaveTapped` calls `createDirectory(pkgDir/mastered)` exactly once and then copies.
  - `destinationCancelTapped` makes no directory calls and keeps `savedFiles` empty.
  - A copy failure halfway leaves the copied list and an error, and the run is unchanged.
- `teardown()` during prepare awaits the task and deletes the work dir.

**D5. ProjectModel wiring.**
- `mastering` survives a retranscribe (same object).
- `viewDisappeared` awaits mastering teardown before the recorder sees `canonicalAudioStore.remove`.
- The `prepareTapped` calls `host.finishTitleEdit` before `host.inputs`: a pending rename draft ends up as the snapshot title. Reading the stale notice never commits an edit.

**D6. Views.**
- `Views/Pages/Mastering/MasteringPageView.swift` plus an editor toolbar button **Prepare for Mastering**, with Export kept as the secondary action.
- All strings, row durations ("12:40 · needed" / "returned") and flags come from the model.

**Manual QA** (checklist in the recipes doc): record browser/real-service/large-package checks before shipping D; do not invent success or perform unauthorized service uploads. If they require user participation, report the concrete remaining QA alongside the reviewable PR.

## Risks and remaining feasibility notes

- **Browser drag** is the one unproven UI mechanism. D1 goes first for that reason.
- **Disk use.** A staged WAV plus its package copy doubles disk use until the window closes (about 1.6 GB for a 50-minute part). This is the same trade the canonical AIFF already makes, and it's accepted.
- **Staging copy cost** (B4) occurs at the document boundary for loaded mastering files. Validate memory and disk behavior with a large lazy wrapper. Missing/corrupt derived media must not make the underlying interview unopenable; staging-storage failures must not be mistaken for corruption.
- **libebur128 true peak** oversamples by 4× at this rate. The tolerance protects our own pipeline's consistency (the same meter, before and after quantization and joining). It doesn't claim BS.1770 absolute accuracy.

## Concrete policy tests and implementation steps

These small policies are literal starting implementations. Audio I/O and document integration follow the contracts/algorithms above and their behavior fixtures; do not paste interface declarations as empty production stubs.

### A: packing and word serialization

- [ ] Add this failing suite in `QuickInterviewEditor/QuickInterviewEditorTests/Mastering/MasteringPolicyTests.swift`, register it in the app test target, and run `make test-fast ONLY=PlayolaInterviewEditorTests/MasteringPolicyTests`. Expect missing policy symbols on the first run.

```swift
import CustomDump
import Testing
@testable import PlayolaInterviewEditor

struct MasteringPolicyTests {
  @Test func packsWholePiecesWithoutAnEmptyTrailingPart() {
    expectNoDifference(MasteringPartPacking.pack([5, 5, 11, 2], limit: 10), [0..<2, 2..<3, 3..<4])
    expectNoDifference(MasteringPartPacking.pack([20], limit: 10), [0..<1])
    expectNoDifference(MasteringPartPacking.pack([], limit: 10), [])
  }

  @Test func preservesRoundedWordOrderAndDoesNotWrapLongMinutes() {
    expectNoDifference(
      MasteringLRC.text(wordStarts: [(0, "Hello"), (1, "a\nb"), (26_901, "café")]),
      "[00:00.00]Hello\n[00:00.00]a b\n[00:00.61]café\n")
    expectNoDifference(
      MasteringLRC.text(wordStarts: [(264_600_000, "late")]), "[100:00.00]late\n")
  }
}
```

- [ ] Implement in `QuickInterviewEditor/QuickInterviewEditor/Models/Mastering/MasteringParts.swift`:

```swift
import Foundation

enum MasteringPartPacking {
  static func pack(_ frameCounts: [Int], limit: Int = MasteringFormat.partLimitFrames)
    -> [Range<Int>]
  {
    precondition(limit > 0 && frameCounts.allSatisfy { $0 > 0 })
    guard !frameCounts.isEmpty else { return [] }
    var result: [Range<Int>] = []
    var start = 0
    var frames = 0
    for (index, count) in frameCounts.enumerated() {
      if frames > 0 && (count > limit || frames > limit - count) {
        result.append(start..<index)
        start = index
        frames = 0
      }
      frames += count
    }
    result.append(start..<frameCounts.count)
    return result
  }
}

enum MasteringLRC {
  static func text(wordStarts: [(frame: Int, text: String)]) -> String {
    wordStarts.compactMap { word in
      guard word.frame >= 0 else { return nil }
      let text = word.text.replacingOccurrences(of: "\r\n", with: "\n")
        .components(separatedBy: .newlines).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      // Quotient/remainder avoids multiplying a large total frame count by 100.
      let centiseconds = (word.frame / 44_100) * 100
        + ((word.frame % 44_100) * 100 + 22_050) / 44_100
      return String(
        format: "[%02ld:%02ld.%02ld]", centiseconds / 6_000,
        (centiseconds / 100) % 60, centiseconds % 100) + text + "\n"
    }.joined()
  }
}
```

The packing preconditions apply only to validated actual render counts. Validate decoded file/manifests with throwing errors before invoking pure policies; never expose these preconditions to unchecked package input.

- [ ] Rerun the focused suite; expect all three packing cases and both lyric cases to pass. Run `SliceRenderPlanTests` after wiring the actual marker mapping. Commit with `feature: preserve intro boundaries and words during mastering preparation`.

### B: immutable references and conditional schema

- [ ] Add the following tests to `QuickInterviewEditor/QuickInterviewEditorTests/Mastering/MasteringRunTests.swift`; run `make test-fast ONLY=PlayolaInterviewEditorTests/MasteringRunTests` and confirm the new reference policy is missing before implementation.

```swift
import CustomDump
import Foundation
import Testing
@testable import PlayolaInterviewEditor

struct MasteringRunTests {
  @Test func rejectsPathsAndAcceptsOnlyOwnedArtifactNames() {
    let stem = "00000000-0000-0000-0000-000000000001"
    expectNoDifference(MasteringArtifactRef(fileName: stem + ".wav", byteCount: 100).isWellFormed, true)
    expectNoDifference(MasteringArtifactRef(fileName: "../" + stem + ".wav", byteCount: 100).isWellFormed, false)
    expectNoDifference(MasteringArtifactRef(fileName: stem + ".wav", byteCount: 0).isWellFormed, false)
    expectNoDifference(MasteringArtifactRef(fileName: stem + ".aiff", byteCount: 100).isWellFormed, false)
  }

  @Test func writingWithoutARunKeepsThePreviousProjectFormat() {
    let file = Fixtures.projectFile()
    expectNoDifference(ProjectFile.writtenSchemaVersion(for: file), 2)
  }
}
```

- [ ] Implement the property in `QuickInterviewEditor/QuickInterviewEditor/Models/MasteringRun.swift` and the schema function in `QuickInterviewEditor/QuickInterviewEditor/Models/ProjectFile.swift`:

```swift
var isWellFormed: Bool {
  guard byteCount > 0 else { return false }
  let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
  guard parts.count == 2, parts[1] == "wav" || parts[1] == "m4a",
    let id = UUID(uuidString: String(parts[0]))
  else { return false }
  return id.uuidString.lowercased() == String(parts[0])
}

static func writtenSchemaVersion(for file: ProjectFile) -> Int {
  file.masteringRun == nil ? 2 : maximumReadableSchemaVersion
}
```

- [ ] Add a v3 run fixture using the full manifest declarations above, then execute B1–B5's real package-write cases. The name validator is only a first check: validate `.wav` for prepared refs, `.m4a` for finished refs, duplicate identities, positive frames and contiguous non-overflowing ranges. A missing finished file makes its part incomplete; a partial set must never be displayed as returned. Read media properties before using a file even when its name and byte count pass.
- [ ] Run `make test-fast` for the entire app after the shared document/schema changes, not only the new suite. Commit with `feature: preserve mastering files across project saves`.

### C: strict matching

- [ ] Add this test to `QuickInterviewEditor/QuickInterviewEditorTests/Mastering/MasterReturnMatchingTests.swift`, register it, and run `make test-fast ONLY=PlayolaInterviewEditorTests/MasterReturnMatchingTests` to establish the missing behavior:

```swift
@Test func preservesAmbiguityAndExcludesTheFiveSecondBoundary() {
  let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  let parts = [(id: first, frameCount: 600 * 44_100), (id: second, frameCount: 604 * 44_100)]
  expectNoDifference(MasterReturnMatching.candidates(durationSeconds: 602, parts: parts), [first, second])
  expectNoDifference(MasterReturnMatching.candidates(durationSeconds: 609, parts: parts), [])
}
```

Use the same imports and test module as `MasteringPolicyTests`. Implement in `QuickInterviewEditor/QuickInterviewEditor/Models/Mastering/MasterReturnMatching.swift`:

```swift
enum MasterReturnMatching {
  static func candidates(durationSeconds: Double, parts: [(id: UUID, frameCount: Int)]) -> [UUID] {
    guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }
    return parts.compactMap { part in
      guard part.frameCount > 0,
        abs(durationSeconds - Double(part.frameCount) / 44_100) < 5
      else { return nil }
      return part.id
    }
  }
}
```

- [ ] Rerun the focused test, then C2/C3's decode, range, metadata and timing fixtures. Commit with `feature: match and split returned mastering parts`.

## Task execution checklist

For **each** A1–A6, B1–B5, C1–C3 and D1–D6 task above:

- [ ] Add its stated behavior fixtures first in the mapped test file; for D1 use the actual browser spike instead of a mock assertion about browser acceptance.
- [ ] Run its exact named suite with `make test-fast ONLY=PlayolaInterviewEditorTests/` followed by the suite name in that task. Record the failing assertion or missing symbol.
- [ ] Implement the specified contract and ordered algorithm, including the named failure/cancellation paths. Add the new file to the correct Xcode target.
- [ ] Rerun that suite to green, then any touched pre-existing suites named in the task.
- [ ] Commit that coherent task without co-author trailers or bypassing hooks. Use the PR's plain-English title as the commit subject when no narrower subject is given.

Each worker's final report lists exactly which automated and manual checks ran. A pending real mastering test remains pending; no implementation task silently treats a synthetic fixture as its substitute.

## Final architecture dispositions

Claude reviewed the approved spec and implementation boundaries, then accepted the streaming readback, owned snapshot files, explicit meter client and pure snapshot corrections. Two later suggestions were declined against the approved scope: silence remains pass-through at unity gain (or peak attenuation), and malformed derived mastering data must not block opening the interview. No silent-program blocker or mastering-media open gate is added. NaN/+infinite meter errors still fail the preparation attempt without replacing an existing run.

Per-file hydration failure is a visible runtime availability problem, not a reason to fail the entire document. Preserve readable package artifacts on ordinary saves when staging failed; refuse a Save As that cannot carry valid required bytes rather than silently declaring it complete. Missing/corrupt media may heal the affected reference as specified. This distinction prevents a full staging disk from destroying an otherwise valid run. A diagnostic is memory-only; no speculative persisted error/status fields are required.

For simultaneous saves, never mutate one `FileWrapper` tree concurrently. Exercise the existing document API with overlapping snapshots; serialize reconciliation over a shared wrapper if the document system does not supply exclusive access. Retain staged owners until the returned wrapper has consumed its source, as well as while the snapshot exists. The file-write test must drop the model/document before completing the old save, not merely compare owner reference counts.

Use a private wrapper lease for that last lifetime edge in `ProjectDocument.swift`. This avoids relying on the snapshot remaining alive after `fileWrapper(snapshot:configuration:)` returns. The Foundation/Objective-C mechanism was compiled under Swift 6 and checked in a disposable local probe: releasing the original owner kept the source readable through `FileWrapper.write`; releasing the wrapper then deleted the source.

```swift
import ObjectiveC

private final class MasteringWrapperLeaseKey: Sendable {}
private let masteringWrapperLeaseKey = MasteringWrapperLeaseKey()

private final class MasteringWrapperLease: Sendable {
  let sources: [StagedMasteringArtifact]
  init(sources: [StagedMasteringArtifact]) { self.sources = sources }
}

private func retainMasteringSources(
  _ sources: [StagedMasteringArtifact], on wrapper: FileWrapper
) {
  objc_setAssociatedObject(
    wrapper, Unmanaged.passUnretained(masteringWrapperLeaseKey).toOpaque(),
    MasteringWrapperLease(sources: sources), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}
```

Route every successful `makeFileWrapper` return through this helper with its snapshot's relevant owners. Attach only while the wrapper is exclusively being constructed/reconciled. B's regression must release the snapshot too, then perform the real wrapper write and inspect output bytes. Keep this tiny lease private to the document boundary; it is not a general job/lifetime framework.
