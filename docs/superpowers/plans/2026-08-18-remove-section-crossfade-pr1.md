# Remove Section + Crossfade — PR 1 Implementation Plan (Remove + Collapse + Persist, silent)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Also invoke the relevant `pfw-*` skills before writing Swift (this repo mandates them): `pfw-observable-models`, `pfw-identified-collections`, `pfw-sharing`, `pfw-testing`, `pfw-custom-dump`. List them in your checklist.

**Goal:** Let the user delete a selected span of audio (from transcript-word selection or waveform marquee) and see the waveform/ruler/playhead **collapse** around a Logic-style crossfade **bowtie** at the seam, with the removal undoable and persisted. Audio is **not yet blended** on playback (that is PR 2); this PR is silent.

**Architecture:** A pure, immutable `EditedTimeline` value type maps source samples ↔ collapsed edited samples from a normalized list of `TimelineRemoval`. `WaveformModel` stays source-pure; `EditorModel` composes the map to render the edited waveform by calling the existing `WaveformModel.columns(in:pixelWidth:)` per visible kept segment and x-offsetting to edited positions. Removals funnel through a widened `mutateDocument` undo snapshot and persist in the existing per-file `ProjectState` sidecar.

**Tech Stack:** Swift 6, SwiftUI + AppKit (macOS), `@Observable` MV models, swift-dependencies, swift-sharing (`@Shared(.fileStorage)`), swift-identified-collections, Swift Testing, swift-custom-dump. Build/test via `make` in `QuickInterviewEditor/`.

**Spec:** `docs/superpowers/specs/2026-08-18-remove-section-crossfade-design.md` — read it before starting. The plan argues from the spec; both travel together.

## Global Constraints

- **Coordinates are SAMPLES**, never seconds, in all new model code. Name variables `sourceSample` / `editedSample`; never a bare `sample` that could mean either.
- **`EditPlan` is immutable engine input** — never mutate it. Removals live in editor/document state.
- **Slices keep SOURCE coordinates** (`startSample`/`endSample`) and are NOT rewritten by a global removal. Their edited length is derived.
- **Zero logic in views.** Every display value / decision is a computed property on the model. Views bind to model properties and call model methods only.
- **Value comparisons in tests use `expectNoDifference` / `expectDifference`**, not raw `#expect(a == b)`.
- **No `Task.sleep` in tests.** Use synchronous assertions / immediate test doubles.
- **Commit messages:** conventional prefixes (`feat:`, `test:`, `refactor:`). **Do NOT add any `Co-Authored-By` trailer.**
- **Before each commit run:** `cd QuickInterviewEditor && make format && make lint`. Before finishing a task run `make test`.
- Build/test commands (verbatim, run from `QuickInterviewEditor/`): `make test` (fastlane scan), `make lint` (swiftlint --strict), `make format` (swift-format -i), `make format-check`, `make generate` (xcodegen — run after adding new files so the `.xcodeproj` picks them up).

**IMPORTANT — new files must be registered:** this project generates its Xcode project from `project.yml` via XcodeGen. After creating any new `.swift` file, run `make generate` before `make test`, or the file will not be compiled.

---

## File Structure

**Create:**
- `QuickInterviewEditor/QuickInterviewEditor/Models/TimelineRemoval.swift` — `TimelineRemoval`, `Crossfade`, `CrossfadeCurve` value types + normalization/clamp helpers.
- `QuickInterviewEditor/QuickInterviewEditor/Models/EditedTimeline.swift` — `EditedTimeline`, `MappingBias`, `TimelineSeam`, `KeptSegment` + the source↔edited mapping.
- `QuickInterviewEditor/QuickInterviewEditor/Models/EditorDocumentState.swift` — `EditorDocumentState` (the widened undo/snapshot struct).
- `QuickInterviewEditor/QuickInterviewEditorTests/Models/TimelineRemovalTests.swift`
- `QuickInterviewEditor/QuickInterviewEditorTests/Models/EditedTimelineTests.swift`

**Modify:**
- `QuickInterviewEditor/QuickInterviewEditor/Models/ProjectState.swift` — add lenient `timelineRemovals` section.
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` — widen undo to `EditorDocumentState`, add `mutateDocument`, `timelineRemovals`, `editedTimeline`, `removeSelectedSectionTapped()`, persistence wiring, edited-waveform adapter methods.
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorView.swift` — bind the bowtie/removed-seam overlay + wire the ⌫ Delete key to `removeSelectedSectionTapped()`.
- `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/WaveformLaneView.swift` — add a `seams` overlay input for bowtie rendering (additive, keeps existing `auditionOverlay`).
- Test files: `QuickInterviewEditorTests/Views/Pages/Editor/EditorTests.swift` (+ a new `EditorRemovalTests.swift`), `QuickInterviewEditorTests/State/ProjectStorePersistenceTests.swift`.

---

