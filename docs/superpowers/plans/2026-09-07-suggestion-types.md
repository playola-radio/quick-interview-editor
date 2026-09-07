# Configurable Suggestions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add configurable Spotlight, Song Intro, imaging, and custom suggestions with editable field-based naming, safe numbering across tapes, resumable replacement searches, type filters, and explicit export collision review.

**Architecture:** Keep the tuned Python paragraph cutter as the default Spotlight/Intro discovery implementation; add a separate configurable discovery pass and a naming-field extraction stage. Swift owns configuration, naming, reservations, document mutations, and presentation through focused observable models and dependency clients. An immutable search snapshot plus a durable request journal preserves paid work independently of the active suggestion batch.

**Tech Stack:** Python 3.12, pytest, existing LLM/cache/subprocess adapters; Swift 6/macOS 15, SwiftUI, Observation, Dependencies, Sharing, IdentifiedCollections, CustomDump, Swift Testing, XcodeGen.

---

## Authority and execution boundaries

The approved contract is [the revised design](../specs/2026-09-07-suggestion-types-design.md). This plan implements that contract, including both adversarial-review rounds approved on September 7. This is one integrated feature: the helper, project state, and naming UI must agree on the same versioned contract. Tasks are incremental commits, not independently published products.

Work in `/Users/brian/conductor/workspaces/logic-utils/georgetown`. This Conductor workspace is already isolated. Keep its current branch name. Compare against `origin/main`. Do not merge, push, release, or restore the archived implementation as part of execution. The archive `temp/suggestion-types-unplanned-draft` at `558cda121e8ffcd3e6abc74534690783d2bb99bc` is read-only reference; several of its choices are incompatible with the approved design.

Read `CLAUDE.md` and applicable `pfw-*` skills before Swift work: observable-models, dependencies, sharing, identified-collections, modern-swiftui, testing, custom-dump, and issue-reporting for dependency test failures. Models inherit `ViewModel`, use the documented MARK order, own every display string and action, and keep effects behind dependency clients. Use `expectNoDifference`/`expectDifference` for value assertions; no sleeping tests and no live subprocess/model calls in unit tests.

Tests below establish the public seams and important regression examples. For each test case listed in a task, implement and run one failing test, make the smallest implementation change, and rerun that test before proceeding to the next case. Each checkbox is a work action; repeat that red/green loop for the explicitly listed cases. The code blocks specify domain contracts and critical algorithms; integrate them with existing initializers and dependency patterns rather than replacing whole existing files.

Commands run from the repository root unless stated. Python: `python3 -m pytest`. Swift: `make -C QuickInterviewEditor test-fast ONLY=PlayolaInterviewEditorTests/<Suite>`. Successful test commands must exit 0 with no failed tests; a red test must fail for the new behavior, not a missing tool or unrelated build failure. Use `make test-fast` as the iteration loop; do not run XcodeGen between test runs. When adding source/test files, update the generated project's file references once per task (XcodeGen after a source-manifest change), then keep the resulting project stable. Do not change package versions.

## File map and ownership

Existing integration points:

| Path | Change |
| --- | --- |
| `cut_suggester/cutter.py`, `prompts.py`, `postprocess.py`, `models.py`, `cli.py`, `cache.py` | Keep tuned behavior, expose configured discovery, add versioned resumable requests without modifying the audio engine |
| `QuickInterviewEditor/QuickInterviewEditor/Models/ProductType.swift` | Open string-backed type identity with legacy single-string coding |
| `QuickInterviewEditor/QuickInterviewEditor/Models/CutSuggestion.swift`, `Slice.swift`, `EditorDocumentState.swift`, `ProjectFile.swift` | Optional naming metadata, full batch snapshot, permanent issued ledger, recovery metadata, schema 2 |
| `QuickInterviewEditor/QuickInterviewEditor/Core/CutSuggestClient.swift`, `LiveCutSuggester.swift` | Versioned run request, checkpoint notifications, refresh/resume, valid-empty result |
| `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` | Wire focused models into snapshot/mutate/restore, one acceptance transaction, filtered transcript bands, export review |
| `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/CutSuggestions/CutSuggestionsPageModel.swift`, `CutSuggestionsPageView.swift` | Run controls, filters, numbering/correction presentation |
| `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Project/ProjectModel.swift`, `ProjectHostView.swift` | Recovery ownership and document hydration/teardown |
| `QuickInterviewEditor/QuickInterviewEditor/Documents/ProjectDocument.swift`, `Core/ProjectPackage.swift` | Save/read new metadata; preserve audio wrappers |
| `QuickInterviewEditor/QuickInterviewEditor/Models/ExportNaming.swift` | Name policy, pure export preflight mappings |
| `QuickInterviewEditor/QuickInterviewEditor/QuickInterviewEditorApp.swift` | App-wide Suggestions configuration entry point |

New focused units:

| Path | Responsibility |
| --- | --- |
| `QuickInterviewEditor/QuickInterviewEditor/Models/SuggestionConfiguration.swift` | Codable definitions, IDs, template components, configuration validation |
| `QuickInterviewEditor/QuickInterviewEditor/Models/SuggestionDefaults.swift` | Six types, three fields, preset restoration |
| `QuickInterviewEditor/QuickInterviewEditor/Models/SuggestionNaming.swift` | Field resolution, sequence keys, canonical spelling, rendering |
| `QuickInterviewEditor/QuickInterviewEditor/Models/SuggestionNumbering.swift` | Checked allocation, starts, ledger entries, conflicts |
| `QuickInterviewEditor/QuickInterviewEditor/Models/SuggestionRunWire.swift` | Decode Python checkpoint/result envelopes into Swift run records |
| `QuickInterviewEditor/QuickInterviewEditor/Models/SuggestionRun.swift` | Immutable snapshot, batch/unfinished state, revision IDs |
| `QuickInterviewEditor/QuickInterviewEditor/Models/SuggestionDocumentMutation.swift` | Pure document transactions and permanent-ledger history transform |
| `QuickInterviewEditor/QuickInterviewEditor/Core/SuggestionConfigurationClient.swift` | Atomic app-wide configuration load/save and stale-draft rejection |
| `QuickInterviewEditor/QuickInterviewEditor/State/SuggestionConfigurationKey.swift` | Shared published configuration; disk errors stay explicit |
| `QuickInterviewEditor/QuickInterviewEditor/Core/SuggestionRecoveryClient.swift` | Durable journal ownership, lookup, copying, cleanup |
| `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SuggestionSettings/SuggestionSettingsModel.swift`, `SuggestionSettingsView.swift` | Types/Fields editor and restore built-in flow |
| `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SuggestionSettings/NamingTemplateModel.swift`, `NamingTemplateView.swift` | Ordered template components and example preview |
| `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/CutSuggestions/SuggestionRunModel.swift` | Search state machine, retries, stale-event protection |
| `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/CutSuggestions/SuggestionReviewModel.swift`, `SuggestionReviewView.swift` | Field/group correction and pending renumber forms |
| `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/ExportReviewModel.swift`, `ExportReviewView.swift` | Collision mapping confirmation and partial-copy status |
| `cut_suggester/suggestion_config.py` | Validate Swift-supplied types/fields; split built-in/custom routing |
| `cut_suggester/configured_discovery.py` | Image/custom windows, validation, overlap and subtype selection |
| `cut_suggester/extraction.py` | Required-field batching, source context, strict result matching |
| `cut_suggester/run_journal.py` | Atomic successful-request checkpoints and immutable request identity |
| `cut_suggester/configured_run.py` | Version-2 orchestration, checkpointed stage outputs |
| `tests/fixtures/suggestion-contract-v2.json` | Shared request/configuration contract fixture (also a Swift test resource) |
| `tests/fixtures/suggestion-result-v2.json` | Shared response and field-result contract fixture |
| `evals/cut_suggestions/datasets/suggestion_types/` | Synthetic labeled positive/negative editorial examples, distinct from live evidence |

New Swift tests follow the existing `QuickInterviewEditor/QuickInterviewEditorTests/Models`, `Core`, and `Views/Pages/<Name>` layout. Add explicit test resources through `QuickInterviewEditor/project.yml`; XcodeGen owns `QuickInterviewEditor/PlayolaInterviewEditor.xcodeproj/project.pbxproj`. Do not move existing page tests or refactor unrelated editor functionality.

## Task 1: Capture the baseline and default-prompt invariants

**Files:** Create `tests/fixtures/suggestion-default-stage2.txt`, `tests/test_suggestion_prompt_regression.py`; inspect `tests/test_eval_cached_joe_miller.py`, `evals/cut_suggestions/runner.py`, `cut_suggester/prompts.py`.

- [ ] Record the clean worktree and baseline test output under `.context/`: `git status --short`, `python3 -m pytest -q`, and `make -C QuickInterviewEditor test-fast`. Stop to diagnose existing failures separately; don't record invented baseline counts.
- [ ] Generate a golden prompt from the current tuned function using these exact inputs, before changing it:

```python
from pathlib import Path
from cut_suggester.models import DEFAULT_SPECS, Sentence, TopicPartition
from cut_suggester.prompts import stage2_prompt
sentences = [Sentence(0, 1, "I wrote this song on the road.", (1,), 0, 20, 0, 20000)]
text = stage2_prompt(sentences, [TopicPartition(0, 0, "Writing")], DEFAULT_SPECS)
Path("tests/fixtures/suggestion-default-stage2.txt").write_text(text, encoding="utf-8")
```

- [ ] Add the pinned assertion below. It is a characterization test and should pass immediately; later routing tests must go red before routing is implemented.

```python
from pathlib import Path
from cut_suggester.models import DEFAULT_SPECS, Sentence, TopicPartition
from cut_suggester.prompts import stage2_prompt

def test_untouched_default_prompt_matches_baseline():
    sentences = [Sentence(0, 1, "I wrote this song on the road.", (1,), 0, 20, 0, 20000)]
    actual = stage2_prompt(sentences, [TopicPartition(0, 0, "Writing")], DEFAULT_SPECS)
    expected = Path("tests/fixtures/suggestion-default-stage2.txt").read_text(encoding="utf-8")
    assert actual == expected
```

- [ ] Run `python3 -m pytest tests/test_suggestion_prompt_regression.py tests/test_eval_cached_joe_miller.py -q`. Preserve committed caches and baseline reports; a new product-spec version can change keys even when prompt text doesn't change. Keep the legacy eval entry point pinned to its original specs/cache versions.
- [ ] Commit only the new test and prompt fixture: `git commit -m "test: pin default suggestion discovery prompt"` after staging those paths.

## Task 2: Define configuration, defaults, and the shared wire fixture

