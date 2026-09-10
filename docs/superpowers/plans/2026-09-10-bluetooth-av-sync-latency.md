# Bluetooth A/V-Sync Latency Compensation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Also required per repo CLAUDE.md:** before writing Swift in any task, invoke the relevant `pfw-*` skills. Mapping for this plan: `pfw-dependencies` (Task 3), `pfw-sharing` (Task 2), `pfw-observable-models` + `pfw-modern-swiftui` (Task 6), `pfw-testing` + `pfw-custom-dump` (all test steps: use `expectNoDifference`, not `#expect(a == b)`).

**Goal:** Delay the visual playhead to match when audio actually reaches the user's ears over Bluetooth, so the cursor stops running ahead of the sound.

**Architecture:** Read an automatic output-latency estimate (`AVAudioNode.outputPresentationLatency`) plus a signed per-device manual offset (keyed by CoreAudio device UID, persisted). Subtract the effective delay (in native frames, rate-scaled) from the player node's render-frame count *before* mapping to a plan/edited sample, producing a `presentationSample` distinct from the raw `renderSample`. The playhead follow, paused cursor, and "what I just heard" marks consume `presentationSample`; explicit clip boundaries are untouched.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation (`AVAudioEngine`/`AVAudioPlayerNode`/`AVAudioUnitTimePitch`), CoreAudio/AudioToolbox (HAL device queries), Point-Free `swift-dependencies` + `swift-sharing`, Swift Testing + `swift-custom-dump`.

**Spec:** `docs/superpowers/specs/2026-09-10-bluetooth-av-sync-latency-design.md`

## Global Constraints

- **MV architecture, zero logic in views.** All state/behavior on the `@Observable` model; view only lays out and binds. Model methods named for the user action.
- **Every side-effecting boundary is a `Sendable` dependency client** with `liveValue`/`testValue`, injected via `@Dependency`, overridden in tests with `withDependencies`.
- **Value comparisons in tests use `expectNoDifference` / `expectDifference`** from `swift-custom-dump`, never raw `#expect(a == b)`. Test names camelCase, no underscores. **No `Task.sleep` in tests.**
- **`@Shared` in tests** is declared locally inside each test with an initial value; never class-level, never `$shared.withLock` in tests.
- **Effective delay floors at 0** (`max(0, automatic + manual)`); the manual term may be negative. Reject non-finite manual values.
- **Persist device identity by UID only** (`kAudioDevicePropertyDeviceUID`), never the numeric `AudioDeviceID`, never the name.
- Run `make test-fast` (in `QuickInterviewEditor/`) for the dev loop; `make format-check` + `make lint` before considering a task done. Do NOT run `xcodegen generate` between test runs.

---

### Task 1: Pure latency math

Pure, dependency-free functions for the two calculations, so they are fully unit-testable with no audio/device. This is the correctness core the untested live actor (Task 5) leans on.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Core/OutputLatencyMath.swift`
- Test: `QuickInterviewEditor/QuickInterviewEditorTests/Core/OutputLatencyMathTests.swift`

**Interfaces:**
- Produces:
  - `enum OutputLatencyMath` with:
    - `static func effectiveSeconds(automatic: Double, manual: Double) -> Double`
    - `static func presentationFrames(renderFrames: Int, effectiveSeconds: Double, nativeSampleRate: Double, rate: Double) -> Int`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import CustomDump

@testable import PlayolaInterviewEditor

struct OutputLatencyMathTests {

  @Test func effectiveSecondsAddsAutomaticAndManual() {
    expectNoDifference(OutputLatencyMath.effectiveSeconds(automatic: 0.15, manual: 0.05), 0.20)
  }

  @Test func effectiveSecondsAllowsNegativeManualToReduceTotal() {
    expectNoDifference(OutputLatencyMath.effectiveSeconds(automatic: 0.15, manual: -0.05), 0.10)
  }

  @Test func effectiveSecondsFloorsAtZero() {
    expectNoDifference(OutputLatencyMath.effectiveSeconds(automatic: 0.02, manual: -0.10), 0.0)
  }

  @Test func effectiveSecondsTreatsNonFiniteManualAsZero() {
    expectNoDifference(OutputLatencyMath.effectiveSeconds(automatic: 0.15, manual: .nan), 0.15)
    expectNoDifference(OutputLatencyMath.effectiveSeconds(automatic: 0.15, manual: .infinity), 0.15)
  }

  @Test func presentationFramesSubtractsRateScaledDelay() {
    // 0.2 s * 48000 * 2.0 = 19_200 input frames backed off.
    expectNoDifference(
      OutputLatencyMath.presentationFrames(
        renderFrames: 100_000, effectiveSeconds: 0.2, nativeSampleRate: 48_000, rate: 2.0),
      80_800)
  }

  @Test func presentationFramesScalesWithRateAtOneX() {
    expectNoDifference(
      OutputLatencyMath.presentationFrames(
        renderFrames: 100_000, effectiveSeconds: 0.2, nativeSampleRate: 48_000, rate: 1.0),
      90_400)
  }

  @Test func presentationFramesClampsToZeroAtPlaybackStart() {
    expectNoDifference(
      OutputLatencyMath.presentationFrames(
        renderFrames: 1_000, effectiveSeconds: 0.2, nativeSampleRate: 48_000, rate: 1.0),
      0)
  }

  @Test func presentationFramesReturnsRenderFramesWhenNoDelay() {
    expectNoDifference(
      OutputLatencyMath.presentationFrames(
        renderFrames: 5_000, effectiveSeconds: 0.0, nativeSampleRate: 48_000, rate: 1.0),
      5_000)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/OutputLatencyMathTests`