## Task 1: `Crossfade` + `TimelineRemoval` value types

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Models/TimelineRemoval.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Models/TimelineRemovalTests.swift`

**Interfaces:**
- Produces:
  - `enum CrossfadeCurve: String, Equatable, Codable, Sendable { case equalPower, linear }`
  - `struct Crossfade: Equatable, Codable, Sendable { var lengthSamples: Int; var curve: CrossfadeCurve }`
  - `struct TimelineRemoval: Identifiable, Equatable, Codable, Sendable { var id: UUID; var removedRange: Range<Int> /*source*/; var crossfade: Crossfade }`
  - `enum TimelineRemovals` namespace with `static func normalize(_ removals: [TimelineRemoval]) -> [TimelineRemoval]?` (returns `nil` if any two overlap; otherwise sorted-by-lowerBound copy). Empty input → `[]`.

- [ ] **Step 1: Write the failing test**

```swift
import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct TimelineRemovalTests {
  private func removal(_ lower: Int, _ upper: Int, length: Int = 480, id: UInt = 1)
    -> TimelineRemoval
  {
    TimelineRemoval(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02u", id))")!,
      removedRange: lower..<upper,
      crossfade: Crossfade(lengthSamples: length, curve: .equalPower))
  }

  @Test func normalizeSortsByLowerBound() {
    let out = TimelineRemovals.normalize([removal(80, 90, id: 2), removal(10, 20, id: 1)])
    expectNoDifference(out?.map(\.removedRange), [10..<20, 80..<90])
  }

  @Test func normalizeRejectsOverlap() {
    let out = TimelineRemovals.normalize([removal(10, 30, id: 1), removal(20, 40, id: 2)])
    #expect(out == nil)
  }

  @Test func normalizeAllowsAbutting() {
    let out = TimelineRemovals.normalize([removal(10, 20, id: 1), removal(20, 30, id: 2)])
    expectNoDifference(out?.map(\.removedRange), [10..<20, 20..<30])
  }

  @Test func normalizeEmptyIsEmpty() {
    expectNoDifference(TimelineRemovals.normalize([]), [])
  }
}
```

- [ ] **Step 2: Run test to verify it fails** — Run: `cd QuickInterviewEditor && make generate && make test` (after creating the empty source file in Step 3, re-run). Expected: compile failure / FAIL (types not defined).

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

enum CrossfadeCurve: String, Equatable, Codable, Sendable {
  case equalPower
  case linear
}

struct Crossfade: Equatable, Codable, Sendable {
  var lengthSamples: Int
  var curve: CrossfadeCurve

  init(lengthSamples: Int, curve: CrossfadeCurve = .equalPower) {
    self.lengthSamples = max(0, lengthSamples)
    self.curve = curve
  }
}

struct TimelineRemoval: Identifiable, Equatable, Codable, Sendable {
  var id: UUID
  var removedRange: Range<Int>  // SOURCE samples [a, b)
  var crossfade: Crossfade
}

enum TimelineRemovals {
  /// Returns removals sorted by `removedRange.lowerBound`, or `nil` if any two overlap.
  /// Abutting ranges (a.upper == b.lower) are allowed.
  static func normalize(_ removals: [TimelineRemoval]) -> [TimelineRemoval]? {
    let sorted = removals.sorted { $0.removedRange.lowerBound < $1.removedRange.lowerBound }
    for (prev, next) in zip(sorted, sorted.dropFirst())
    where next.removedRange.lowerBound < prev.removedRange.upperBound {
      return nil
    }
    return sorted
  }
}
```

- [ ] **Step 4: Run tests to verify they pass** — Run: `cd QuickInterviewEditor && make generate && make test`. Expected: PASS.
- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Models/TimelineRemoval.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Models/TimelineRemovalTests.swift \
        QuickInterviewEditor/project.yml QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat: add TimelineRemoval + Crossfade value types with overlap normalization"
```

---

## Task 2: `EditedTimeline` — source↔edited coordinate map

This is the crux of the feature. Read spec §4.1–§4.2. The edited timeline lays out **kept segments** (source ranges between removals) end to end, but each seam **overlaps by the crossfade length** `L`, so the output is shorter than "source minus removed" by `ΣL`.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Models/EditedTimeline.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Models/EditedTimelineTests.swift`

**Interfaces:**
- Consumes: `TimelineRemoval`, `TimelineRemovals.normalize` (Task 1).
- Produces:
  - `enum MappingBias { case leftEdge, rightEdge, nearest, nilInsideRemoval }`
  - `struct KeptSegment: Equatable { var source: Range<Int>; var editedStart: Int }`
  - `struct TimelineSeam: Equatable, Identifiable { var id: UUID; var sourceCut: Int /*== removal.lowerBound a*/; var crossfadeLength: Int; var editedCenter: Int }`
  - `struct EditedTimeline: Equatable`:
    - `init(sourceDurationSamples: Int, removals: [TimelineRemoval])` — normalizes + clamps each crossfade to available handle; if `normalize` returns nil, falls back to `removals: []` and sets `isValid = false` (callers validate before constructing in practice).
    - `let sourceDurationSamples: Int`
    - `let removals: [TimelineRemoval]` (normalized, clamped)
    - `let keptSegments: [KeptSegment]`
    - `let seams: [TimelineSeam]`
    - `var editedDurationSamples: Int`
    - `func sourceToEdited(_ sourceSample: Int, bias: MappingBias = .nilInsideRemoval) -> Int?`
    - `func editedToSource(_ editedSample: Int) -> Int`
    - `func sourceRanges(forEdited edited: Range<Int>) -> [Range<Int>]`
    - `func seam(containingEdited editedSample: Int) -> TimelineSeam?`