**Files:** Create the configuration/defaults models and `QuickInterviewEditor/QuickInterviewEditorTests/Models/SuggestionConfigurationTests.swift`; modify `Models/ProductType.swift`; create `tests/fixtures/suggestion-contract-v2.json`; modify `QuickInterviewEditor/project.yml` for fixture resources.

- [ ] Write a failing default-template test using the following public contract. Definitions belong in `SuggestionConfiguration.swift`; field IDs are strings, custom type IDs use injected UUIDs prefixed `custom-`.

```swift
enum SuggestionGroup: String, Codable, CaseIterable, Sendable {
  case spotlights, songIntros, audioImages
}
struct NamingComponent: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable { case literal, field, sequence }
  var kind: Kind
  var value: String?
}
struct SuggestionField: Identifiable, Codable, Equatable, Sendable {
  var id: String
  var name: String
  var instructions: String
}
struct SuggestionTypeDefinition: Identifiable, Codable, Equatable, Sendable {
  var id: String
  var name: String
  var group: SuggestionGroup
  var guidelines: String
  var template: [NamingComponent]
  var sequenceFieldIDs: [String]
}
struct SuggestionConfiguration: Codable, Equatable, Sendable {
  var schemaVersion: Int = 1
  var revision: Int = 0
  var types: [SuggestionTypeDefinition]
  var fields: [SuggestionField]
}
```

```swift
@Test func introTemplateCombinesFieldsAndSequence() throws {
  let config = SuggestionDefaults.configuration
  let intro = try #require(config.types.first { $0.id == "intro" })
  expectNoDifference(intro.template, [
    NamingComponent(kind: .field, value: "song-title"),
    NamingComponent(kind: .literal, value: " "),
    NamingComponent(kind: .sequence, value: nil),
    NamingComponent(kind: .literal, value: ", "),
    NamingComponent(kind: .field, value: "artist-name"),
  ])
  expectNoDifference(intro.sequenceFieldIDs, ["song-title", "artist-name"])
}
```

- [ ] Run `make -C QuickInterviewEditor test-fast ONLY=PlayolaInterviewEditorTests/SuggestionConfigurationTests` and confirm missing-contract failure.
- [ ] Implement the six defaults with IDs `spotlight`, `intro`, `image-id`, `image-pre-commercial`, `image-post-commercial`, `image-promo`, and field IDs `song-title`, `artist-name`, `descriptive-title`. Copy the approved guidance verbatim from the spec; Spotlight/Intro discovery descriptions retain the existing tuned strings. For intros, supplemental semantic evaluation is separate from changing default prompt text. `SuggestionDefaults.configuration` is the Swift source of user-facing presets.
- [ ] Replace the closed Swift `ProductType` enum with a string-backed `RawRepresentable`, `Hashable`, `Sendable`, `Codable` value. Preserve `.intro`, `.spotlight`, and single-string legacy JSON. `init?(rawValue:)` rejects empty/whitespace IDs but preserves historical nonempty IDs. New helper responses must additionally belong to the run's configured ID set. Keep `displayLabel` as a legacy fallback; new results use the snapshot's label. Update existing unknown-response tests to test request membership rather than rejecting every unfamiliar historical ID.
- [ ] Implement `SuggestionConfiguration.validationMessages() -> [String]`: enforce nonempty/unique IDs, names, guidance, extraction instructions; normalized unique names per group and unique field names; supported schema; at least one type; no duplicate grouping-field references; all field references exist; literals/field tokens are nonempty; Sequence has no value; at least one meaningful component. Whitespace-only literal-only templates fail. Omitted Sequence is valid. Referenced-field deletion returns affected type names. Restoring a missing built-in retains its ID and blocks conflicting names, preserving custom definitions.
- [ ] Add parameterized cases for each validation rule, every default prefix, preset restore/name conflict, field rename preserving token IDs, and legacy/custom ID Codable round trips. Export the default configuration into the shared JSON fixture under `configuration` with Swift's exact camelCase keys; Python consumes that shape without a second hand-maintained default catalog.
- [ ] Run the focused suite and `ProductSpecTests`/`CutSuggestionWireTests` where present; update source registration once. Commit: `feat: define configurable suggestion types and naming fields`.

## Task 3: Pure field rendering and sequence allocation

**Files:** Create `Models/SuggestionNaming.swift`, `Models/SuggestionNumbering.swift`; create `QuickInterviewEditor/QuickInterviewEditorTests/Models/SuggestionNamingTests.swift`, `SuggestionNumberingTests.swift`.

- [ ] Establish these Codable value contracts. Use arrays of field/value pairs for canonical sequence keys, sorted by field ID; never concatenate unescaped values into a delimiter-based key.

```swift
struct SequenceFieldValue: Codable, Hashable, Sendable {
  var fieldID: String
  var value: String
}
struct SuggestionSequenceKey: Codable, Hashable, Sendable {
  var typeID: String
  var fields: [SequenceFieldValue]
  var provisionalCandidateID: UUID?
}
struct SequenceReservationIdentity: Codable, Hashable, Sendable {
  var candidateID: UUID
  var key: SuggestionSequenceKey
  var number: Int
}
struct SequenceReservation: Codable, Equatable, Sendable {
  var candidateID: UUID
  var key: SuggestionSequenceKey
  var number: Int
  var canonicalValues: [String: String]
  var identity: SequenceReservationIdentity {
    SequenceReservationIdentity(candidateID: candidateID, key: key, number: number)
  }
}
struct SuggestionStart: Codable, Equatable, Sendable {
  var number: Int
  var isExplicit: Bool
}
struct SuggestionStarts: Codable, Equatable, Sendable {
  var types: [String: SuggestionStart] = [:]
  var groups: [GroupStart] = []
  struct GroupStart: Codable, Equatable, Sendable {
    var key: SuggestionSequenceKey
    var start: SuggestionStart
  }
}
enum SuggestionNumberingError: Error, Equatable {
  case invalidStart
  case minimumSafeStart(Int)
  case exhausted
}
```

- [ ] Write and run the failing checked-allocation test:

```swift
@Test func occupiedMaximumDoesNotOverflow() throws {
  #expect(throws: SuggestionNumberingError.exhausted) {
    try nextSuggestionNumber(start: Int.max, occupied: [Int.max])
  }
  expectNoDifference(try nextSuggestionNumber(start: Int.max, occupied: []), Int.max)
}
```

- [ ] Implement the primitive and rerun the test:

```swift
func nextSuggestionNumber(start: Int, occupied: Set<Int>) throws -> Int {
  guard start > 0 else { throw SuggestionNumberingError.invalidStart }
  var number = start
  while occupied.contains(number) {
    let next = number.addingReportingOverflow(1)
    guard !next.overflow else { throw SuggestionNumberingError.exhausted }
    number = next.partialValue
  }
  return number
}
```

- [ ] Implement `suggestionSequenceKey(type:values:candidateID:)`: trim values, canonical-compose Unicode, case-fold using a fixed `en_US_POSIX` locale without diacritic/punctuation stripping; sort key fields by stable ID. If any grouping field is missing/blank, retain `candidateID` in `provisionalCandidateID`. No missing fields means nil. Implement `renderSuggestionName(template:values:sequence:fallback:) -> String`: concatenate ordered components; if any required token is unresolved return the discovery label unchanged. Repeated Sequence tokens use the same number; types without Sequence never issue a reservation merely for rendering.
- [ ] Add the failing naming test and implementation for this exact example:

```swift
@Test func rendersAnIntroUsingAppAssignedNumber() {
  let intro = SuggestionDefaults.configuration.types.first { $0.id == "intro" }!
  expectNoDifference(
    renderSuggestionName(template: intro.template,
      values: ["song-title": "Nobody Wins", "artist-name": "American Aquarium"],
      sequence: 4, fallback: "Introducing the next recording"),
    "Nobody Wins 4, American Aquarium")
}
```

- [ ] Add an all-or-nothing allocation helper and tests for starting at 7, skipping occupied 8, the final Int.max slot, and a batch that exceeds Int.max. Run its failing tests before adding this implementation:

```swift
func allocateSuggestionNumbers(count: Int, start: Int, occupied: Set<Int>) throws -> [Int] {
  guard count >= 0, start > 0 else { throw SuggestionNumberingError.invalidStart }
  var taken = occupied
  var assigned: [Int] = []
  var cursor = start
  for index in 0..<count {
    let value = try nextSuggestionNumber(start: cursor, occupied: taken)
    assigned.append(value)
    taken.insert(value)
    if index < count - 1 {
      let next = value.addingReportingOverflow(1)
      guard !next.overflow else { throw SuggestionNumberingError.exhausted }
      cursor = next.partialValue
    }
  }
  return assigned
}
```

- [ ] Test canonical key equivalence for case/Unicode variants, distinct punctuation/different performers, separate provisional missing-field keys, fallback rendering, and optional/repeated Sequence tokens. Batch-specific ownership/correction tests follow in Task 4 after its record types exist.
- [ ] Run `make -C QuickInterviewEditor test-fast ONLY=PlayolaInterviewEditorTests/SuggestionNamingTests` and `make -C QuickInterviewEditor test-fast ONLY=PlayolaInterviewEditorTests/SuggestionNumberingTests`. Commit: `feat: add deterministic suggestion naming and checked numbering`.

## Task 4: Define immutable run and result records

**Files:** Create `Models/SuggestionRun.swift`; modify `Models/CutSuggestion.swift`, `Models/Slice.swift`; create `QuickInterviewEditor/QuickInterviewEditorTests/Models/SuggestionRunTests.swift` and extend `Models/CutSuggestionTests.swift`.

- [ ] Write a failing test that decodes a legacy suggestion/slice with no naming keys and re-encodes it without changing its title or opting it into generated export naming. Use the existing `Fixtures.cutSuggestion` and slice fixtures.
- [ ] Add the following records. New fields on existing Codable records are optional with `decodeIfPresent`; defaults on stored properties alone are not sufficient for synthesized decoding compatibility.

```swift
struct SuggestionRunSnapshot: Codable, Equatable, Sendable {
  var runID: UUID
  var configuration: SuggestionConfiguration
  var configurationHash: String
  var model: String
  var discoveryPromptVersion: String
  var extractionPromptVersion: String
  var productSpecVersion: String
  var transcriptHash: String
  var sourceFingerprint: String
  var sampleRate: Int
}
struct SuggestionNamingRecord: Codable, Equatable, Sendable {
  var runID: UUID
  var typeID: String
  var typeName: String
  var typeGroup: SuggestionGroup
  var discoveryLabel: String
  var extractedValues: [String: String]
  var missingFieldIDs: [String]
  var correctedValues: [String: String]
  var reservation: SequenceReservation?
}
struct SuggestionBatch: Codable, Equatable, Sendable {
  var snapshot: SuggestionRunSnapshot
  var actualStarts: SuggestionStarts
  var canonicalGroups: [CanonicalGroup]
  struct CanonicalGroup: Codable, Equatable, Sendable {
    var key: SuggestionSequenceKey
    var values: [String: String]
  }
}
struct SuggestionRunCheckpoint: Codable, Equatable, Sendable {
  var schemaVersion: Int = 1
  var pythonRevision: Int
  var controlRevision: Int
  var originalBatchFingerprint: String?
  var snapshot: SuggestionRunSnapshot
  var phase: Phase
  var candidates: [CutSuggestion]
  var completedRequestKeys: [String]
  var failedRequestKeys: [String]
  var proposedStarts: SuggestionStarts
  enum Phase: String, Codable, Sendable {
    case discovering, extracting, paused, needsRetry, needsNumbering, ready
  }
}
```