Expected: FAIL — `OutputLatencyMath` not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Pure math for compensating the visual playhead for output latency. Isolated from the audio
/// graph so it is fully unit-testable; the live player actor (untested, hardware-bound) calls
/// these and adds only the frame reads.
enum OutputLatencyMath {

  /// The delay to back the playhead off by, in seconds: the automatic estimate plus a signed
  /// manual correction, floored at 0. A non-finite manual value (corrupt defaults) is treated as 0.
  static func effectiveSeconds(automatic: Double, manual: Double) -> Double {
    let safeManual = manual.isFinite ? manual : 0
    return max(0, automatic + safeManual)
  }

  /// Converts the node's render (input-frame) count to the count representing audio the user is
  /// actually hearing. `effectiveSeconds` is a wall-clock OUTPUT delay; input frames advance at
  /// `nativeSampleRate * rate` per wall-clock second (the time-pitch rate speeds up input
  /// consumption), so the subtraction is rate-scaled. Clamped to 0 so the first `effectiveSeconds`
  /// of playback never maps below the range start.
  static func presentationFrames(
    renderFrames: Int, effectiveSeconds: Double, nativeSampleRate: Double, rate: Double
  ) -> Int {
    let offset = effectiveSeconds * nativeSampleRate * rate
    return max(0, Int((Double(renderFrames) - offset).rounded()))
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/OutputLatencyMathTests`
Expected: PASS.

- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format-check && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Core/OutputLatencyMath.swift QuickInterviewEditor/QuickInterviewEditorTests/Core/OutputLatencyMathTests.swift
git commit -m "feat: pure output-latency compensation math"
```

---

### Task 2: Shared keys for per-device offsets and estimates

The persisted signed manual offsets (per device UID) and the session-only automatic estimates the actor publishes for the Settings readout. Both are `[String: Double]` (UID → seconds).

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/State/OutputLatencyKeys.swift`
- Test: `QuickInterviewEditorTests/State/OutputLatencyKeysTests.swift`

**Interfaces:**
- Consumes: `AppDirectories.folderName` (existing, used by `ProjectState.sidecarURL`).
- Produces:
  - `@Shared(.outputLatencyOffsets)` → `[String: Double]` (persisted, fileStorage), seconds keyed by device UID.
  - `@Shared(.outputLatencyEstimates)` → `[String: Double]` (in-memory), seconds keyed by device UID.
  - `enum OutputLatencyOffsets { static func offsetSeconds(for uid: String?, in map: [String: Double]) -> Double }` — pure lookup used by the actor and Settings.

- [ ] **Step 1: Write the failing tests**

```swift
import Sharing
import Testing
import CustomDump

@testable import PlayolaInterviewEditor

struct OutputLatencyKeysTests {

  @Test func offsetLookupReturnsZeroForMissingOrNilDevice() {
    let map = ["uid-a": 0.12]
    expectNoDifference(OutputLatencyOffsets.offsetSeconds(for: nil, in: map), 0.0)
    expectNoDifference(OutputLatencyOffsets.offsetSeconds(for: "uid-b", in: map), 0.0)
  }

  @Test func offsetLookupReturnsStoredValue() {
    let map = ["uid-a": 0.12, "uid-b": -0.03]
    expectNoDifference(OutputLatencyOffsets.offsetSeconds(for: "uid-a", in: map), 0.12)
    expectNoDifference(OutputLatencyOffsets.offsetSeconds(for: "uid-b", in: map), -0.03)
  }

  @Test func offsetLookupTreatsNonFiniteStoredValueAsZero() {
    let map = ["uid-a": Double.nan]
    expectNoDifference(OutputLatencyOffsets.offsetSeconds(for: "uid-a", in: map), 0.0)
  }

  @Test func offsetsKeyRoundTripsPerDevice() {
    @Shared(.outputLatencyOffsets) var offsets = [:]
    $offsets.withLock { $0["uid-a"] = 0.2 }
    expectNoDifference(offsets["uid-a"], 0.2)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/OutputLatencyKeysTests`
Expected: FAIL — key and helper not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import Sharing

/// `@Shared` keys for output-latency compensation.
///
/// `.outputLatencyOffsets` is the user's signed per-device manual correction (seconds, keyed by
/// CoreAudio device UID), persisted as one JSON file so it survives relaunch and follows the
/// device. `.outputLatencyEstimates` is the automatic `outputPresentationLatency` the player
/// measures during playback, published in-memory for the Settings readout (session-only; there is
/// nothing to persist — it is re-measured each playback).
extension SharedKey where Self == FileStorageKey<[String: Double]>.Default {
  static var outputLatencyOffsets: Self {
    Self[.fileStorage(outputLatencyOffsetsURL), default: [:]]
  }
}

extension SharedKey where Self == InMemoryKey<[String: Double]>.Default {
  static var outputLatencyEstimates: Self {
    Self[.inMemory("outputLatencyEstimates"), default: [:]]
  }
}

/// `…/Application Support/Playola Interview Editor/PlaybackLatency/output-offsets.json`.
private let outputLatencyOffsetsURL: URL =
  URL.applicationSupportDirectory
  .appending(component: AppDirectories.folderName, directoryHint: .isDirectory)
  .appending(component: "PlaybackLatency", directoryHint: .isDirectory)
  .appending(component: "output-offsets.json", directoryHint: .notDirectory)

enum OutputLatencyOffsets {
  /// The stored signed offset (seconds) for a device UID, or 0 for a nil/absent/non-finite entry.
  /// A missing UID must never reuse another device's value.
  static func offsetSeconds(for uid: String?, in map: [String: Double]) -> Double {
    guard let uid, let value = map[uid], value.isFinite else { return 0 }
    return value
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/OutputLatencyKeysTests`
Expected: PASS.

- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format-check && make lint
git add QuickInterviewEditor/QuickInterviewEditor/State/OutputLatencyKeys.swift QuickInterviewEditor/QuickInterviewEditorTests/State/OutputLatencyKeysTests.swift
git commit -m "feat: shared keys for per-device output-latency offsets and estimates"
```

---

### Task 3: `AudioOutputClient` dependency

A `Sendable` dependency client that reports the current default output device (runtime id + persistent UID + display name) and a stream that fires when the default output device changes. The `liveValue` uses CoreAudio HAL; it is not unit-tested (hardware), matching how `AudioPlayerClient.live()` is treated. `testValue` reports unexpected reads and yields an inert stream.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Core/AudioOutputClient.swift`
- Test: `QuickInterviewEditorTests/Core/AudioOutputClientTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `struct OutputDevice: Equatable, Sendable { var id: UInt32; var uid: String; var name: String }`
  - `struct AudioOutputClient: Sendable { var current: @Sendable () -> OutputDevice?; var changes: @Sendable () -> AsyncStream<Void> }`
  - `DependencyValues.audioOutput`

- [ ] **Step 1: Write the failing test** (only the injectable contract is unit-tested; live CoreAudio is manual)

```swift
import Dependencies
import Testing
import CustomDump

@testable import PlayolaInterviewEditor

struct AudioOutputClientTests {

  @Test func testValueCurrentIsOverridable() {
    let device = OutputDevice(id: 7, uid: "uid-x", name: "Test Buds")
    withDependencies {
      $0.audioOutput = AudioOutputClient(current: { device }, changes: { AsyncStream { $0.finish() } })
    } operation: {
      @Dependency(\.audioOutput) var audioOutput
      expectNoDifference(audioOutput.current(), device)
    }
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/AudioOutputClientTests`
Expected: FAIL — `AudioOutputClient` / `OutputDevice` not defined.

- [ ] **Step 3: Write the implementation**

```swift
import AudioToolbox
import CoreAudio
import Dependencies
import Foundation
import IssueReporting

/// A CoreAudio output device, identified for persistence by `uid` (never the runtime `id`).
struct OutputDevice: Equatable, Sendable {
  var id: UInt32  // AudioDeviceID — runtime only, never persisted
  var uid: String  // kAudioDevicePropertyDeviceUID — persistent key
  var name: String  // kAudioObjectPropertyName — display
}

/// Reads the current default output device and notifies when it changes. Isolated as a dependency
/// so the player and Settings resolve device identity/latency without a real HAL in tests.
struct AudioOutputClient: Sendable {
  /// The current default output device, or nil if it can't be resolved.
  var current: @Sendable () -> OutputDevice?
  /// Fires (no payload) whenever the system default output device changes. Read `current()` after.
  var changes: @Sendable () -> AsyncStream<Void>
}

extension AudioOutputClient: DependencyKey {
  static let liveValue = AudioOutputClient(
    current: { Self.readDefaultOutputDevice() },
    changes: {
      AsyncStream { continuation in
        var address = AudioObjectPropertyAddress(
          mSelector: kAudioHardwarePropertyDefaultOutputDevice,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in continuation.yield(()) }
        let status = AudioObjectAddPropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
        if status != noErr { continuation.finish() }
        continuation.onTermination = { _ in
          AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
        }
      }
    }
  )

  private static func readDefaultOutputDevice() -> OutputDevice? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
      deviceID != 0,
      let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
      let name = stringProperty(deviceID, kAudioObjectPropertyName)
    else { return nil }
    return OutputDevice(id: deviceID, uid: uid, name: name)
  }

  private static func stringProperty(
    _ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    return value as String
  }
}

extension AudioOutputClient: TestDependencyKey {
  static let testValue = AudioOutputClient(
    current: {
      reportIssue("AudioOutputClient.current called without a test override")
      return nil
    },
    changes: { AsyncStream { $0.finish() } }
  )
  static let previewValue = AudioOutputClient(
    current: { OutputDevice(id: 0, uid: "preview", name: "Built-in Output") },
    changes: { AsyncStream { $0.finish() } })
}

extension DependencyValues {
  var audioOutput: AudioOutputClient {
    get { self[AudioOutputClient.self] }
    set { self[AudioOutputClient.self] = newValue }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/AudioOutputClientTests`
Expected: PASS.

- [ ] **Step 5: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format-check && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Core/AudioOutputClient.swift QuickInterviewEditorTests/Core/AudioOutputClientTests.swift
git commit -m "feat: AudioOutputClient dependency for default-output device identity + changes"
```

---

### Task 4: Split `PlaybackPosition` into render + presentation samples

Behavior-preserving refactor: give every position tick both a `renderSample` (raw engine position) and a `presentationSample` (latency-compensated). This task keeps them equal (no compensation yet — Task 5 wires that in) and repoints consumers to `presentationSample`, so the correctness split exists before the offset that needs it. Prevents the pause-jump the spec calls out.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Core/AudioPlayerClient.swift` — `PlaybackPosition` (line 95-99), `emitPosition` (~636), `stopTicking` broadcast (~617-621).
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Editor/EditorModel.swift` — `observePlayback` (line 1414: `position.sample` → `position.presentationSample`).
- Modify any other reader of `PlaybackPosition.sample` (grep first — see Step 1).
- Test: `QuickInterviewEditorTests/Core/AudioPlayerClientPositionTests.swift` (new) or extend the nearest existing position test suite.

**Interfaces:**
- Consumes: nothing new.
- Produces: `struct PlaybackPosition { var sessionID; var renderSample: PlaybackSample; var presentationSample: PlaybackSample; var isPlaying: Bool }`.

- [ ] **Step 1: Find every consumer of `PlaybackPosition.sample`**

Run: `cd /Users/brian/conductor/workspaces/logic-utils/brussels && grep -rn "\.sample" QuickInterviewEditor/QuickInterviewEditor QuickInterviewEditor/QuickInterviewEditorTests | grep -i "position\|playback"`
Repoint each read to `presentationSample`. Any test constructing `PlaybackPosition(...)` must pass both `renderSample:` and `presentationSample:`.

- [ ] **Step 2: Write the failing test**

```swift
import Testing
import CustomDump

@testable import PlayolaInterviewEditor

struct AudioPlaybackPositionTests {
  @Test func positionCarriesDistinctRenderAndPresentationSamples() {
    let session = PlaybackSessionID()
    let position = PlaybackPosition(
      sessionID: session,
      renderSample: .source(1_000),
      presentationSample: .source(800),
      isPlaying: true)
    expectNoDifference(position.renderSample, .source(1_000))
    expectNoDifference(position.presentationSample, .source(800))
  }
}
```

- [ ] **Step 3: Run test to verify it fails (compile error is a valid fail)**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/AudioPlaybackPositionTests`
Expected: FAIL — `PlaybackPosition` has no `renderSample`/`presentationSample`.

- [ ] **Step 4: Update `PlaybackPosition` and its producers**

Replace the struct:

```swift
struct PlaybackPosition: Sendable, Equatable {
  var sessionID: PlaybackSessionID
  /// The raw engine render position (frames actually rendered). Kept for debugging/tests and any
  /// future consumer that needs the true render point rather than the audible one.
  var renderSample: PlaybackSample
  /// The latency-compensated position representing audio reaching the user's ears. This is what the
  /// playhead, paused cursor, and transcript follow use. Equals `renderSample` when no compensation
  /// applies (0 delay). See `OutputLatencyMath`.
  var presentationSample: PlaybackSample
  var isPlaying: Bool
}
```

In `emitPosition` (both samples equal here; Task 5 makes them differ):

```swift
let framesPlayed = Int(max(0, playerTime.sampleTime))
let sample = positionSample(forFramesPlayed: framesPlayed)
broadcast(
  PlaybackPosition(
    sessionID: session, renderSample: sample, presentationSample: sample, isPlaying: true))
```

In `stopTicking`'s broadcast, pass the same zero sample to both:

```swift
let zero = positionSample(forFramesPlayed: 0)
broadcast(
  PlaybackPosition(
    sessionID: session, renderSample: zero, presentationSample: zero, isPlaying: false))
```

- [ ] **Step 5: Repoint `observePlayback`**

`EditorModel.swift:1414`: change `switch position.sample {` to `switch position.presentationSample {`.

- [ ] **Step 6: Run the full suite to verify green**

Run: `cd QuickInterviewEditor && make test-fast`
Expected: PASS (behavior unchanged; both samples equal).

- [ ] **Step 7: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format-check && make lint
git add -A
git commit -m "refactor: split PlaybackPosition into render + presentation samples"
```

---

### Task 5: Wire compensation into `LivePlayerBox`

Apply the offset inside the live actor: store the native sample rate, read `node.outputPresentationLatency` after the engine starts, resolve the current device UID, look up the manual offset, compute `presentationFrames`, and broadcast both samples. Also publish the automatic estimate for Settings, and stop playback cleanly on an output-device change. This is the live audio boundary — not unit-tested (matches the existing `live()` treatment); its arithmetic is already covered by Task 1.

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Core/AudioPlayerClient.swift` — `live()` factory (149-175), `LivePlayerBox` stored state (185-219), `play`/`playEdited` (set native rate + refresh estimate), `emitPosition` (630-638), `pause` (521-538), and a new route-change observer.

**Interfaces:**
- Consumes: `OutputLatencyMath.effectiveSeconds`/`presentationFrames` (Task 1); `OutputLatencyOffsets.offsetSeconds` + `.outputLatencyOffsets` + `.outputLatencyEstimates` (Task 2); `AudioOutputClient` + `OutputDevice` (Task 3); the render/presentation `PlaybackPosition` (Task 4).
- Produces: no new public API; `AudioPlayerClient.live()` gains internal wiring only.

- [ ] **Step 1: Inject dependency + shared state into the actor**

In `live()`, resolve the client and shared maps and pass them to the box:

```swift
static func live() -> AudioPlayerClient {
  @Dependency(\.audioOutput) var audioOutput
  @Shared(.outputLatencyOffsets) var offsets
  @Shared(.outputLatencyEstimates) var estimates
  let box = LivePlayerBox(
    audioOutput: audioOutput, offsets: $offsets, estimates: $estimates)
  // …unchanged closure wiring…
}
```

Add to `LivePlayerBox`:

```swift
private let audioOutput: AudioOutputClient
@ObservationIgnored private let offsets: Shared<[String: Double]>
@ObservationIgnored private let estimates: Shared<[String: Double]>
/// The file's native sample rate for the current playback, used to convert the latency delay
/// (wall-clock output seconds) into input frames. Set at the top of `play`/`playEdited`.
private var nativeSampleRate: Double = 44_100
/// The automatic latency estimate (seconds) read from the node after the engine starts.
private var automaticLatencySeconds: Double = 0
/// The current default output device's UID (for the manual-offset lookup), refreshed on play
/// start and on a device-change event.
private var currentDeviceUID: String?
private var routeChangeTask: Task<Void, Never>?

init(
  audioOutput: AudioOutputClient,
  offsets: Shared<[String: Double]>,
  estimates: Shared<[String: Double]>
) {
  self.audioOutput = audioOutput
  self.offsets = offsets
  self.estimates = estimates
}
```

> Note: `Shared` is imported from `Sharing`; add `import Sharing` to the file if not present.

- [ ] **Step 2: Refresh device + automatic estimate after the engine starts**

Add a helper and call it in `play` and `playEdited` immediately after `try engine.start()`:

```swift
/// Reads the current output device and the node's downstream presentation latency, caches them
/// for the offset math, and publishes the estimate for Settings. Call after `engine.start()`.
private func refreshOutputLatency() {
  let device = audioOutput.current()
  currentDeviceUID = device?.uid
  automaticLatencySeconds = max(0, node.outputPresentationLatency)
  if let uid = device?.uid {
    estimates.withLock { $0[uid] = automaticLatencySeconds }
  }
}
```

In `play`: set `nativeSampleRate = nativeRate` (already computed at line 246) right after `playRatio = ratio`, and call `refreshOutputLatency()` after `try engine.start()` (line 275).
In `playEdited`: set `nativeSampleRate = format.sampleRate` after `playRatio = ratio`, and call `refreshOutputLatency()` after `try engine.start()` (line 357).

- [ ] **Step 3: Compute the presentation sample in `emitPosition`**

```swift
private func emitPosition() {
  guard let session = currentSession,
    node.isPlaying, let nodeTime = node.lastRenderTime,
    let playerTime = node.playerTime(forNodeTime: nodeTime)
  else { return }
  let renderFrames = Int(max(0, playerTime.sampleTime))
  let renderSample = positionSample(forFramesPlayed: renderFrames)
  let presentationSample = positionSample(forFramesPlayed: presentationFrames(for: renderFrames))
  broadcast(
    PlaybackPosition(
      sessionID: session, renderSample: renderSample,
      presentationSample: presentationSample, isPlaying: true))
}

/// The audible (latency-compensated) input-frame count for a render-frame count, using the
/// cached device estimate + this device's stored manual offset at the current rate.
private func presentationFrames(for renderFrames: Int) -> Int {
  let manual = OutputLatencyOffsets.offsetSeconds(for: currentDeviceUID, in: offsets.wrappedValue)
  let effective = OutputLatencyMath.effectiveSeconds(
    automatic: automaticLatencySeconds, manual: manual)
  return OutputLatencyMath.presentationFrames(
    renderFrames: renderFrames, effectiveSeconds: effective,
    nativeSampleRate: nativeSampleRate, rate: currentRate)
}
```

- [ ] **Step 4: Compensate the paused resting sample**

In `pause`, map the compensated frames so the paused cursor matches the live follow (no forward jump):

```swift
let restingSample: PlaybackSample
if let nodeTime = node.lastRenderTime,
  let playerTime = node.playerTime(forNodeTime: nodeTime)
{
  restingSample = positionSample(
    forFramesPlayed: presentationFrames(for: Int(max(0, playerTime.sampleTime))))
} else {
  restingSample = positionSample(forFramesPlayed: 0)
}
```

- [ ] **Step 5: Stop playback on an output-device change (v1)**

Start observing in `init` (or lazily on first play); on each event, refresh the device/estimate and stop any current playback so the user restarts against the new device:

```swift
private func startObservingRouteChanges() {
  guard routeChangeTask == nil else { return }
  routeChangeTask = Task { [weak self] in
    guard let self else { return }
    for await _ in self.audioOutput.changes() {
      await self.handleOutputDeviceChanged()
    }
  }
}

private func handleOutputDeviceChanged() {
  // A default-output change tears down/retunes the engine graph; don't pair the new device with
  // the old graph's latency. Stop cleanly (a normal `.stopped`) — v1 requires pressing Play again
  // — then refresh identity for the next play.
  if currentSession != nil { supersede(reason: .stopped) }
  currentDeviceUID = audioOutput.current()?.uid
}
```

Call `startObservingRouteChanges()` at the end of `init`. Cancel `routeChangeTask` on deinit is unnecessary (the box lives for the app), but stop it defensively if you add teardown.

- [ ] **Step 6: Build + full suite (integration is manual; ensure nothing regressed)**

Run: `cd QuickInterviewEditor && make test-fast`
Expected: PASS. The existing `testValue`-based transport/editor tests must stay green (they never hit `live()`), and `withDependencies` in any test that touches the live path (there are none by default) is unaffected.

- [ ] **Step 7: Manual hardware verification (record result in the commit body)**

1. Play over **built-in output**: playhead tracks the sound as before (auto estimate small, offset ≈ 0).
2. Play over **Bluetooth headphones**: the playhead should sit noticeably closer to the heard audio than before. Confirm no crash, no negative/stuck cursor at playback start.
3. **Pause** during BT playback: the cursor stays put (no forward jump).
4. **Switch output device mid-playback** (e.g. unplug BT): playback stops cleanly; pressing Play resumes against the new device.

- [ ] **Step 8: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format-check && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Core/AudioPlayerClient.swift
git commit -m "feat: compensate playhead for output latency (auto estimate + per-device offset)"
```

---

### Task 6: Playback-latency Settings tab

A Settings tab mirroring the `ClipBoundarySettings` trio: shows the current output device name and its auto-measured estimate (from `.outputLatencyEstimates`, populated during playback), and a signed Earlier↔Later slider that writes this device's entry in `.outputLatencyOffsets`.

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Settings/PlaybackLatencySettingsModel.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Settings/PlaybackLatencySettingsView.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/QuickInterviewEditorApp.swift` (add `@State` + the tab, 44-86).
- Test: `QuickInterviewEditorTests/Views/Pages/Settings/PlaybackLatencySettingsModelTests.swift`

**Interfaces:**
- Consumes: `.outputLatencyOffsets`, `.outputLatencyEstimates`, `OutputLatencyOffsets.offsetSeconds` (Task 2); `AudioOutputClient` (Task 3).
- Produces: `PlaybackLatencySettingsModel` (methods: `viewAppeared()`, `offsetChanged(_ ms: Double)`, `resetTapped()`).

- [ ] **Step 1: Write the failing tests**

```swift
import Dependencies
import Sharing
import Testing
import CustomDump

@testable import PlayolaInterviewEditor

@MainActor
struct PlaybackLatencySettingsModelTests {

  @Test func viewAppearedResolvesCurrentDeviceNameAndOffset() {
    @Shared(.outputLatencyOffsets) var offsets = ["uid-buds": 0.05]
    let model = withDependencies {
      $0.audioOutput = AudioOutputClient(
        current: { OutputDevice(id: 1, uid: "uid-buds", name: "AirPods") },
        changes: { AsyncStream { $0.finish() } })
    } operation: {
      PlaybackLatencySettingsModel()
    }
    model.viewAppeared()
    expectNoDifference(model.deviceName, "AirPods")
    expectNoDifference(model.offsetMs, 50)  // 0.05 s → 50 ms
  }

  @Test func offsetChangedWritesSignedMillisecondsForCurrentDevice() {
    @Shared(.outputLatencyOffsets) var offsets = [:]
    let model = withDependencies {
      $0.audioOutput = AudioOutputClient(
        current: { OutputDevice(id: 1, uid: "uid-buds", name: "AirPods") },
        changes: { AsyncStream { $0.finish() } })
    } operation: {
      PlaybackLatencySettingsModel()
    }
    model.viewAppeared()
    model.offsetChanged(-30)
    expectNoDifference(offsets["uid-buds"], -0.030)  // stored in seconds
  }

  @Test func offsetChangedIsNoOpWhenNoDevice() {
    @Shared(.outputLatencyOffsets) var offsets = [:]
    let model = withDependencies {
      $0.audioOutput = AudioOutputClient(current: { nil }, changes: { AsyncStream { $0.finish() } })
    } operation: {
      PlaybackLatencySettingsModel()
    }
    model.viewAppeared()
    model.offsetChanged(-30)
    expectNoDifference(offsets, [:])
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd QuickInterviewEditor && make test-fast ONLY=PlayolaInterviewEditorTests/PlaybackLatencySettingsModelTests`
Expected: FAIL — model not defined.

- [ ] **Step 3: Write the model**

```swift
import Dependencies
import Foundation
import Observation
import Sharing

/// Drives the "Playback Latency" settings tab: shows the current output device and its
/// auto-measured latency, and a signed manual nudge (Earlier ↔ Later) persisted per device UID.
/// Auto-detection handles the baseline; this only corrects what the OS under/over-reports on a
/// given device (notably Bluetooth). All copy/bounds/derived values live here; the view binds only.
@MainActor
@Observable
final class PlaybackLatencySettingsModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.audioOutput) var audioOutput

  // MARK: - Shared State
  @ObservationIgnored @Shared(.outputLatencyOffsets) var offsets: [String: Double]
  @ObservationIgnored @Shared(.outputLatencyEstimates) var estimates: [String: Double]

  // MARK: - Properties
  let minMs = -300.0
  let maxMs = 300.0
  private var deviceUID: String?
  var deviceName: String = "No output device"
  var offsetMs: Double = 0

  // MARK: - Display Text
  let title = "Playback Latency"
  let sectionHeader = "Bluetooth A/V Sync"
  let helpText =
    "The app automatically delays the playhead to match when you hear the audio, so it lines up "
    + "over Bluetooth. If the playhead still leads or trails what you hear on this device, nudge "
    + "it Earlier or Later. Saved per output device."
  let offsetSliderLabel = "Adjust"
  let resetLabel = "Reset"

  // MARK: - View Helpers
  var deviceLabel: String { "Output: \(deviceName)" }
  var autoEstimateLabel: String {
    guard let uid = deviceUID, let seconds = estimates[uid] else {
      return "Auto-detected: measured during playback"
    }
    return "Auto-detected: \(Int((seconds * 1000).rounded())) ms"
  }
  var offsetLabel: String { Self.readoutLabel(for: offsetMs) }
  var canReset: Bool { offsetMs != 0 }

  // MARK: - User Actions
  func viewAppeared() {
    let device = audioOutput.current()
    deviceUID = device?.uid
    deviceName = device?.name ?? "No output device"
    let seconds = OutputLatencyOffsets.offsetSeconds(for: deviceUID, in: offsets)
    offsetMs = (seconds * 1000).rounded()
  }

  func offsetChanged(_ ms: Double) {
    guard let uid = deviceUID else { return }
    let clampedMs = min(max(ms, minMs), maxMs).rounded()
    offsetMs = clampedMs
    $offsets.withLock { $0[uid] = clampedMs / 1000 }
  }

  func resetTapped() {
    guard let uid = deviceUID else { return }
    offsetMs = 0
    $offsets.withLock { $0[uid] = 0 }
  }

  // MARK: - Private Helpers
  private static func readoutLabel(for ms: Double) -> String {
    let rounded = Int(ms.rounded())
    if rounded == 0 { return "0 ms" }
    if rounded > 0 { return "+\(rounded) ms later" }
    return "\u{2212}\(abs(rounded)) ms earlier"
  }
}
```

- [ ] **Step 4: Write the view**

```swift
import SwiftUI

/// The "Playback Latency" settings tab. Device name + auto estimate are read-only; the slider
/// nudges this device's manual offset. No logic here — all copy/bounds/enablement come from the model.
struct PlaybackLatencySettingsView: View {
  @Bindable var model: PlaybackLatencySettingsModel

  var body: some View {
    Form {
      Section {
        Text(model.helpText)
          .font(.callout)
          .foregroundStyle(.secondary)
        Text(model.deviceLabel)
        Text(model.autoEstimateLabel)
          .foregroundStyle(.secondary)
        LabeledContent(model.offsetSliderLabel) {
          HStack {
            Slider(
              value: Binding(get: { model.offsetMs }, set: { model.offsetChanged($0) }),
              in: model.minMs...model.maxMs, step: 1)
            Text(model.offsetLabel)
              .monospacedDigit()
              .frame(width: 96, alignment: .trailing)
          }
        }
        Button(model.resetLabel) { model.resetTapped() }
          .disabled(!model.canReset)
      } header: {
        Text(model.sectionHeader)
      }
    }
    .padding()
    .frame(width: 460)
    .onAppear { model.viewAppeared() }
  }
}
```

- [ ] **Step 5: Register the tab**

In `QuickInterviewEditorApp.swift`, add a state model beside the others (line 52):

```swift
@State private var playbackLatencySettings = PlaybackLatencySettingsModel()
```

and a tab inside the `TabView` (after the "Editing" tab, line 81):

```swift
PlaybackLatencySettingsView(model: playbackLatencySettings)
  .tabItem { Label("Playback Latency", systemImage: "wave.3.right") }
```

- [ ] **Step 6: Run tests + full suite**

Run: `cd QuickInterviewEditor && make test-fast`
Expected: PASS.

- [ ] **Step 7: Format, lint, commit**

```bash
cd QuickInterviewEditor && make format-check && make lint
git add -A
git commit -m "feat: Playback Latency settings tab (per-device Bluetooth A/V-sync offset)"
```

---

## Self-Review

**Spec coverage:**
- Auto estimate via `outputPresentationLatency`, refreshed on play/route change → Task 5 (Steps 2, 5). ✓
- Signed per-device manual offset, `[UID: seconds]` in one `@Shared(.fileStorage)` JSON, effective = max(0, auto+manual) → Tasks 1, 2, 5. ✓
- Offset math `frames − effective·nativeRate·rate`, clamp before mapping → Task 1 + Task 5 Step 3. ✓
- Render vs. presentation split; playhead/pause/marks use presentation, boundaries untouched → Task 4 + Task 5 Steps 3-4. (Marks read the cursor, which is now presentation via `observePlayback`.) ✓
- Device identity + change detection (UID, name, listener) → Task 3; stop-on-change v1 → Task 5 Step 5. ✓
- Settings: device name + auto estimate readout + signed Earlier↔Later control → Task 6. ✓
- Deferred (rate-history ring buffer, click/flash preview, seamless route recovery) → not implemented, by decision. ✓

**Placeholder scan:** No TBD/TODO; every code step carries real code. ✓

**Type consistency:** `OutputDevice`, `AudioOutputClient.current/changes`, `PlaybackPosition.renderSample/presentationSample`, `OutputLatencyMath.effectiveSeconds/presentationFrames`, `OutputLatencyOffsets.offsetSeconds`, `.outputLatencyOffsets`/`.outputLatencyEstimates` names match across tasks. ✓

**Module names (verified):** `@testable import PlayolaInterviewEditor` and `make test-fast ONLY=PlayolaInterviewEditorTests/...` are confirmed against existing test files and `QuickInterviewEditor/Makefile` — used verbatim throughout.