**Model semantics (pin these with the test vectors below):**
- Clamp per removal: `effectiveL = min(requestedL, a - prevKeptLower, nextKeptUpper - b)`, `>= 0`.
- Kept segments: `K0 = [0, a0)`, `Ki = [b_{i-1}, a_i)`, ... `Kn = [b_{n-1}, sourceDuration)`. A zero-length kept segment (adjacent removals with a>b collapse) is allowed but contributes 0.
- `editedStart(K0) = 0`; `editedStart(K_{j}) = editedStart(K_{j-1}) + |K_{j-1}| - L_{j-1}`.
- `editedDuration = Σ|Kj| - ΣL`.
- `sourceToEdited(s)`: find the kept segment containing `s`; return `editedStart(K) + (s - K.source.lowerBound)`. If `s` is inside a removed range, apply bias: `.leftEdge` → edited position of `a` from the left segment's end; `.rightEdge` → edited position of `b` from the right segment's start; `.nearest` → whichever of those is closer in source; `.nilInsideRemoval` → `nil`.
- `editedToSource(e)`: find the kept segment whose edited span contains `e`; overlap zones (first `L` edited samples of a right segment) resolve to the **right** (post-cut) source sample. Clamp out-of-range `e` to `[0, editedDuration]`.
- `seam(containingEdited:)`: seam i occupies edited `[editedStart(K_{i+1}), editedStart(K_{i+1}) + L_i)`; `editedCenter = editedStart(K_{i+1})`.

- [ ] **Step 1: Write the failing tests** (concrete vectors — source 100, remove [40,60) length 10)

```swift
import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct EditedTimelineTests {
  private func removal(_ lower: Int, _ upper: Int, length: Int, id: UInt = 1) -> TimelineRemoval {
    TimelineRemoval(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02u", id))")!,
      removedRange: lower..<upper,
      crossfade: Crossfade(lengthSamples: length, curve: .equalPower))
  }

  @Test func emptyTimelineIsIdentity() {
    let t = EditedTimeline(sourceDurationSamples: 100, removals: [])
    expectNoDifference(t.editedDurationSamples, 100)
    expectNoDifference(t.sourceToEdited(37), 37)
    expectNoDifference(t.editedToSource(37), 37)
  }

  @Test func singleRemovalCollapsesWithCrossfadeOverlap() {
    // Remove [40,60), L=10. Kept K0=[0,40) K1=[60,100). editedDur = 40 + 40 - 10 = 70.
    let t = EditedTimeline(sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    expectNoDifference(t.editedDurationSamples, 70)
    expectNoDifference(t.sourceToEdited(30), 30)          // left segment, before overlap
    expectNoDifference(t.sourceToEdited(60), 30)          // right segment start sits at overlap start
    expectNoDifference(t.sourceToEdited(70), 40)          // 10 into right segment
    expectNoDifference(t.sourceToEdited(100), 70)         // right segment end == editedDuration
    expectNoDifference(t.sourceToEdited(50), nil)         // inside removed range
    expectNoDifference(t.sourceToEdited(50, bias: .leftEdge), 40)   // edited pos of a=40
    expectNoDifference(t.sourceToEdited(50, bias: .rightEdge), 30)  // edited pos of b=60
  }

  @Test func editedToSourceResolvesOverlapToRightSide() {
    let t = EditedTimeline(sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    expectNoDifference(t.editedToSource(35), 65)  // inside overlap → right (post-cut) source
    expectNoDifference(t.editedToSource(20), 20)  // pure left segment
    expectNoDifference(t.editedToSource(45), 75)  // right segment past overlap
  }

  @Test func seamLookup() {
    let t = EditedTimeline(sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    let seam = t.seam(containingEdited: 33)
    expectNoDifference(seam?.sourceCut, 40)
    expectNoDifference(seam?.crossfadeLength, 10)
    expectNoDifference(seam?.editedCenter, 30)
    #expect(t.seam(containingEdited: 5) == nil)
  }

  @Test func crossfadeClampsToAvailableHandle() {
    // Remove [5,95) length 20 but only 5 samples of handle on the left → clamp to 5.
    let t = EditedTimeline(sourceDurationSamples: 100, removals: [removal(5, 95, length: 20)])
    expectNoDifference(t.seams.first?.crossfadeLength, 5)
    expectNoDifference(t.editedDurationSamples, 5)  // K0=[0,5)=5, K1=[95,100)=5, minus L=5 → 5
  }

  @Test func sourceRangesForEditedSpansSeam() {
    let t = EditedTimeline(sourceDurationSamples: 100, removals: [removal(40, 60, length: 10)])
    // Edited [25,45) crosses the seam at edited 30..40.
    expectNoDifference(t.sourceRanges(forEdited: 25..<45), [25..<40, 60..<75])
  }
}
```