`CutSuggestion.naming: SuggestionNamingRecord?` stores its original discovery label separately from `title` (the generated display name). `Slice.suggestionNaming: SuggestionNamingRecord?` opts into exact-name export; `Slice.suggestionTypeID: String?` allows legacy known type association without changing export behavior. Full field instructions and template/grouping definitions live in the owning `SuggestionBatch.snapshot` and unfinished snapshot, not a lookup against current settings. The owning batch snapshot is canonical for every pending correction/renumber; per-record type ID/name/group are display provenance only. Saved clips require no template lookup to export their stored name after the originating batch is replaced. Validate new record labels/IDs against that snapshot when applying a run. A record with a run ID but no owning snapshot fails a new-run apply; legacy nil metadata remains valid.

- [ ] Implement `numberSuggestions(_ candidates: [CutSuggestion], snapshot: SuggestionRunSnapshot, starts: SuggestionStarts, issued: [SequenceReservation], retained: [SequenceReservation]) throws -> (candidates: [CutSuggestion], batch: SuggestionBatch)` as a pure all-or-nothing transformation using Task 3's primitives. Sort by start sample, end sample, type ID, then candidate UUID string. Resolve a group override before the type start. Fresh automatic starts advance beyond the issued maximum; explicit starts at/below it fail with the minimum safe start. For an explicit pending renumber, exclude only selected pending reservations from retained occupancy; rejected and all issued numbers stay occupied. Maximum+1 and every skip use checked arithmetic. Set each candidate's naming record and title; retain extraction source values, resolve corrections first, and assign canonical rendering by group. A missing grouping field receives its own provisional key; missing template fields use the descriptive fallback. Only a template containing Sequence allocates a number. Test independent image counters, same song/different performers, rank/filter independence, rejection gaps, two case-variant takes sharing canonical display values, group correction with occupied numbers, and idempotent same-owner reservations. Preserve an existing candidate's reservation during single-row correction when its key is unchanged.

Implementation refinement verified during Task 4: `numberSuggestions` also takes `mode: SuggestionNumberingMode = .fresh` and `existingBatch: SuggestionBatch? = nil`. The explicit modes are `.fresh`, `.pendingRenumber(selectedCandidateIDs:)`, and `.correction(candidateID:)`. Correction and pending renumber use the owning existing batch snapshot when supplied; ordinary correction preserves its historical actual starts. An unchanged-key reservation collision throws rather than silently renumbering. Validate the snapshot configuration before constructing lookup dictionaries, and include provisional candidate UUIDs in canonical-group ordering.

- [ ] Write the snapshot regression: create an intro batch, change the app-wide template to a different prefix, correct the artist in the old batch, and assert its original template still renders. Also round-trip missing vs empty fields, custom historical type labels, canonical values, and the separate Python/control checkpoint revisions. Ensure malformed new metadata does not silently decode as legacy.
- [ ] Run `SuggestionRunTests`, `SuggestionNamingTests`, `SuggestionNumberingTests`, and existing suggestion/slice Codable tests. Commit: `feat: persist immutable suggestion naming snapshots`.

## Task 5: App-wide configuration persistence and shared publication

**Files:** Create `Core/SuggestionConfigurationClient.swift`, `State/SuggestionConfigurationKey.swift`; create `QuickInterviewEditor/QuickInterviewEditorTests/Core/SuggestionConfigurationClientTests.swift`.

- [ ] Test load from missing storage returns the six defaults, invalid JSON/schema (including an existing file without schemaVersion) returns a visible load error without overwriting bytes, and two saves based on the same revision cannot both succeed.
- [ ] Implement `SuggestionConfigurationStore` as an actor initialized with `fileURL: URL`, exposing `load()` and `save(_:expectedRevision:)`, and a `Sendable` dependency boundary with these operations:

```swift
struct SuggestionConfigurationClient: Sendable {
  var load: @Sendable () async throws -> SuggestionConfiguration
  var save: @Sendable (SuggestionConfiguration, Int) async throws -> SuggestionConfiguration
}
enum SuggestionConfigurationStoreError: Error, Equatable {
  case staleDraft
  case invalid([String])
}
```

The second save argument is `expectedRevision`. Within one serialized actor operation: load the current file, validate the draft, compare revisions, checked-increment the revision, encode, write atomically, then publish/return the saved value. File location: `Application Support/<AppDirectories.folderName>/SuggestionConfiguration.json`. Configuration schemaVersion/revision are required on disk for this first configuration format; initializer defaults seed newly created values, not missing stored keys. An absent file seeds defaults; missing required keys in an existing file fail without rewriting it. Missing directory is created; a write error throws and leaves both disk and published value unchanged. This is one app process with multiple windows, not a cross-process settings synchronization service.

- [ ] Add the stale-save regression using an isolated temporary directory and run it red before adding revision comparison:

```swift
@Test func aStaleDraftCannotOverwriteASavedConfiguration() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = SuggestionConfigurationStore(fileURL: directory.appendingPathComponent("rules.json"))
  let original = try await store.load()
  var first = original
  first.types[0].name = "Stories"
  let saved = try await store.save(first, expectedRevision: original.revision)
  do {
    _ = try await store.save(original, expectedRevision: original.revision)
    Issue.record("A stale draft unexpectedly saved")
  } catch {
    expectNoDifference(error as? SuggestionConfigurationStoreError, .staleDraft)
  }
  expectNoDifference(try await store.load(), saved)
}
```

- [ ] Add a type-safe `@Shared(.inMemory("suggestionConfiguration"))` key with optional configuration default nil. Publish only a successfully loaded/saved value; errors belong to model state. Do not use an implicitly seeded `fileStorage` value that could hide a corrupted file. Every new search ensures a successful load and takes a value snapshot; no model observes draft edits from another window.
- [ ] Implement `DependencyKey`/`TestDependencyKey` and `DependencyValues.suggestionConfiguration`. Live closures capture the same store actor. Tests override the client; its unimplemented default reports a programmer issue and throws, and previews use an in-memory implementation. Test actor behavior using isolated temporary files; test shared publication with locally initialized `@Shared`, never a global test shared value.
- [ ] Run `SuggestionConfigurationClientTests`. Commit: `feat: persist app-wide suggestion rules atomically`.

## Task 6: Validate Python configuration and route the tuned pass

**Files:** Create `cut_suggester/suggestion_config.py`, `tests/test_suggestion_config.py`; modify `cut_suggester/cutter.py`, `prompts.py`, `postprocess.py`; extend `tests/test_suggestion_prompt_regression.py`.

- [ ] Write the routing test against the shared fixture:

```python
import copy
import json
from pathlib import Path
from cut_suggester.suggestion_config import split_discovery_types

def test_custom_spotlight_name_does_not_route_to_tuned_pass():
    config = json.loads(Path("tests/fixtures/suggestion-contract-v2.json").read_text())["configuration"]
    custom = copy.deepcopy(next(t for t in config["types"] if t["id"] == "spotlight"))
    custom["id"] = "custom-story"
    config["types"] = [t for t in config["types"] if t["id"] != "spotlight"] + [custom]
    tuned, generic = split_discovery_types(config)
    assert [t["id"] for t in tuned] == ["intro"]
    assert "custom-story" in [t["id"] for t in generic]
```

- [ ] Run `python3 -m pytest tests/test_suggestion_config.py -q` and confirm the missing function fails; implement validation of the configuration's actual shared keys and `split_discovery_types`. Reserve tuned routing only for exact IDs `spotlight`/`intro`; image membership uses exact built-in IDs. Reject unsupported schema, duplicates, undeclared field references, and invalid component shapes before any model call.
- [ ] Keep `ProductType` and `CutCandidate` in the tuned Python cutter unchanged. Build its `ProductSpec` mapping only for present built-ins, using their configured descriptions. Change `specs = specs or DEFAULT_SPECS` to `specs = DEFAULT_SPECS if specs is None else specs`; an empty configured mapping must not restore defaults. Skip the tuned pipeline entirely when empty. Reject an output type absent from the requested mapping before `build_candidate` can index the specs. In V2, distinguish an explicitly empty `clips` array from a nonempty array containing only malformed/undeclared candidates: the latter fails validation rather than masquerading as a successful zero-result replacement. Valid candidates all removed by documented duration filtering may legitimately produce an empty result with diagnostics.
- [ ] Preserve `stage2_prompt` byte-for-byte for the default pair. For a subset, generate only the subset's type alternatives in the JSON instruction and guidance. This is an intentional changed prompt/cache key. Naming fields, imaging guidance, and templates are never added to this prompt.
- [ ] Test default-prompt equality after adding all imaging defaults and a custom type; Spotlight removal; Intro removal; both removed; edited guidance; custom named Spotlight; restoring a built-in; out-of-request model types; and no calls for an empty tuned pass. Keep default topic labels for story merging. Restrict `merge_adjacent_same_label` to Spotlight candidates: nonoverlapping repeated Intro takes must remain separate even when their song/topic labels match.
- [ ] Run `python3 -m pytest tests/test_suggestion_config.py tests/test_suggestion_prompt_regression.py tests/test_cut_suggester_cutter.py tests/test_cut_suggester_postprocess.py tests/test_eval_cached_joe_miller.py -q`. Commit: `feat: route configured types through preserved discovery passes`.

## Task 7: Discover imaging and custom candidates

**Files:** Create `cut_suggester/configured_discovery.py`, `tests/test_configured_discovery.py`; create `evals/cut_suggestions/datasets/suggestion_types/labels.json`, `transcript.json`; modify `cut_suggester/models.py` only for the configured Intro minimum strategy documented below.

- [ ] Define generic candidate output as dictionaries matching existing `CutCandidate.to_dict()` keys plus stable `candidate_id`. Keep `product_type` a string, without extending the tuned enum to an unbounded set. `candidate_id` is a deterministic UUID derived from run ID, type ID, and validated global sentence bounds; no LLM-generated UUIDs. Assign it after overlap resolution so a checkpoint replay is stable.
- [ ] Add a failing window test using `configured_discovery.discover_configured(sentences, types, llm, *, run_id, sample_rate, window=130, step=110) -> list[dict]`. The fake returns a candidate spanning the overlap with boundaries `[119, 121]` in one response and `[118, 121]` in the next (both lie inside the default windows starting at 0 and 110); expect one longer candidate and a separate nonoverlapping repeated take. Validate global indices against both source length and the specific request window; reject booleans/nonintegers, undeclared IDs, negative/reversed/out-of-range bounds, and empty labels. Derive every sample/word/time field from transcript evidence, never model-supplied times.
- [ ] Implement windows with global coordinates and a prompt listing configured IDs/guidelines. The response schema is `{"clips":[{"type":"image-id","start":0,"end":1,"label":"Station listening liner"}]}`. Ask for complete takes, exhaustive distinct repeats, no quota, no invented text. Skip this pass when `types` is empty.
- [ ] Extract a generic overlap predicate usable without enum identity checks:

```python
def same_take(a: dict, b: dict) -> bool:
    overlap = max(0, min(a["end_index"], b["end_index"]) - max(a["start_index"], b["start_index"]) + 1)
    shorter = min(a["end_index"] - a["start_index"] + 1,
                  b["end_index"] - b["start_index"] + 1)
    return overlap > 0 and overlap / shorter >= 0.5
```

Within a type, keep the existing 50%-of-shorter rule, longer span, then earlier start/end. Across the four built-in image types use mutual coverage instead:

```python
def duplicate_imaging_classification(a: dict, b: dict) -> bool:
    overlap = max(0, min(a["end_index"], b["end_index"]) - max(a["start_index"], b["start_index"]) + 1)
    lengths = (a["end_index"] - a["start_index"] + 1,
               b["end_index"] - b["start_index"] + 1)
    return overlap > 0 and all(overlap / length >= 0.8 for length in lengths)
```

For the four built-in image IDs, priorities are pre/post=2, promo=1, ID=0. Resolve overlapping candidates by descending priority, descending span length, type ID, start/end; discard lower-priority duplicates. Pre/post disagreement adds an ambiguity warning to the survivor. Custom cross-type overlaps survive regardless of display group. This algorithm does not merge disjoint takes or allow image clips into story merging.

- [ ] Add positive fixtures: a complete ~8-second intro; two complete short repeated IDs; a ~38-second subscription promo; an explicit return from ads; a speaker introducing another performer's recording; and a Spotlight with a passing station/song mention. Add nested fixtures: a complete standalone two-sentence ID within a fifteen-sentence promo retains both; an incidental self-identification within a promo is not separately suggested; two substantially matching subtype classifications collapse by precedence. The geometric test only prevents suppression of distinct spans; the prompt/evaluation establishes editorial completeness. Add negative labels for “yeah,” isolated song titles, false starts, unfinished handoffs, and a URL mention embedded in a story. Use synthetic text, clearly labeled as synthetic, not copied database transcripts.
- [ ] Set only the configured Intro acceptance minimum to 1 second, retaining its target/upper bound and leaving the legacy pinned eval specs intact. New types use 1–240 seconds. Test structural duration enforcement with fake candidates separately from semantic quality evaluation: a unit test cannot prove an LLM will reject a plausible-looking fragment. Keep `FRAGMENT_SECONDS` and the old cached baseline unchanged. Task 17 runs the labeled editorial evaluation and blocks a quality-complete claim if short-fragment behavior is poor.
- [ ] Run `python3 -m pytest tests/test_configured_discovery.py tests/test_cut_suggester_postprocess.py tests/test_suggestion_prompt_regression.py -q`. Commit: `feat: discover imaging and custom suggestion types`.

## Task 8: Extract user-defined fields with strict batch matching

**Files:** Create `cut_suggester/extraction.py`, `tests/test_suggestion_extraction.py`, `tests/fixtures/suggestion-result-v2.json`.

- [ ] Define the result shape and exact parser boundary:

```python
# Parser API:
# parse_extraction_response(text: str, expected: dict[str, set[str]])
#     -> dict[str, dict[str, str | None]]
# Each expected candidate must occur exactly once, each required field exactly once.
example = {
    "results": [
        {"candidate_id": "00000000-0000-0000-0000-000000000001",
         "fields": [
             {"field_id": "song-title", "value": "Nobody Wins"},
             {"field_id": "artist-name", "value": "American Aquarium"},
         ]}
    ]
}
```

Use a list of field records on the model-facing wire so duplicate IDs remain detectable instead of being silently collapsed by JSON dictionaries. Explicit null means evidence is missing. Wrong field types, absent entries, duplicate/foreign candidate IDs, and undeclared fields fail that batch. Whitespace-only extracted text normalizes to missing, not a completed name. Detect duplicate JSON object keys with `object_pairs_hook` before structural validation.

- [ ] Write and run this missing-vs-malformed test before implementing the parser:

```python
import json
import pytest
from cut_suggester.extraction import parse_extraction_response

def test_explicit_missing_is_valid_but_absent_result_is_not():
    expected = {"c1": {"artist-name"}}
    payload = {"results": [{"candidate_id": "c1", "fields": [
        {"field_id": "artist-name", "value": None}]}]}
    assert parse_extraction_response(json.dumps(payload), expected) == {"c1": {"artist-name": None}}
    with pytest.raises(ValueError):
        parse_extraction_response('{"results": []}', expected)
```

- [ ] Implement `required_field_ids(type_definition)` as the union of template field tokens and grouping IDs, sorted by ID; don't request descriptive-title unless referenced. Batch at most 20 candidates and at most 24,000 input characters of candidate/context text per request. Add source context in deterministic order: candidate text first, two neighboring sentences on either side, then remaining transcript sentences in source order up to the budget. Include stable speaker IDs when available but never substitute speaker metadata for performer evidence. Truncate only optional context. If the candidate text plus required field instructions alone exceeds the budget, report that candidate as an input-size error and preserve the completed work; do not repeatedly auto-retry unchanged oversized input or silently omit its text. A new search with revised rules/source may be needed. No general summarization pipeline is added.
- [ ] The prompt treats transcript content as evidence, uses the snapshot field instructions, asks for null on insufficient evidence, and never asks for Sequence or a filename. Tests inspect that user-defined instructions and relevant context are present, and that a Radney Foster speaker does not hardcode Radney as the extracted performer. A fake response asserts correct mapping; actual performer accuracy remains part of Task 17's editorial review.
- [ ] Parse all returned fields before committing a batch. In the orchestrator, keep successful batches when another fails and continue independent remaining batches for transient/provider/malformed-response failures; stop all further requests on recovery-write failure or cancellation. Expose failed batch keys for retry. Only all-valid completed batches can make a run ready. A type with no referenced fields makes zero extraction calls.
- [ ] Run `python3 -m pytest tests/test_suggestion_extraction.py -q`. Commit: `feat: extract naming fields in validated batches`.

## Task 9: Durable Python checkpoints and the version-2 run protocol

**Files:** Create `cut_suggester/run_journal.py`, `configured_run.py`, `tests/test_suggestion_run_journal.py`, `tests/test_configured_run.py`; modify `cut_suggester/cli.py`; extend shared contract fixtures and `tests/test_cut_suggester_cli.py`.

- [ ] Define the version-2 envelope in `suggestion-contract-v2.json`. Keep legacy requests (no `schema_version`) on the existing CLI path for existing evals/tests. V2 requires the complete immutable snapshot; unknown versions fail before a request. Configuration internals keep the camelCase fields from Task 2.

```json
{
  "schema_version": 2,
  "run_id": "00000000-0000-0000-0000-000000000001",
  "mode": "fresh",
  "transcript_hash": "fixture-transcript",
  "source_fingerprint": "fixture-source",
  "transcript_units": [
    {"id": 0, "text": "You're listening to Playola.", "word_ids": [0],
     "start_sample": 0, "end_sample": 88200, "start_sec": 0, "end_sec": 2}
  ],
  "options": {"model": "fixture-model", "sample_rate": 44100,
    "stage1_window": 130, "stage1_step": 110,
    "discovery_prompt_version": "configured-v1",
    "extraction_prompt_version": "fields-v1", "product_spec_version": "configured-v1"}
}
```

The actual fixture additionally contains the complete `configuration` object generated in Task 2. `mode` is `fresh`, `automatic`, or `resume`. Credentials remain only in child environment. Pass the app-owned **run directory** returned by `SuggestionRecoveryClient.prepare` as `--journal-dir`, never a model-provided path. This is already `SuggestionRecovery/<owner UUID>/<run UUID>/`; Python must not append a second run-ID directory. The owner manifest outside that run directory is Swift-owned; Python writes only inside the supplied run directory.

- [ ] Write an atomic journal regression against this public API:

```python
from cut_suggester.run_journal import RunJournal

def test_completed_request_survives_a_new_journal_instance(tmp_path):
    calls = []
    journal = RunJournal(tmp_path, request_identity="same-input")
    def produce():
        calls.append("provider")
        return '{"clips": []}'
    import json
    first = journal.request("classify-key", produce, json.loads)
    reopened = RunJournal(tmp_path, request_identity="same-input")
    second = reopened.request("classify-key", produce, json.loads)
    assert first == second == {"clips": []}
    assert calls == ["provider"]
```

- [ ] Implement `RunJournal.request(key, invoke, validate)` to read a validated completed result or call `invoke`, validate its response, atomically write response/result metadata, then return the result. Use same-directory temporary files, flush/fsync, `os.replace`, and directory fsync where supported. Failed parsing/provider calls are recorded as failed attempts, never valid cache hits. A storage failure propagates and prevents more provider calls. Catch corruption as a visible recovery error; do not silently rerun paid work.
- [ ] Derive `request_identity` from the canonical immutable request excluding mode, credentials, and filesystem paths. Include the run ID, model/prompt/spec versions, transcript/source, and full config; calculate each request key from stage identity and actual prompt. A fresh run has a new run ID and bypasses shared caches. Resume opens the same journal even when the original mode was fresh. Pin old cache behavior for legacy evals; no cache-version bump that needlessly invalidates those fixtures. The Python identity manifest also stores the complete immutable request JSON value before provider work. Swift validates it against its durable original request at JSON value level and checks the opaque identity consistently across checkpoint/request records; Python recomputes its own digest on reopen. Do not require Swift to reproduce Python JSON numeric spelling or escaping.
- [ ] Add a validating adapter around the existing tuned LLM seam: partition purposes validate via `parse_partition_response` for their window, classification via `parse_clip_response` plus requested-type checks. Extend `stage1_partition` with an optional validated-request callback only if needed; the default path must keep existing prompts/results. Generic discovery and extraction call the same journal API with their own validators. This preserves successful tuned partition requests even if classification fails.
- [ ] Implement `run_configured_suggest(request, llm, journal, emit)` in `configured_run.py`: validate input; restore or run tuned discovery; restore or run generic windows; checkpoint deduplicated candidate evidence; create fixed extraction batches; attempt/record each; write a revisioned checkpoint after each stage with fields `schema_version: 1`, `run_id`, `request_identity`, `revision`, `phase` (`discovering`, `extracting`, `needs_retry`, or `ready`), `suggestions`, `completed_request_keys`, and `failed_request_keys`; return ready only when every required batch is valid. Responses include `schema_version`, `run_id`, `checkpoint_revision`, `status` (`ready` or `needs_retry`), `suggestions`, and failed batch diagnostics. Emit `QIE_EVENT` progress and `{"type":"checkpoint","run_id":"00000000-0000-0000-0000-000000000001","revision":1}` only after the corresponding write succeeds. Even on nonzero exit, successfully written request records remain recoverable.
- [ ] Add tests for five extraction batches with one failure (four successes survive a new process; retry calls only the failed batch), failure after partition success, all-numbered types skipping extraction, a valid empty batch, malformed top-level output, identical prompt under changed field instructions, changed source rejection, fresh cache bypass, resumed fresh-run reuse, cancellation before checkpoint, interrupted atomic writes, and unknown schema. Keep stdout pure JSON on both CLI branches.
- [ ] Run `python3 -m pytest tests/test_suggestion_run_journal.py tests/test_configured_run.py tests/test_cut_suggester_cli.py tests/test_cut_suggester_cache.py -q`. Commit: `feat: checkpoint and resume configured suggestion searches`.