- [ ] **Step 2: Run to verify failure** — `cd QuickInterviewEditor && make generate && make test`. Expected: FAIL (type not defined).
- [ ] **Step 3: Implement `EditedTimeline`** to satisfy the vectors. Build `keptSegments` with clamped `L`, precompute `editedStart`, and implement the four query methods per the semantics above. Keep it pure (no imports beyond `Foundation`). Cache nothing across instances; the struct is cheap and rebuilt on change.

Guidance for the implementer (write the real code; this is the algorithm, not a placeholder):
  - Normalize via `TimelineRemovals.normalize`; if `nil`, treat as no removals (defensive — callers reject overlaps first).
  - Compute `keptSegments` boundaries from sorted removals; clamp each removal's `crossfade.lengthSamples` to `min(L, leftKeptLen, rightKeptLen)`.
  - `sourceToEdited`: binary or linear scan of `keptSegments` (n is tiny). Inside-removal handling per bias.
  - `sourceRanges(forEdited:)`: walk kept segments; for each, intersect its edited span with the query, translate back to source; concatenate. A query overlapping a seam yields ≥2 ranges.

- [ ] **Step 4: Run to verify pass** — `cd QuickInterviewEditor && make test`. Expected: PASS.
- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Models/EditedTimeline.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Models/EditedTimelineTests.swift \
        QuickInterviewEditor/project.yml QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat: add EditedTimeline source<->edited coordinate map with crossfade overlap"
```

---

## Task 3: Persist `timelineRemovals` in `ProjectState`

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Models/ProjectState.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/State/ProjectStorePersistenceTests.swift`

**Interfaces:**
- Produces: `ProjectState.timelineRemovals: IdentifiedArrayOf<TimelineRemoval>` (defaults `[]`, lenient-decoded like `cutSuggestions`).

- [ ] **Step 1: Write the failing test** (append to `ProjectStorePersistenceTests`)

```swift
@Test func roundTripsTimelineRemovals() throws {
  let fingerprint = "fp-removals"
  let url = ProjectState.sidecarURL(fingerprint: fingerprint)
  let seeded = ProjectState(timelineRemovals: [
    TimelineRemoval(
      id: Fixtures.uuid(7), removedRange: 1000..<2000,
      crossfade: Crossfade(lengthSamples: 480, curve: .equalPower))
  ])
  let seededData = try JSONEncoder().encode(seeded)
  let fileSystem = LockIsolated<[URL: Data]>([url: seededData])

  withDependencies {
    $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
  } operation: {
    @Shared(.projectState(fingerprint: fingerprint)) var state = ProjectState()
    expectNoDifference(state.timelineRemovals, seeded.timelineRemovals)
  }
}

@Test func decodesLegacySidecarWithoutRemovalsSection() throws {
  // A sidecar written before this feature has no "timelineRemovals" key; must decode to [].
  let json = Data(#"{"cutSuggestions":[],"speakerDisplayNames":{}}"#.utf8)
  let state = try JSONDecoder().decode(ProjectState.self, from: json)
  expectNoDifference(state.timelineRemovals, [])
}
```

- [ ] **Step 2: Run to verify failure** — `cd QuickInterviewEditor && make test`. Expected: FAIL (no `timelineRemovals`).
- [ ] **Step 3: Add the section to `ProjectState`.** Add the stored property, the init parameter (default `[]`), the `CodingKeys` case, and the lenient `decodeIfPresent` line — mirroring `cutSuggestions` exactly:

```swift
// stored property (near cutSuggestions)
var timelineRemovals: IdentifiedArrayOf<TimelineRemoval>

// init parameter (default [])
timelineRemovals: IdentifiedArrayOf<TimelineRemoval> = [],
// ...assignment...
self.timelineRemovals = timelineRemovals

// CodingKeys
case cutSuggestions, speakerCountOverride, speakerDisplayNames, timelineRemovals

// in init(from:)
timelineRemovals: try container.decodeIfPresent(
  IdentifiedArrayOf<TimelineRemoval>.self, forKey: .timelineRemovals) ?? [],
```

- [ ] **Step 4: Run to verify pass** — `cd QuickInterviewEditor && make test`. Expected: PASS.
- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Models/ProjectState.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/State/ProjectStorePersistenceTests.swift
git commit -m "feat: persist timelineRemovals in the ProjectState sidecar (lenient decode)"
```

---

## Task 4: Widen undo to `EditorDocumentState` + `mutateDocument`

Widen the undo snapshot so slices and removals move together, keeping `mutateSlices` working via delegation.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Models/EditorDocumentState.swift`
- Modify: `EditorModel.swift` (`sliceUndo` type, `mutateSlices`, add `mutateDocument`, `timelineRemovals`, `undoTapped`/`redoTapped`)
- Test: `QuickInterviewEditorTests/Views/Pages/Editor/EditorTests.swift`