## Task 10: Swift helper contract, valid-empty completion, and cancellation

**Files:** Create `Models/SuggestionRunWire.swift`; modify `Core/CutSuggestClient.swift`, `Core/LiveCutSuggester.swift`, `Models/CutSuggestOptions.swift`, `Models/CutSuggestionWire.swift`; extend `QuickInterviewEditor/QuickInterviewEditorTests/Core/CutSuggestClientTests.swift`, `LiveCutSuggesterTests.swift`, `Models/CutSuggestionWireTests.swift`.

- [ ] Add `snapshot: SuggestionRunSnapshot?`, `mode: SuggestionSearchMode`, and `journalDirectory: URL?` to `CutSuggestRequest` with initializer defaults preserving old fixture call sites. New app runs always set a snapshot; nil is only legacy compatibility. Define `SuggestionSearchMode: String, Codable, Sendable` with `fresh`, `automatic`, `resume`. Pin option versions in the snapshot; don't silently change the current model selection as part of this feature.
- [ ] Extend the event seam without embedding credentials or raw transcript in progress text:

```swift
// Additional cases in CutSuggestEvent:
case checkpoint(runID: UUID, revision: Int)
case recoverableFailure(runID: UUID, failedRequestKeys: [String], message: String)
```

Define `SuggestionRunWireCheckpoint` in `SuggestionRunWire.swift` for the Python envelope; its converter takes the original Swift snapshot and proposed starts from the durable Swift control manifest defined in Task 12. The checkpoint's Python revision comes from the Python journal, its control revision comes from that manifest; neither is an ordering substitute for the other. Python stores candidate evidence and snake_case phase values, while Swift owns final names/numbering and its camelCase document records. Decode phase `needs_retry` explicitly to `.needsRetry`; map candidate evidence through `CutSuggestion.Wire`, then attach fields and the supplied snapshot. Do not ask Python to emit a full Swift `CutSuggestion` or directly decode its journal as `SuggestionRunCheckpoint`. Retain `.progress(String)` and `.completed([CutSuggestion])`; V2 result decoding validates its run ID and stamps the snapshot onto returned records. Candidate UUIDs come from the V2 wire; only the legacy path injects new UUIDs. New responses reject duplicate candidate IDs and type IDs absent from the request snapshot, even if a historical document decoder accepts them.

- [ ] Write the cross-language fixture test: Swift encodes the shared V2 request including all field/type definitions, decodes it to a JSON value, and compares it to the fixture at value level; Python validates that same fixture. Do not assert raw JSONEncoder byte order, whitespace, floating-point spelling, or URL escape choices. A separate subprocess integration test can feed Swift-produced bytes to Python without comparing those bytes to golden formatting. Swift decodes `suggestion-result-v2.json` and a checkpoint built from the same fixture with a custom ID, explicit missing field, and preserved discovery label. Copy `configurationHash` as supplied snapshot provenance; Python independently fingerprints the complete actual immutable request, so correctness does not rely on identical JSON hash implementations in both languages. Test wrong run ID/schema, duplicate IDs, missing fields, and malformed UTF-8/JSON output fail the whole result.
- [ ] Update `LiveCutSuggester.encodedRequest`, argv construction, progress decoder, and `completedEvent`. A fresh V2 run adds refresh policy; resume adds the same journal directory without refreshing successful journal requests. Keep scratch request-file cleanup and process-group cancellation. Separate persistent journal lifetime from scratch/cache cleanup; “Clear Cache” must not delete unfinished searches.
- [ ] Remove the valid-empty rejection in **both** `LiveCutSuggester.completedEvent` and the page model's completion path (the latter is fully replaced in Task 13). A well-formed completed empty list is success; malformed/all-invalid provider data must be distinguished upstream and remain an error. Preserve diagnostic metadata for explaining empty results without treating zero length alone as failure.
- [ ] Add deterministic live-adapter tests using the existing process seams: checkpoint line recognition; stale revision ignored; cancellation terminates the child and doesn't emit completion; stderr without progress doesn't misclassify auth; credential stays out of encoded request, checkpoint, and argv. Avoid launching the actual provider helper in unit tests.
- [ ] Run `CutSuggestClientTests`, `LiveCutSuggesterTests`, and `CutSuggestionWireTests`. Commit: `feat: bridge resumable suggestion runs into Swift`.

## Task 11: Project schema, permanent reservations, and undo transactions

**Files:** Create `Models/SuggestionDocumentMutation.swift`; modify `Models/EditorDocumentState.swift`, `ProjectFile.swift`, `Core/ProjectPackage.swift`, `Documents/ProjectDocument.swift`, `Views/Pages/Editor/EditorModel.swift`, `Views/Pages/Project/ProjectModel.swift`; extend tests in `Models/EditorDocumentStateTests.swift`, `ProjectFileTests.swift`, `Core/ProjectPackageTests.swift`, `Documents/ProjectDocumentTests.swift`, `Views/Pages/Editor/EditorSuggestionFlowTests.swift`, `EditorDocumentMutationTests.swift`.

- [ ] Extend the project document value with default-decoded fields: `suggestionStarts: SuggestionStarts`, `suggestionBatch: SuggestionBatch?`, `issuedSuggestionNumbers: [SequenceReservation]`, `unfinishedSuggestionRun: SuggestionRunCheckpoint?`, `lastAppliedSuggestionRunID: UUID?`, and `suggestionRecoveryOwnerID: UUID?`. Allocate the owner with injected UUID when a project first starts recovery-enabled work; decoding old documents must not create random equality changes. Populate all fields in `EditorModel` initialization, `documentState`, `mutateDocument`, and `restoreDocument`. This explicit four-path audit prevents values disappearing on Undo/save.
- [ ] Write the permanent-reservation acceptance regression using a real editor fixture:

```swift
@Test func undoAcceptanceKeepsItsIssuedNumber() async throws {
  let plan = Fixtures.editPlan()
  let model = EditorModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"),
    canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan,
    sourceFingerprint: "fp-flow")
  var candidate = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12, 13, 14, 15, 16])
  candidate.provenance.transcriptHash = plan.transcriptHash
  candidate.provenance.sourceFingerprint = "fp-flow"
  let type = SuggestionDefaults.configuration.types.first { $0.id == "spotlight" }!
  let reservation = SequenceReservation(candidateID: candidate.id,
    key: SuggestionSequenceKey(typeID: type.id, fields: [], provisionalCandidateID: nil),
    number: 3, canonicalValues: [:])
  candidate.title = "Spotlight 3"
  candidate.naming = SuggestionNamingRecord(runID: Fixtures.uuid(2), typeID: type.id, typeName: type.name, typeGroup: type.group,
    discoveryLabel: "Writing on the road", extractedValues: [:], missingFieldIDs: [],
    correctedValues: [:], reservation: reservation)
  let snapshot = SuggestionRunSnapshot(runID: Fixtures.uuid(2),
    configuration: SuggestionDefaults.configuration, configurationHash: "fixture",
    model: "fixture-model", discoveryPromptVersion: "configured-v1",
    extractionPromptVersion: "fields-v1", productSpecVersion: "configured-v1",
    transcriptHash: plan.transcriptHash, sourceFingerprint: "fp-flow", sampleRate: plan.source.sampleRate)
  model.mutateDocument(recordUndo: false) {
    $0.cutSuggestions = [candidate]
    $0.suggestionBatch = SuggestionBatch(snapshot: snapshot,
      actualStarts: SuggestionStarts(), canonicalGroups: [])
  }
  model.cutSuggestions.acceptTapped(candidate.id)
  await model.undoTapped()
  expectNoDifference(model.slices.count, 0)
  expectNoDifference(model.documentState.issuedSuggestionNumbers, [reservation])
  expectNoDifference(model.documentCutSuggestions[id: candidate.id]?.status, .pending)
}
```

- [ ] Implement a single acceptance transaction: validate staleness/bounds/reservation ownership; derive and offset the slice exactly once using existing acceptance behavior; capture `old`; form `new` with slice+accepted status+ledger entry; record one undo snapshot; rebase **only the ledger insertion** into undo/redo snapshots; publish the new state once and dirty once. Do not call `mutateDocument(recordUndo:false)` with the entire acceptance body, which would make the clip non-undoable. Use a small `recordingPermanentReservations` mutation option or focused helper, not an unrelated rewrite of `UndoStack`.

```swift
// History transform used after recording the ordinary acceptance mutation:
let issued = reservation
documentUndo.rebase { state in
  if !state.issuedSuggestionNumbers.contains(where: { $0.identity == issued.identity }) {
    state.issuedSuggestionNumbers.append(issued)
  }
}
```

This block runs inside `EditorModel` against its existing `documentUndo`; `reservation` is the validated new entry. Ledger deduplication uses `SequenceReservation.identity` (candidate/key/number), while synthesized value equality includes canonicalValues. Never override whole-record equality to ignore metadata: document change detection must still notice spelling edits. An existing issued identity retains its original ledger metadata; a corrected pending display name does not add a second ledger entry. Restoring a previously issued reservation to its same owner is valid; a different owner produces a visible conflict. Deleting or renaming a slice never edits the ledger.

- [ ] Add cases for delete/reopen/rerun after acceptance; undo/redo/reaccept; accept → undo → group-spelling correction → reaccept with exactly one ledger identity; changing a restored candidate's group/number leaves old issued entry; ordinary clip creation and offset behavior unchanged; non-undoable batch replacement rebases batch metadata and candidates together; next-start Undo leaves current actual starts unchanged; explicit pending renumber is undoable and preserves rejected/issued reservations. Validate conflicts again in the editor's final acceptance closure, not only in a child model.
- [ ] Set `ProjectFile.currentSchemaVersion = 2`; preserve the existing `1...current` read gate. Track whether the opened V1 project remains untouched. Skip background auto-suggest and persisted owner allocation in that state; opening/closing alone makes no document-content change or `registerChange` call and leaves on-disk bytes/schema unchanged. The existing audio-only hydration `sink.commit` (same `ProjectFile`, session-copy source) is permitted; assert unchanged file/schema and no dirtiness. Explicit Suggest Cuts, a document edit, or explicit Save permits upgrade. New/V2 projects keep auto-suggest. Upgrade a loaded V1 file on its next authorized write through `ProjectModel.wireEditor`/document save paths, not only new imports. Default-decode new state, retain unknown historical types with snapshot labels, and infer only known legacy slice type association by matching accepted suggestion UUIDs. Do not parse old clip titles into reservations or opt those clips into exact-name export.
- [ ] On `EditorDocumentState.rekeyed(to:)`, clear stale candidates, applied batch, and unfinished run while retaining issued numbers, future starts, and clips. Recovery manifests with the old transcript remain stale and cannot resume. Revert explicitly restores saved ledger/version state; duplication copies issued numbers with independent recovery ownership in Task 12.
- [ ] Run the listed model/document/editor suites and `EditorClipOffsetTests`. Round-trip the unchanged V1 fixture and an in-memory V2 package, including Unicode/custom fields and historical deleted definitions. Commit: `feat: persist suggestion numbering without reusing issued counts`.

## Task 12: Recovery storage and document ownership

**Files:** Create `Core/SuggestionRecoveryClient.swift`, `QuickInterviewEditor/QuickInterviewEditorTests/Core/SuggestionRecoveryClientTests.swift`; modify `Documents/ProjectDocument.swift`, `Views/Pages/Project/ProjectModel.swift`, `ProjectHostView.swift`; extend `Project/ProjectHydrationTests.swift`, `Documents/ProjectDocumentTests.swift`.

- [ ] Implement the following dependency contract, backed by an actor for manifest operations. Python alone writes request files in the returned run directory; Swift alone owns manifests/ownership. Never have both languages replace the same manifest.

```swift
struct SuggestionRecoveryOwner: Codable, Equatable, Sendable {
  var id: UUID
  var documentURL: URL?
  var sourceFingerprint: String
  var transcriptHash: String
}
struct SuggestionRecoveryControl: Codable, Equatable, Sendable {
  var revision: Int
  var proposedStarts: SuggestionStarts
  var originalBatchFingerprint: String?
  var isPaused: Bool
}
struct SuggestionRecoveryPreparation: Sendable {
  var snapshot: SuggestionRunSnapshot
  var originalRequest: Data
  var control: SuggestionRecoveryControl
}
struct SuggestionRecoveryClient: Sendable {
  var prepare: @Sendable (SuggestionRecoveryOwner, SuggestionRecoveryPreparation) async throws -> URL
  var updateControl: @Sendable (SuggestionRecoveryOwner, UUID, SuggestionRecoveryControl, Int) async throws -> Void
  var load: @Sendable (SuggestionRecoveryOwner) async throws -> SuggestionRunCheckpoint?
  var checkpoint: @Sendable (SuggestionRecoveryOwner, UUID, Int) async throws -> SuggestionRunCheckpoint
  var discard: @Sendable (SuggestionRecoveryOwner, UUID) async throws -> Void
  var duplicate: @Sendable (SuggestionRecoveryOwner, SuggestionRecoveryOwner) async throws -> Void
  var confirmSaved: @Sendable (SuggestionRecoveryOwner, UUID) async throws -> Void
  var recoverableOrphans: @Sendable (String, String) async throws -> [SuggestionRecoveryOwner]
}
```

- [ ] Write a reopen test with two independently constructed store instances: prepare a run, write a fixture Python checkpoint, load with the second instance, and assert original snapshot/candidate UUIDs survive. Use a temporary directory injected into the store; no app-wide real data or sleeps.
- [ ] Store under `Application Support/<AppDirectories.folderName>/SuggestionRecovery/<owner UUID>/<run UUID>/`. `prepare` atomically writes an owner manifest with current document URL, source/transcript hashes, immutable snapshot, original request, current run ID, and Swift control (proposedStarts, originalBatchFingerprint, isPaused, revision) **before** any provider call. `updateControl` checks expected control revision, increments with checked arithmetic, and atomically persists proposed-start edits, pause/resume, or a newly confirmed old-batch fingerprint before exposing the change as recoverable. Journal records survive cache pruning. `checkpoint` validates run/input identity, reads the latest Python disk checkpoint and Swift control manifest, and returns a combined document-storable value. Python owns validated provider work and pythonRevision; Swift owns controlRevision/proposed starts/pause/batch fingerprint. Compare each counter only with its own last observed or archived revision. Reopening starts from validated durable records, not a zeroed in-memory revision assumption. The `.pie` archive is a portable saved copy: restore missing local files from it, merge a newer same-identity archive component only against that component's revision, and fail on equal-revision different-content or conflicting input identities. Never infer Swift control state from Python's terminal ready phase; recompute numbering conflicts against current issued reservations after loading. An unreadable/corrupt/write-failed recovery state is visible and prevents advancing the search.
- [ ] Persist the owner UUID and latest structured checkpoint in `.pie` state. Save a portable recovery archive containing the manifest and validated request records as an optional `suggestion-recovery.json` package child; add it to `ProjectPackage` decode/encode/rewrite and `ProjectDocument` snapshot without touching the audio wrapper. JSON values/encoded bytes are data, never executable paths; accept only known archive keys and restore through the owner store. Add read/write/duplicate tests for this optional package child. Removing a completed/discarded run removes the child on the next save. A structured checkpoint containing only request-key strings is insufficient to preserve successful requests when moving a project to another machine. Also index the manifest by standardized document URL to recover a first search that crashed before autosave persisted the UUID. Verify source/transcript before using that index; mismatches are never auto-attached. Untitled documents keep their owner manifest and native document recovery identity; if native recovery fails, source/transcript matching only offers an explicit orphan-recovery choice. Use `recoverableOrphans(sourceFingerprint, transcriptHash)` to return owner manifests for that chooser; do not silently pick one of multiple matches.
- [ ] Document window teardown cancels the running process/task but leaves checkpoints. On hydrate, load the current owner's checkpoint before auto-suggest (which remains disabled for untouched V1 projects); show Resume/Discard and don't issue a paid request. If a run ID equals the saved `lastAppliedSuggestionRunID`, don't present/reapply it.
- [ ] After applying a batch, retain an applied journal until durable saved content proves that `lastAppliedSuggestionRunID` is on disk. `confirmSaved` reads the saved `project.json` at the document URL and compares owner/run IDs before cleanup; `FileWrapper` construction or the in-memory save indicator alone is not proof that disk committed. If not yet saved or still untitled, leave the journal. On next hydrate/save observation, repeat this cheap check. A crash before save retains the ready result for explicit recovery; a crash after save skips duplicate application.
- [ ] On Save As/Duplicate, create a fresh owner ID and atomically copy the recovery journal before pointing the new document at it; a copied checkpoint retains the immutable run ID, while storage ownership differs. Use `ProjectHostView`'s document identity/fileURL updates and the existing document replacement path, not source fingerprint alone. A moved project whose persisted owner matches may update its location only when the previous location no longer exists; a simultaneous copied project receives a new owner. Test that discarding one copy cannot delete another copy's work.
- [ ] Test checkpoint write failure stops requests, malformed checkpoint is reported, close/reopen and crash-before/after-apply cases, save-as isolation, unsaved matching-orphan selection, stale-source refusal, and cache clearing preservation. Run recovery/hydration/document suites. Commit: `feat: preserve unfinished suggestion searches across document recovery`.

## Task 13: Search lifecycle, replacement confirmation, and retry UI state

**Files:** Create `Views/Pages/CutSuggestions/SuggestionRunModel.swift`, `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/CutSuggestions/SuggestionRunModelTests.swift`; modify `CutSuggestionsPageModel.swift`, `CutSuggestionsPageView.swift`, `Views/Pages/Editor/EditorModel.swift`; extend `CutSuggestionsPageTests.swift` and `EditorSuggestionFlowTests.swift`.

- [ ] Define a focused `@MainActor @Observable final class SuggestionRunModel: ViewModel` with injected cutSuggest/recovery/configuration/UUID dependencies and this state contract:

```swift
enum SuggestionRunPhase: Equatable {
  case idle
  case confirmingReplacement
  case running(runID: UUID, message: String)
  case paused(runID: UUID, message: String)
  case needsRetry(runID: UUID, message: String)
  case needsNumbering(runID: UUID, message: String)
  case failed(message: String)
}
```

The child reads `currentDocument: @MainActor () -> EditorDocumentState`, receives `makeRequest: @MainActor (SuggestionRunSnapshot, SuggestionSearchMode, URL?) -> CutSuggestRequest`, and emits `onCheckpoint: @MainActor (SuggestionRunCheckpoint) -> Void` and `onApply: @MainActor ([CutSuggestion], SuggestionBatch) throws -> Void`. The editor owns those mutations; `onApply` revalidates source and reservations synchronously on the main actor immediately before atomically replacing the batch. The run model has `suggestTapped()`, `replaceConfirmed() async`, `cancelReplacementTapped()`, `cancelSearchTapped()`, `resumeTapped() async`, `discardSearchTapped() async`, and `applyNumberingTapped(_ starts: SuggestionStarts) async` actions. The page delegates existing onboarding/key resolution to its current `SettingsModel` seam; keys never enter persisted model properties.

- [ ] Write the first behavioral test before implementation: an existing batch + `suggestTapped` enters confirmation and invokes neither client nor recovery prepare; Cancel leaves exact document equality. Use a `LockIsolated<Int>` call counter and an injected empty stream. Include the exact copy in model constants:

```swift
let replaceTitle = "Replace existing suggestions?"
let replaceMessage = "This will run a new search and replace the current suggestions. Your saved clips will not be changed."
let replaceButtonTitle = "Replace Suggestions"
let cancelButtonTitle = "Cancel"
```