**Interfaces:**
- Produces:
  - `struct EditorDocumentState: Equatable { var slices: IdentifiedArrayOf<Slice>; var timelineRemovals: IdentifiedArrayOf<TimelineRemoval> }`
  - `EditorModel.timelineRemovals: IdentifiedArrayOf<TimelineRemoval>`
  - `EditorModel.editedTimeline: EditedTimeline` (computed from `editPlan.source.durationSamples` + `timelineRemovals`)
  - `EditorModel.mutateDocument(_ body: (inout EditorDocumentState) -> Void)`
- Consumes: `UndoStack` (`record(before:after:)`, `undo(current:)`, `redo(current:)`), `EditedTimeline`, `Slice`.

- [ ] **Step 1: Write the failing test** (add to `EditorTests`)

```swift
@Test func removalUndoRedoRoundTrips() async {
  let model = editor()
  #expect(!model.canUndo)
  model.mutateDocument { doc in
    doc.timelineRemovals.append(
      TimelineRemoval(id: Fixtures.uuid(3), removedRange: 1000..<2000,
        crossfade: Crossfade(lengthSamples: 480, curve: .equalPower)))
  }
  expectNoDifference(model.timelineRemovals.count, 1)
  #expect(model.canUndo)

  await model.undoTapped()
  expectNoDifference(model.timelineRemovals, [])

  await model.redoTapped()
  expectNoDifference(model.timelineRemovals.count, 1)
}
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL (no `mutateDocument`/`timelineRemovals`).
- [ ] **Step 3: Implement.**
  - New file `EditorDocumentState.swift` with the struct above.
  - In `EditorModel`: replace `var sliceUndo = UndoStack<IdentifiedArrayOf<Slice>>()` with `var documentUndo = UndoStack<EditorDocumentState>()`; add `var timelineRemovals: IdentifiedArrayOf<TimelineRemoval> = []`.
  - Add computed:
    ```swift
    var editedTimeline: EditedTimeline {
      EditedTimeline(
        sourceDurationSamples: editPlan.source.durationSamples,
        removals: Array(timelineRemovals))
    }
    private var documentState: EditorDocumentState {
      EditorDocumentState(slices: slices, timelineRemovals: timelineRemovals)
    }
    ```
  - Add the funnel and re-point `mutateSlices`:
    ```swift
    func mutateDocument(_ body: (inout EditorDocumentState) -> Void) {
      let old = documentState
      var new = old
      body(&new)
      slices = new.slices
      timelineRemovals = new.timelineRemovals
      documentUndo.record(before: old, after: new)
      persistTimelineRemovals()
    }
    func mutateSlices(_ body: (inout IdentifiedArrayOf<Slice>) -> Void) {
      mutateDocument { doc in body(&doc.slices) }
    }
    ```
  - Update `undoTapped`/`redoTapped` to restore both fields from `EditorDocumentState`:
    ```swift
    func undoTapped() async {
      guard !hasUncommittedSliceEdit,
            let restored = documentUndo.undo(current: documentState) else { return }
      slices = restored.slices
      timelineRemovals = restored.timelineRemovals
      persistTimelineRemovals()
      await reconcilePlayback()
    }
    // redoTapped mirrors this with documentUndo.redo(current:)
    ```
  - Update any direct `sliceUndo.undo`/`.record` references (tests read `model.sliceUndo.undo.count` — see Step 5 note) and `canUndo`/`canRedo` if they forward to `sliceUndo`; point them at `documentUndo`.
  - Add `persistTimelineRemovals()` stub for now (real body in Task 5): `private func persistTimelineRemovals() {}`.

- [ ] **Step 4: Fix existing tests that referenced `sliceUndo`.** Search tests for `sliceUndo` (e.g. `EditorSliceCommitTests.swift` reads `model.sliceUndo.undo.count`) and rename to `documentUndo`. Run `cd QuickInterviewEditor && make test`. Expected: PASS (all existing slice undo tests still green).
- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add -A QuickInterviewEditor/QuickInterviewEditor/Models/EditorDocumentState.swift \
        QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests QuickInterviewEditor/project.yml \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "refactor: widen undo to EditorDocumentState via mutateDocument funnel"
```

---

## Task 5: Seed + write-through `timelineRemovals` to the sidecar

**Files:**
- Modify: `EditorModel.swift` (add `@Shared projectState`, seed in init, real `persistTimelineRemovals`)
- Test: new `QuickInterviewEditorTests/Views/Pages/Editor/EditorRemovalTests.swift`

**Interfaces:**
- Consumes: `@Shared(.projectState(fingerprint:))` (from `State/ProjectStore.swift`), `ProjectState.timelineRemovals` (Task 3).

- [ ] **Step 1: Write the failing test**