- [ ] Implement launch ordering: resolve valid configuration/key; obtain explicit confirmation when needed; capture immutable snapshot, an original-batch content fingerprint, and future starts; build and encode the original request with nil journal URL; prepare recovery with that data and its initial control manifest; build the launch request with the returned URL; then start the stream. The old-batch fingerprint includes IDs/status/naming values so edits after a pause are detected across relaunch, rather than relying on an in-memory revision counter. Guard all candidate mutations while requests are running or numbering correction is active, including callbacks invoked directly by keyboard actions. Saved clip actions remain enabled. A second search is unavailable until the pending run is explicitly discarded.
- [ ] Track active run ID **and a per-attempt generation UUID**: Resume retains the run ID but creates a new attempt ID. A cancelled attempt must not update phase after a newer attempt resumes the same run. Every progress/checkpoint/completion/error handler checks both tokens; cancellation synchronously invalidates the attempt before terminating its task.

```swift
// Inside each event handler, before mutating observable state:
guard activeRunID == snapshot.runID, activeAttemptID == attemptID else { return }
try Task.checkCancellation()
```

Declare `activeRunID: UUID?` and `activeAttemptID: UUID?` on the model; inject UUID creation through Dependencies. Clear attempt ownership on stop. A stream that ends without completion/recoverable status becomes a visible error, never an endless spinner.

- [ ] Read validated disk checkpoints on events and persist them non-undoably through `onCheckpoint`. On recoverable failure or Cancel, retain old suggestions and checkpoint; enable old-batch edits. Resume compares the durable originalBatchFingerprint with current batch content and repeats replacement confirmation if changed. If the baseline is missing and current suggestions exist, require confirmation. Persist the newly confirmed baseline through updateControl. Checkpoint/control writes precede document mirrors; a crash before autosave must retain paused state and proposed starts in the control manifest. Global config edits leave the old snapshot intact; transcript/source changes refuse resume/apply. Background auto-suggest additionally refuses an untouched opened V1 project; for eligible new/V2 projects it requires no active/unfinished run and an empty batch at both start and apply, and never opens a key-entry sheet.
- [ ] On ready completion, run pure numbering against current issued ledger, then call the final synchronous editor apply. A start conflict stores the completed checkpoint as needsNumbering and displays the current minimum; correction reruns only pure numbering. An explicit failed correction changes neither current starts nor current batch. On success install candidates, batch actual starts, applied run ID, and clear unfinished state in one non-undoable rebased mutation. Zero candidates is a successful clearing transaction. Start preferences stay future-facing; the batch stores its own actual starts.
- [ ] Add each lifecycle regression with controlled stream continuations: no-results success clears, malformed/provider failure preserves, 4-of-5 naming failure retries only missing work, cancellation late completion ignored, same-run old-attempt ignored, saved reservation changes during search and numbering dialog, two Apply attempts with changed minima, close/reopen paused run, background/manual race, configuration edit during run, and discarded checkpoint late event. Assert clips and future starts are unchanged on every unsuccessful path. Do not sleep; explicitly finish/yield the controlled streams.
- [ ] Connect `.confirmationDialog`/`.alert` presentation to model state, progress/cancel/resume/discard controls to model actions, and no-matches/error copy to computed model values. Keep only layout and bindings in the view. Run `SuggestionRunModelTests`, `CutSuggestionsPageTests`, and `EditorSuggestionFlowTests`. Commit: `feat: replace and resume suggestion searches safely`.

## Task 14: Configuration editor and field-based naming builder

**Files:** Create `Views/Pages/SuggestionSettings/SuggestionSettingsModel.swift`, `SuggestionSettingsView.swift`, `NamingTemplateModel.swift`, `NamingTemplateView.swift`; create `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/SuggestionSettings/SuggestionSettingsTests.swift`, `NamingTemplateTests.swift`; modify `QuickInterviewEditorApp.swift`, `Views/Pages/CutSuggestions/CutSuggestionsPageModel.swift`, `CutSuggestionsPageView.swift`.

- [ ] Define `SuggestionSettingsModel` as an observable ViewModel with `draft: SuggestionConfiguration`, `loadedRevision: Int`, selected type/field ID, `validationMessages`, `statusMessage`, and `isSaving`. Load via the configuration client, copy into a local draft, publish only successful saves. Actions: `addTypeTapped()`, `removeTypeTapped(_ id: String)`, `restoreBuiltInTapped(_ id: String)`, `addFieldTapped()`, `removeFieldTapped(_ id: String)`, `saveTapped() async`, `cancelTapped()`. Create custom IDs with injected UUID and prefix; select a valid display group explicitly on the draft. Use default placeholder draft names only in unsaved rows, never as silently saved valid rules.
- [ ] Write a failing reference-deletion test, then implement reference checks in the configuration layer and presentation in the model:

```swift
@Test func referencedArtistFieldCannotBeRemoved() {
  let model = SuggestionSettingsModel(configuration: SuggestionDefaults.configuration)
  model.removeFieldTapped("artist-name")
  expectNoDifference(model.draft.fields.map(\.id),
    SuggestionDefaults.configuration.fields.map(\.id))
  #expect(model.validationMessages.joined().contains("Song Intro"))
}
```

Provide `init(configuration:)` for an already-loaded draft and `viewAppeared() async` for the live client path. `loadedRevision` starts at that configuration's revision.

- [ ] Define `NamingTemplateModel` with `components: [NamingComponent]`, available fields, selected grouping field IDs, and sample field values. Actions add a literal/field/Sequence component, edit literal text, remove a component, move it up/down, and select grouping fields. Preview calls `renderSuggestionName` with sample number 1 and example values, displays “Example,” and never contacts an LLM. Stable component row IDs are editor-local wrappers; persisted ordering is the array. Unavailable field IDs produce validation messages, not dropped tokens.
- [ ] Add the naming-builder test before implementation:

```swift
@Test func previewCanCombineAnExtractedTitleAndNumber() {
  let model = NamingTemplateModel(
    components: [NamingComponent(kind: .literal, value: "Promo "),
                 NamingComponent(kind: .sequence, value: nil)],
    fields: SuggestionDefaults.configuration.fields)
  expectNoDifference(model.previewName, "Promo 1")
  model.literalChanged(at: 0, text: "ID ")
  expectNoDifference(model.previewName, "ID 1")
}
```

Declare those initializer arguments and `literalChanged(at:text:)` on the template model. Add tests for combined intro naming, custom extraction instructions, optional/repeated Sequence, field rename retaining references, ordered movement, literal validation, and sequence grouping independent of token order.

- [ ] Lay out Types and Fields sections with a sidebar/list and selected item editor. Types expose name, group, discovery guidelines, template builder, and grouping controls; Fields expose name and extraction instructions. All labels/help/error/save/cancel strings come from models. Built-in editors explain the tuned behavior and offer restoration of missing presets. Removal affects future searches; historical candidates remain visible. No raw JSON editor or “deterministic/non-deterministic” terminology.
- [ ] Add app Settings entry “Suggestion Rules” while retaining existing API-key and cache settings. “Configure Suggestions…” on the panel opens the same editor with an independent draft against the shared saved revision. Test two windows: A saves, B's stale save fails visibly; B can explicitly reload, preserving the saved A configuration. Test save failure keeps the draft and sheet open, Cancel publishes nothing, and validation prevents deletion of the last type.
- [ ] Run `SuggestionSettingsTests`, `NamingTemplateTests`, and existing Settings tests. Commit: `feat: let users edit suggestion rules and naming templates`.

## Task 15: Filters, field correction, canonical spelling, and numbering controls

**Files:** Create `Views/Pages/CutSuggestions/SuggestionReviewModel.swift`, `SuggestionReviewView.swift`, `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/CutSuggestions/SuggestionReviewTests.swift`; modify `CutSuggestionsPageModel.swift`, `CutSuggestionsPageView.swift`, `Models/CutSuggestionPresentation.swift`, `Views/Pages/Editor/EditorModel.swift`; extend `CutSuggestionsPageTests.swift`, `Views/Pages/Editor/EditorClipBandsTests.swift`.

- [ ] Add local filter state to the page: `selectedTypeIDs: Set<String>?`, with nil meaning All Types and an empty set meaning none. Build available IDs/labels from both current configuration and historical batch snapshots. Group rows expose a model-derived all/some/none selection state. Changing filters never changes run configuration or stored suggestion status.

```swift
func visibleSuggestions(_ suggestions: [CutSuggestion], selected: Set<String>?) -> [CutSuggestion] {
  guard let selected else { return suggestions }
  return suggestions.filter { selected.contains($0.productType.rawValue) }
}
```

Place this pure helper in `CutSuggestionPresentation.swift`. The page's ranked list and pending transcript bands use the same filter. Change `EditorModel`'s suggestion-band source from `documentCutSuggestions.pending` to the child's filtered pending suggestions; saved slice bands remain independent.

- [ ] Write a filter regression using two fixture candidates with different types; toggle to one ID and assert both visible rows and pending bands select that ID while document equality, generated names, ranking, and slices remain unchanged. Cover All Types, none, partially selected Audio Images, removed historical custom type, and no-matches copy distinct from no results.
- [ ] Define `SuggestionReviewModel` with a supplied current document snapshot, candidate ID or sequence key, draft fields/start/canonical spelling, computed preview names/errors, and an `onApply` callback carrying the validated proposed change. Actions `fieldChanged(_ id:String,value:String)`, `applyFieldsTapped()`, `startChanged(_ value:String)`, `renumberTapped()`, `canonicalValueChanged(_ id:String,value:String)`, `applyGroupSpellingTapped()`, and `cancelTapped()`. No draft keystroke mutates the actual document. Apply re-reads the current document and validates again.
- [ ] Field correction overlays manually corrected values over extraction. An unchanged sequence key retains its reservation. A changed key allocates in the new group beyond issued/retained occupancy; old issued reservations remain permanently recorded. Use the owning run snapshot's template/instructions and destination canonical values. Pending group-spelling changes show a list of affected before/after names and update pending names in one undoable mutation; accepted/rejected names remain unchanged. No implicit batch renumber follows a field edit.
- [ ] Future controls say “Start next search at”; applied metadata says “This search started at.” Per-song overrides appear after extraction. Add a **Song Starts** list that includes every saved group override, including keys with no current candidates, displaying their canonical song/artist labels and **Reset to Type Start**. Field correction leaves old overrides visible rather than transferring/deleting them implicitly. Reset deletes only that future override and is undoable; it never renumbers current suggestions. Test orphaned override visibility/reset, correction to a new title, and later reappearance of the old key. The review renumber action is visibly separate and previews changed pending names. Positive integer parsing rejects decimals/sign-only/zero/overflow; treat “minimum safe value exceeds Int.max” as exhausted instead of displaying a wrapped number. Never allow an edit that partially renumbers before a later allocation fails.
- [ ] Add tests for artist correction against an older template, missing fields/fallback acceptance, two takes with case-variant performers, explicit group spelling edit, group change with occupied numbers, pending-only renumber skipping rejected/issued slots, starts preserved across reopen, and Undo of future start vs Undo of explicit renumber. UI-enabled state reflects run locks, but action methods enforce them independently.
- [ ] Build the menu with All Types, group toggles, and child checkmarks; show mixed selection through model-provided state/icon. Bind the correction/renumber sheets to review-model values. Use the repository's existing alert presentation conventions. Run `SuggestionReviewTests`, `CutSuggestionsPageTests`, `EditorClipBandsTests`, and `EditorDocumentMutationTests`. Commit: `feat: filter and review suggestions by editable type and sequence`.