```swift
import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
@_spi(Internals) import Sharing
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorRemovalTests {
  private func editor(fingerprint: String) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL,
      editPlan: Fixtures.editPlan(), sourceFingerprint: fingerprint)
  }

  @Test func removalWritesThroughToSidecar() {
    let fingerprint = "fp-writethrough"
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: fingerprint)
      model.mutateDocument { doc in
        doc.timelineRemovals.append(
          TimelineRemoval(id: Fixtures.uuid(1), removedRange: 100..<200,
            crossfade: Crossfade(lengthSamples: 48, curve: .equalPower)))
      }
      @Shared(.projectState(fingerprint: fingerprint)) var persisted = ProjectState()
      expectNoDifference(persisted.timelineRemovals.count, 1)
    }
  }

  @Test func seedsTimelineRemovalsFromSidecar() {
    let fingerprint = "fp-seed"
    let url = ProjectState.sidecarURL(fingerprint: fingerprint)
    let seeded = ProjectState(timelineRemovals: [
      TimelineRemoval(id: Fixtures.uuid(2), removedRange: 300..<400,
        crossfade: Crossfade(lengthSamples: 48, curve: .equalPower))])
    let fileSystem = LockIsolated<[URL: Data]>([url: try! JSONEncoder().encode(seeded)])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      let model = editor(fingerprint: fingerprint)
      expectNoDifference(model.timelineRemovals, seeded.timelineRemovals)
    }
  }
}
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL.
- [ ] **Step 3: Implement.** In `EditorModel`:
  - Add dependency-adjacent shared state: `@ObservationIgnored @Shared var projectState: ProjectState`.
  - In `init`, after computing `fingerprint` and before `super.init()`: `_projectState = Shared(.projectState(fingerprint: fingerprint))`. After `super.init()`: `self.timelineRemovals = projectState.timelineRemovals`.
  - Real body: `private func persistTimelineRemovals() { $projectState.withLock { $0.timelineRemovals = timelineRemovals } }`.
  - NOTE: `CutSuggestionsPageModel` also holds a `@Shared` to the same fingerprint — same fileStorage URL keeps them consistent. Do not remove that one.

- [ ] **Step 4: Run to verify pass** — `cd QuickInterviewEditor && make test`. Expected: PASS. Also confirm existing `EditorTests`/transport tests still pass.
- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add -A QuickInterviewEditor
git commit -m "feat: seed and persist timelineRemovals via the ProjectState sidecar"
```

---

## Task 6: `removeSelectedSectionTapped()` — build a removal from the current selection

**Files:**
- Modify: `EditorModel.swift`
- Test: `EditorRemovalTests.swift`

**Interfaces:**
- Consumes: `transcript.selectedSampleRange: Range<Int>?`, `transcript.clearSelectionTapped()`, the waveform marquee range (see note), `editedTimeline`, `mutateDocument`.
- Produces:
  - `EditorModel.removeSelectedSectionTapped() async`
  - `EditorModel.defaultCrossfadeSamples: Int` (computed: `Int(0.020 * Double(editPlan.source.sampleRate))`, i.e. 20 ms)
  - `EditorModel.canRemoveSelectedSection: Bool` (drives ⌫ enablement / menu)

**Selection source:** the current selected **source** range is `transcript.selectedSampleRange` (the marquee already mirrors onto the transcript selection per the existing `updateMarqueeSelection()` path, so one accessor covers both C-decision inputs). If in future a marquee-only range exists, prefer an explicit `selectedSourceRange` computed on `EditorModel` that returns `transcript.selectedSampleRange`.

**Cross-seam rejection (spec §4.7):** reject if the selected source range spans an existing seam — i.e. if any existing `removedRange` intersects the selection, or the selection is not fully inside one kept segment of the *current* `editedTimeline`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func removeSelectedSectionCreatesRemovalWithDefaultCrossfade() async {
  let model = editor(fingerprint: "fp-remove")
  // Select a source span via the transcript (Fixtures.editPlan has words; pick two).
  model.transcript.selectWords(
    anchorID: model.editPlan.words[1].id, focusID: model.editPlan.words[2].id)
  #expect(model.canRemoveSelectedSection)
  await model.removeSelectedSectionTapped()

  expectNoDifference(model.timelineRemovals.count, 1)
  #expect(model.timelineRemovals.first?.crossfade.curve == .equalPower)
  #expect(model.transcript.hasSelection == false)  // selection cleared
}

@Test func removeRejectsSelectionCrossingExistingSeam() async {
  let model = editor(fingerprint: "fp-reject")
  model.mutateDocument { doc in
    doc.timelineRemovals.append(
      TimelineRemoval(id: Fixtures.uuid(9), removedRange: 500..<600,
        crossfade: Crossfade(lengthSamples: 48, curve: .equalPower)))
  }
  // A selection whose source range straddles 500..<600 must be rejected.
  // (Construct via a helper that sets transcript selection to a known sample range,
  //  or assert canRemoveSelectedSection == false for that selection.)
  // ... set selection straddling the seam ...
  #expect(model.canRemoveSelectedSection == false)
}
```

Note: if setting an exact straddling selection through the transcript is awkward with the fixture, add a small `@_spi`-style test seam or assert on a pure helper `EditorModel.canRemove(sourceRange:)` that Task 6 also exposes and unit-test that directly with an explicit range.

- [ ] **Step 2: Run to verify failure** — Expected: FAIL.
- [ ] **Step 3: Implement.**

```swift
var defaultCrossfadeSamples: Int { Int(0.020 * Double(editPlan.source.sampleRate)) }