## Task 16: Exact generated filenames and export collision review

**Files:** Modify `Models/ExportNaming.swift`, `Views/Pages/Editor/EditorModel.swift`, `EditorView.swift`; create `Views/Pages/Editor/ExportReviewModel.swift`, `ExportReviewView.swift`, `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/ExportReviewTests.swift`; extend `Models/ExportNamingTests.swift` and `Views/Pages/Editor/EditorExportRemovalTests.swift`.

- [ ] Add a defaulted name-policy argument to preserve existing callers:

```swift
enum ExportNamePolicy: Equatable, Sendable { case sourcePrefixed, exactClipName }
struct ExportNameMapping: Equatable, Identifiable, Sendable {
  var id: UUID
  var requestedName: String
  var proposedName: String
  var requiresConfirmation: Bool
}
// Existing helper gains: policy: ExportNamePolicy = .sourcePrefixed
```

Choose `.exactClipName` only when the saved slice has new `suggestionNaming` provenance. Manual later renames use the current slice name. Legacy type association alone remains source-prefixed. Keep sanitation and UTF-8 limits, calculating remaining bytes for the actual collision suffix on each attempt rather than assuming at most three suffix digits.

- [ ] Write the first failing test, then implement the policy branch:

```swift
@Test func generatedNamesDoNotIncludeSourceStem() {
  var taken: Set<String> = []
  expectNoDifference(exportFileName(sourceStem: "Tape Two", sliceName: "ID 7", index: 1,
    taken: &taken, policy: .exactClipName), "ID 7.aiff")
}
```

- [ ] Implement pure `preflightExportNames(slices: [Slice], sourceStem: String, existing: Set<String>) -> [ExportNameMapping]`: derive each requested sanitized/truncated name without disambiguation, allocate unique proposed names in export order, and flag collisions involving generated-name clips. If a legacy item collides with a generated item earlier in the batch, the conflict still involves generated provenance and must be reviewed. Detect collisions after normalization/truncation, not by template text. Never change a clip's displayed name or editorial reservation here.
- [ ] Add cross-type duplicate-name, destination `ID 1.aiff`, case variant, sanitized-equivalent path characters, very long Unicode names, within-batch duplicate, manual renamed generated clip, and legacy-only collision tests. Assert exact requested/proposed mapping and confirmation flags. More than 999 suffixes remains under the filename byte limit with checked suffix increments.
- [ ] Implement `ExportReviewModel` with mappings, `reviewNamesTapped()`, `exportWithSuffixesTapped()`, and model-owned warning/copy labels. “Review Names” closes export before copying; “Export with Suffixes” authorizes only the displayed mappings. Allow rendering results to remain available during review so a declined collision need not rerender immediately. Keep removal-aware rendering, progress, cancellation, and clip offset behavior unchanged.
- [ ] Extend the copy outcome to return copied URLs, cancellation/error, and an optional new collision mapping. Before each copy recheck destination and catch `file exists` from the copy itself (a race can occur after the check). Never overwrite. If a generated-name mapping changes, stop before that item and show the revised mapping; retain already rendered/uncopied sources and list already copied files. Resume copies only remaining items after approval, never duplicates already copied ones. Legacy-only new collisions may use existing silent suffix behavior.
- [ ] Write an injected-filesystem test where another writer creates `ID 1.aiff` after preflight: no overwrite, no silent `ID 1 2.aiff`, one new review mapping. Add cancellation-after-partial-copy, confirmation then second race, all-safe no-dialog, and old export tests. Keep ordinary export destination file protection in the existing dependency/file-copy seam; no live Logic automation is needed.
- [ ] Run `ExportNamingTests`, `ExportReviewTests`, and `EditorExportRemovalTests`. Commit: `feat: review generated filename collisions before export`.

## Task 17: Integration, editorial quality, and completion evidence

**Files:** Extend `tests/test_configured_run.py`, create `tests/test_suggestion_editorial_eval.py`, `evals/cut_suggestions/editorial_runner.py`; extend `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Editor/EditorSuggestionFlowTests.swift`; update `README.md`, `evals/cut_suggestions/README.md`; create `docs/superpowers/reviews/2026-09-07-suggestion-types-validation.md` during execution.

- [ ] Add an end-to-end deterministic helper test using the shared V2 fixture and injected model: discover Spotlight+Intro+four images+custom; extract performer/title; output stable candidate IDs/fields; fail one naming batch; reopen and resume; verify no successful request repeats. Swift consumes the resulting checked-in response fixture and applies names without depending on Python at test runtime. Keep the legacy eval path and audio engine unchanged.
- [ ] Add a full editor regression: start Spotlight at 7, apply a batch, accept 7, delete its clip, rerun, and get a next safe number; undo deletion restores the same clip without releasing/duplicating its reservation. Export exact names, then preflight the same destination and require collision review. A second independent project starting at 1 remains independent; its destination collision warns rather than inventing a global count. Test saved clips survive an empty replacement and every failure path.
- [ ] Implement an editorial runner for the synthetic dataset from Task 7. It loads transcript/labels, calls the same configured discovery entry point, and reports expected positive take recall plus forbidden negative-span matches and unexpected overlaps by type. Labels use global sentence spans and expected type IDs; compute overlap with the same sentence-span predicate for comparisons. CLI modes `cached` and `live` mirror the existing runner; cache misses in cached mode fail without network. Add deterministic metric tests with handcrafted predictions; do not present those as model-quality evidence.
- [ ] Run the existing cached Spotlight regression and compare candidate spans/discovery labels before naming, not generated titles. Then run `python3 -m evals.cut_suggestions.editorial_runner --mode cached`; record a cache miss honestly when no approved live responses exist. For a live quality check, use the existing configured provider and synthetic/previously authorized source material, save results and review the short-intro/negative-fragment pairs together. Command: `python3 -m evals.cut_suggestions.editorial_runner --mode live`. The feature's purpose authorizes using the existing model integration; no external message or database write is part of this test. Do not expand to unrelated private material.
- [ ] Review editorial output for: Spotlight spans unchanged under default naming/imaging additions; short complete handoffs retained; isolated titles/acknowledgments/false starts not promoted to intros; distinct repeated takes retained; correct introduced performer; station ID vs break transition vs direct promotion; and longer promos. Post-commercial guidance lacks live transcript evidence in the original research, so explicitly label synthetic-only validation if that remains true. If negative fragments fail, stop the quality-complete claim and diagnose the Intro path; do not loosen expectations, silently raise an arbitrary floor, or edit the successful Spotlight prompt to mask failures.
- [ ] Run the full required verification after implementation stabilizes:

```bash
python3 -m pytest -q
make -C QuickInterviewEditor test-fast
make -C QuickInterviewEditor format-check
make -C QuickInterviewEditor lint
```

Use `make -C QuickInterviewEditor test` for pre-push/CI parity if proceeding to that workflow. Do not repeatedly broaden tests after all checks pass without a new change or unresolved failure. No tests need running for this planning-only commit.

- [ ] Manually inspect the native app with fixtures: Types mixed checkmarks; configure/save/cancel and two-window stale drafts; combined intro name preview; missing-field correction; per-song starts; next-start Undo; replace confirmation; cancelled/recovered search; numbering conflict correction; accepted clip deletion; exact export collision review. Confirm keyboard focus, accessible labels, and disabled actions match model state. This is a native SwiftUI app, so a browser mockup is not a substitute for this check.
- [ ] Update README with the three groups/six defaults, Types filter, custom fields/templates, app-wide vs project settings, Start next search at, permanent issued counts, Resume/Discard vs fresh search, and collision review. Record actual commands/results and quality limits in the validation document. Use `superpowers:verification-before-completion` and `superpowers:requesting-code-review` before declaring the feature complete; keep implementation review distinct from this plan review. Commit: `test: validate configurable suggestions across recovery and export`.

## Coverage and self-review

| Approved requirement / adversarial finding | Tasks |
| --- | --- |
| Preserve default Spotlight discovery and topic-based merging | 1, 6, 7, 17 |
| Six editable defaults, custom types/fields, combined templates | 2, 5, 6, 8, 14 |
| Partial built-in removal/restoration and explicit routing (#3) | 2, 6, 14 |
| Separate tuned/image passes, image specificity, custom overlap (#6) | 6, 7 |
| Short complete intros and negative fragment evaluations (#7) | 7, 17 |
| Full snapshot and canonical group spelling (#5, #8) | 3, 4, 15 |
| Per-type/per-song starts; stable numbers; overflow at assignment | 3, 4, 11, 15 |
| Issued counts survive deletion/Undo; idempotent same-owner acceptance (#2) | 3, 11, 17 |
| Future starting counts distinct from applied batch counts (#10) | 4, 11, 13, 15 |
| Successful requests survive batch failures; retry only failed work (#1) | 8, 9, 10, 12, 13 |
| Resume/discard, quit/crash, pending-numbering revalidation (#9) | 9, 12, 13 |
| One replacement transaction, clips safe, empty success, cancellation/races | 10, 11, 13, 17 |
| Multi-select filter affects list and transcript, not saved clips | 15 |
| Exact filenames and explicit collision review/race handling (#4) | 16, 17 |
| Schema 1 read/schema 2 write; save/undo/revert/duplicate | 4, 11, 12 |
| App-wide draft conflicts and persistence errors | 5, 14 |
| Packaging/source registration and meaningful tests | Every source task, 17 |

Execution checkpoints: after Task 5, review the configuration/naming contracts; after Task 10, review helper recovery and cross-language fixtures; after Task 13, review document/undo/recovery behavior; after Task 16, review the actual user flow; Task 17 supplies completion evidence. These are review checkpoints during execution, not permission requests for each reversible code edit.

Plan review completed against every spec section, all ten original adversarial findings, and all seven implementation-plan review findings. The latter are covered by Tasks 3/11 (reservation identity), 9/10/12/13 (recovery authority), 11/13 (untouched V1 protection), 7/17 (nested imaging), 10 (JSON value comparison), 4/15 (canonical rule ownership), and 15 (visible/resettable song overrides). Execution has not started. The remaining editorial uncertainty is measured explicitly in Task 17; no live discovery-quality claim is made by this plan.