private var selectedSourceRange: Range<Int>? { transcript.selectedSampleRange }

func canRemove(sourceRange range: Range<Int>) -> Bool {
  guard range.lowerBound < range.upperBound else { return false }
  // Reject if it intersects an existing removal (cross-seam) — spec §4.7.
  return !timelineRemovals.contains { $0.removedRange.overlaps(range) }
}

var canRemoveSelectedSection: Bool {
  guard let range = selectedSourceRange else { return false }
  return canRemove(sourceRange: range)
}

func removeSelectedSectionTapped() async {
  guard let range = selectedSourceRange, canRemove(sourceRange: range) else { return }
  let removal = TimelineRemoval(
    id: uuid(),  // use the repo's uuid dependency if present; else UUID()
    removedRange: range,
    crossfade: Crossfade(lengthSamples: defaultCrossfadeSamples, curve: .equalPower))
  mutateDocument { doc in
    doc.timelineRemovals.append(removal)
    doc.timelineRemovals = IdentifiedArray(
      uniqueElements: TimelineRemovals.normalize(Array(doc.timelineRemovals)) ?? Array(doc.timelineRemovals))
  }
  transcript.clearSelectionTapped()
  await reconcilePlayback()
}
```

Check whether `EditorModel` already has a `@Dependency(\.uuid)`; if not, use `UUID()` (tests pass explicit ids only for constructed removals, and this action's id is not asserted).

- [ ] **Step 4: Run to verify pass** — `cd QuickInterviewEditor && make test`. Expected: PASS.
- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add -A QuickInterviewEditor
git commit -m "feat: removeSelectedSectionTapped builds a TimelineRemoval from the selection"
```

---

## Task 7: Collapsed edited-coordinate waveform rendering + bowtie overlay

Render the waveform, ruler, and playhead in **edited** coordinates by composing the existing source-pure `WaveformModel`. Pure mapping is unit-tested; pixel output is manually verified (spec §5, §6 PR1).

**Files:**
- Modify: `EditorModel.swift` (edited-waveform adapter methods + seam overlay data), `WaveformLaneView.swift` (additive `seams` overlay input), `EditorView.swift` (pass seams + wire ⌫).
- Test: `EditorRemovalTests.swift` (mapping-level assertions).

**Interfaces:**
- Produces on `EditorModel`:
  - `struct SeamOverlay: Equatable, Identifiable { var id: UUID; var editedCenterSample: Int; var crossfadeLength: Int }`
  - `var seamOverlays: [SeamOverlay]` — derived from `editedTimeline.seams`.
  - `func editedWaveformColumns() -> [WaveformColumn]` — for the visible edited window, concatenate `waveform.columns(in: keptSourceSubRange, pixelWidth: segmentPixelWidth)` per visible kept segment, x-offset to the segment's edited x. (Uses existing `WaveformModel.columns(in:pixelWidth:)`, line 104, and `sampleToX`.)
- Consumes: `WaveformModel.columns(in:pixelWidth:)`, `WaveformModel.span(for:)`, `WaveformModel.sampleToX`, `EditedTimeline`.

**Rendering approach (spec §4.1):** The waveform axis becomes the edited axis. Concretely: `WaveformModel` keeps rendering source, but the visible window is expressed in edited samples and split into per-kept-segment source sub-ranges via `editedTimeline.sourceRanges(forEdited:)`. Each sub-range is drawn with `columns(in:pixelWidth:)` and offset. The **bowtie** for each seam is an overlay at `sampleToX(editedCenter)` spanning `crossfadeLength` edited samples, drawn as two crossing curves (an X) — a new small SwiftUI shape in `WaveformLaneView`.

- [ ] **Step 1: Write the failing test** (mapping-level, deterministic)

```swift
@Test func seamOverlaysDerivedFromTimeline() {
  let model = editor(fingerprint: "fp-seams")
  model.mutateDocument { doc in
    doc.timelineRemovals.append(
      TimelineRemoval(id: Fixtures.uuid(4), removedRange: 1000..<2000,
        crossfade: Crossfade(lengthSamples: 96, curve: .equalPower)))
  }
  expectNoDifference(model.seamOverlays.count, 1)
  expectNoDifference(model.seamOverlays.first?.crossfadeLength, 96)
  // editedCenter == sourceToEdited(1000) with left bias == 1000 (nothing removed before it)
  expectNoDifference(model.seamOverlays.first?.editedCenterSample, 1000)
}
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL.
- [ ] **Step 3: Implement `seamOverlays` + `editedWaveformColumns()`** on `EditorModel`, and the `WaveformLaneView` additive overlay:
  - `WaveformLaneView`: add `let seams: [WaveformSpan]` (or a small `SeamShape` model) and render each as an `.overlay` drawing the bowtie X (two `Path`s crossing within the span rect). Keep the existing `auditionOverlay` param and all current inputs unchanged (additive, default `[]` so existing call sites compile).
  - `EditorView`: compute the seam spans as `model.seamOverlays.compactMap { model.waveform.span(for: $0.editedCenterSample ..< ($0.editedCenterSample + $0.crossfadeLength)) }` (or center the span) and pass them in; wire the ⌫ key to `model.removeSelectedSectionTapped()` via a `.keyboardShortcut(.delete, modifiers: [])` command / `.onDeleteCommand` on the editor surface, gated by `model.canRemoveSelectedSection`.
  - Wire the edited axis: where `EditorView` currently feeds the waveform, switch the visible-window source to edited coordinates. If the full edited-axis switch is too large for one step, land the seam overlay + delete wiring first (visible, correct seams on top of the existing source waveform), then the column remapping — but both must be in this PR.

- [ ] **Step 4: Verify.** `cd QuickInterviewEditor && make test` (mapping tests pass). Then **manual verification** (spec §5): run the app (`make generate` then run the `QuickInterviewEditor` scheme in Xcode, or `open QuickInterviewEditor/QuickInterviewEditor.xcodeproj`), import a fixture clip, select a span, press ⌫, and confirm: the waveform collapses around the seam, a bowtie X appears, the ruler/playhead read edited time, undo (⌘Z) restores, and reopening the file keeps the removal. Capture a before/after screenshot for the PR.
- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format && make lint
git add -A QuickInterviewEditor
git commit -m "feat: collapsed edited-coordinate waveform + bowtie seam overlay + delete-to-remove"
```

---

## Task 8: Interim-limitation guard + PR wrap-up

Playback is still source-contiguous this PR (spec §6 PR1 interim limitation). Make that non-confusing and document it.

**Files:**
- Modify: `EditorModel.swift` (a computed `var playbackReflectsRemovals: Bool { false }` or a small banner string the view can show), `EditorView.swift` (optional subtle note when removals exist), the PR description.

- [ ] **Step 1:** Add a model computed property for the interim note, e.g. `var removalPlaybackNote: String? { timelineRemovals.isEmpty ? nil : "Playback preview does not yet blend cuts (coming next)." }`. View binds to it (no hardcoded string in the view).
- [ ] **Step 2:** Run `cd QuickInterviewEditor && make test && make format-check && make lint`. Expected: all green.
- [ ] **Step 3:** Update `docs/superpowers/specs/2026-08-18-remove-section-crossfade-design.md` status note if needed (PR1 complete).
- [ ] **Step 4: Commit + open PR**

```bash
cd QuickInterviewEditor && make format && make lint && make test
git add -A
git commit -m "feat: interim playback note while cut-blending is pending (PR1 wrap-up)"
```

Then open the PR against `main` with a body that: summarizes the 4-PR feature, states this PR is **silent** (interim limitation from spec §6 PR1), links the spec, and attaches the before/after screenshot. After creating the PR, run `/fix-review` per the repo workflow (do not trigger a re-review if the confidence score is ≥ 4/5).

---

## Self-Review (completed by plan author)

**Spec coverage (§ → task):** §4.1 coordinate model → Task 2, Task 7. §4.2 data model + normalization + clamp → Task 1, Task 2. §4.3 undo widening + `mutateDocument` → Task 4. §4.6 delete gesture (transcript + marquee), ⌫ → Task 6, Task 7. §4.7 word-hide (existing midpoint logic — no new code needed since collapsed rendering hides removed-range words via the edited axis; verify in Task 7 manual check) + cross-seam rejection → Task 6. §4.8 persistence → Task 3, Task 5. §6 PR1 interim limitation → Task 8. Continuous audition / export / editable-seam UI / slice-local → **out of scope (PR 2–4), intentionally.**

**Gaps flagged for the executor:**
- Task 7's full edited-axis switch is the riskiest step; the plan allows landing the seam overlay + delete first, then column remapping, both within the PR. If the edited-axis remap proves larger than expected, STOP and split into a follow-up commit within the same PR rather than faking it.
- Word-hide on removal: confirm during Task 7 manual verification that words inside a removed range disappear from the transcript. If the transcript does not react to `timelineRemovals` yet, add a follow-up task (transcript reads `editedTimeline` to filter words whose midpoint is removed) — spec §4.7. This may warrant a Task 7b if non-trivial.

**Placeholder scan:** none — all code steps carry real code or a named algorithm + reference to the exact existing method.

**Type consistency:** `mutateDocument`, `documentUndo`, `EditorDocumentState`, `timelineRemovals`, `editedTimeline`, `TimelineRemoval`, `Crossfade`, `EditedTimeline`, `SeamOverlay` used consistently across tasks.
