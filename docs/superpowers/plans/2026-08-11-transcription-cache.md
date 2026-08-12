# Transcription Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make re-importing a byte-identical `.wav` instant by caching the WhisperX transcription result on disk, with automatic invalidation when the engine changes and manual force-refresh / clear controls.

**Architecture:** A new `TranscriptionClient` dependency sits between `SongTabModel` and the pure `EngineClient` subprocess boundary. It keys an on-disk cache by `SHA256(sourceFingerprint + engineFingerprint + schemaVersion)`, returns a synthesized `.completed` event on a hit (no subprocess), and stores the `EditPlan` + canonical AIFF on a miss. The engine fingerprint is a per-launch content hash of the engine, so any engine code/dependency change auto-misses. Force-refresh is a File-menu command (⌘⇧R) targeting the selected tab; clear + a live size label live in the Settings window.

**Tech Stack:** Swift 6, SwiftUI (macOS 15), Point-Free `swift-dependencies` + `swift-sharing`, Swift Testing, `swift-custom-dump`, CryptoKit, `Synchronization.Mutex`. Python `logic_markers` WhisperX engine driven as a subprocess (unchanged).

## Global Constraints

- **Pattern:** MV with `@Observable` models; **zero logic in views**; every model tested. Follow the `pfw-*` skills before writing Swift (`pfw-dependencies`, `pfw-observable-models`, `pfw-testing`, `pfw-custom-dump`).
- **Dependencies:** every side-effecting boundary is a `Sendable` client struct with `liveValue` + `testValue`, injected via `@Dependency`, overridden in tests with `withDependencies`.
- **Value comparisons in tests:** use `expectNoDifference` / `expectDifference` (not raw `#expect(a == b)`).
- **No `Task.sleep` in tests.** Deterministic, synchronous doubles only. Use bundled `edit-plan.json` fixtures — no real audio, no subprocess.
- **Test location:** tests mirror the source tree under `QuickInterviewEditorTests/` (e.g. `Core/Foo.swift` → `QuickInterviewEditorTests/Core/FooTests.swift`).
- **Naming:** action methods describe the user action (`reimportIgnoringCacheTapped`), test names are camelCase with no underscores.
- **Cache location:** `~/Library/Application Support/QuickInterviewEditor/TranscriptCache/<key>/` (mirrors the existing `Projects/` sidecar). This is Application Support (durable), **not** `Caches` (which `CanonicalAudioStore` uses and prunes).
- **Bias:** over-invalidation is safe (an extra transcribe); under-invalidation (stale result) is the only hazard — the engine fingerprint errs broad.
- **Build/test tooling:** new files are picked up by `make generate` (XcodeGen globs the `QuickInterviewEditor/` and `QuickInterviewEditorTests/` dirs). Run `make generate` after adding files, `make format` before committing, `make test` (fastlane) to run the suite. `make lint` must be clean.

---

### Task 1: `EngineFingerprint` — per-launch engine content hash

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Core/EngineFingerprint.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditorTests/Core/EngineFingerprintTests.swift`

**Interfaces:**
- Consumes: `EngineLaunch` (`Core/EngineResolution.swift`: `.isBundled`, `.executable`, `.workingDirectory`), `LiveEngine.resolvedLaunch()`.
- Produces:
  - `enum EngineFingerprint` with:
    - `static func compute(launch: EngineLaunch, pythonFiles: (URL) -> [URL], contentHash: (URL) -> String?) -> String` (pure core)
    - `static func current(launch: EngineLaunch = LiveEngine.resolvedLaunch()) -> String` (memoized once per process)
  - `struct EngineFingerprintClient: Sendable { var current: @Sendable () -> String }` with `\.engineFingerprint` dependency.

Rationale: dev runs `python -m logic_markers.cli` from the repo root, so the engine's behavior is defined by `logic_markers/**/*.py` plus the dependency pins (`requirements.txt`, `pyproject.toml`). Packaged runs the frozen `logic-markers-engine`, so its content hash defines behavior. `size+mtime` is rejected (false-hits). Memoize because hashing the packaged binary can take ~1s.

- [ ] **Step 1: Write the failing test**

Create `EngineFingerprintTests.swift`:

```swift
import Foundation
import Testing

@testable import QuickInterviewEditor

@Suite struct EngineFingerprintTests {
  private func devLaunch(root: URL) -> EngineLaunch {
    EngineLaunch(
      executable: root.appendingPathComponent(".venv/bin/python"),
      argumentPrefix: ["-m", "logic_markers.cli"],
      workingDirectory: root, isBundled: false)
  }

  @Test func devFingerprintCoversPythonSourcesAndPins() {
    let root = URL(fileURLWithPath: "/repo")
    let a = root.appendingPathComponent("logic_markers/cli.py")
    let b = root.appendingPathComponent("logic_markers/whisperx_backend.py")
    var contents = [a.path: "h1", b.path: "h2", root.appendingPathComponent("requirements.txt").path: "r1"]

    let first = EngineFingerprint.compute(
      launch: devLaunch(root: root),
      pythonFiles: { _ in [b, a] },  // unsorted on purpose
      contentHash: { contents[$0.path] })

    // Changing a source file changes the fingerprint.
    contents[a.path] = "h1-modified"
    let second = EngineFingerprint.compute(
      launch: devLaunch(root: root),
      pythonFiles: { _ in [a, b] },
      contentHash: { contents[$0.path] })

    #expect(first.hasPrefix("engine:src:"))
    #expect(first != second)
  }

  @Test func devFingerprintIsStableRegardlessOfFileOrder() {
    let root = URL(fileURLWithPath: "/repo")
    let a = root.appendingPathComponent("logic_markers/a.py")
    let b = root.appendingPathComponent("logic_markers/b.py")
    let contents = [a.path: "ha", b.path: "hb"]
    let one = EngineFingerprint.compute(
      launch: devLaunch(root: root), pythonFiles: { _ in [a, b] }, contentHash: { contents[$0.path] })
    let two = EngineFingerprint.compute(
      launch: devLaunch(root: root), pythonFiles: { _ in [b, a] }, contentHash: { contents[$0.path] })
    #expect(one == two)
  }

  @Test func bundledFingerprintHashesTheBinary() {
    let launch = EngineLaunch(
      executable: URL(fileURLWithPath: "/app/engine/logic-markers-engine"),
      argumentPrefix: [], workingDirectory: URL(fileURLWithPath: "/app/engine"), isBundled: true)
    let value = EngineFingerprint.compute(
      launch: launch, pythonFiles: { _ in [] }, contentHash: { _ in "binhash" })
    #expect(value == "engine:bin:binhash")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make generate && make test` (or the `EngineFingerprintTests` filter in Xcode)
Expected: FAIL — `EngineFingerprint` is undefined.

- [ ] **Step 3: Write minimal implementation**

Create `EngineFingerprint.swift`:

```swift
import CryptoKit
import Foundation
import Synchronization

/// A per-process content hash of the transcription engine, folded into the
/// transcription cache key so any engine change auto-invalidates cached results.
///
/// Dev (runs `python -m logic_markers.cli` from the repo root) is defined by the
/// `logic_markers` package plus the dependency pins. Packaged (frozen helper) is
/// defined by the binary's contents. `size+mtime` is deliberately NOT used — it
/// false-hits on a rebuild that changes behavior without changing size/mtime.
enum EngineFingerprint {

  /// The dependency-pin files (relative to the dev repo root) folded in alongside
  /// the Python sources, so a WhisperX/dep bump also invalidates.
  static let pinFiles = ["requirements.txt", "pyproject.toml"]

  private static let cached = Mutex<String?>(nil)

  /// Memoized once per app launch (hashing the packaged binary can take ~1s).
  static func current(launch: EngineLaunch = LiveEngine.resolvedLaunch()) -> String {
    cached.withLock { stored in
      if let stored { return stored }
      let value = compute(
        launch: launch,
        pythonFiles: { pythonFiles(under: $0) },
        contentHash: { sha256OfFile($0) })
      stored = value
      return value
    }
  }

  /// Pure core with filesystem access injected, so it unit-tests without disk.
  static func compute(
    launch: EngineLaunch,
    pythonFiles: (URL) -> [URL],
    contentHash: (URL) -> String?
  ) -> String {
    if launch.isBundled {
      return "engine:bin:\(contentHash(launch.executable) ?? "missing")"
    }
    let root = launch.workingDirectory
    let pkg = root.appendingPathComponent("logic_markers")
    var entries: [String] = []
    for file in pythonFiles(pkg).sorted(by: { $0.path < $1.path }) {
      let rel = file.path.replacingOccurrences(of: root.path + "/", with: "")
      entries.append("\(rel):\(contentHash(file) ?? "missing")")
    }
    for pin in pinFiles {
      let url = root.appendingPathComponent(pin)
      if let hash = contentHash(url) { entries.append("\(pin):\(hash)") }
    }
    let digest = SHA256.hash(data: Data(entries.joined(separator: "\n").utf8))
    return "engine:src:" + digest.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Filesystem

  private static func pythonFiles(under dir: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "py" }
  }

  private static func sha256OfFile(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
```

- [ ] **Step 4: Add the `EngineFingerprintClient` dependency (same file)**

Append to `EngineFingerprint.swift`:

```swift
import Dependencies

struct EngineFingerprintClient: Sendable {
  var current: @Sendable () -> String
}

extension EngineFingerprintClient: DependencyKey {
  static let liveValue = EngineFingerprintClient(current: { EngineFingerprint.current() })
}

extension EngineFingerprintClient: TestDependencyKey {
  static let testValue = EngineFingerprintClient(current: { "engine:test" })
}

extension DependencyValues {
  var engineFingerprint: EngineFingerprintClient {
    get { self[EngineFingerprintClient.self] }
    set { self[EngineFingerprintClient.self] = newValue }
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test`
Expected: PASS (all three `EngineFingerprintTests`).

- [ ] **Step 6: Format, lint, commit**

```bash
make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Core/EngineFingerprint.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Core/EngineFingerprintTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(cache): engine content fingerprint for cache invalidation"
```

---

### Task 2: `TranscriptCacheClient` — the on-disk cache

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Core/TranscriptCache.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditorTests/Core/TranscriptCacheTests.swift`

**Interfaces:**
- Consumes: `EditPlan` (`Models/EditPlan.swift`: `Codable`, `static func decoded(from: URL) throws -> EditPlan`).
- Produces:
  - `struct CachedTranscription: Sendable, Equatable { var editPlan: EditPlan; var canonicalAudioURL: URL }`
  - `struct TranscriptCacheClient: Sendable { var lookup: @Sendable (String) -> CachedTranscription?; var store: @Sendable (String, EditPlan, URL) throws -> CachedTranscription; var clear: @Sendable () throws -> Void; var totalSize: @Sendable () -> Int64 }`
  - `static func TranscriptCacheClient.onDisk(base: URL) -> TranscriptCacheClient` (used by `liveValue` with the real base, and by tests with a temp dir).
  - `\.transcriptCache` dependency.

Storage: `TranscriptCache/<key>/` holding `plan.json`, `canonical.aiff`, `manifest.json`. **Atomic store:** build a sibling temp dir, write `plan.json`, copy the AIFF, write `manifest.json` **last**, then remove any existing `<key>/` and rename the temp dir into place. **Lookup is a hit only if** the manifest exists (with a matching schema version) and both payload files are present.

- [ ] **Step 1: Write the failing tests**

Create `TranscriptCacheTests.swift`:

```swift
import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

@Suite struct TranscriptCacheTests {
  /// A unique temp base dir per test; caller removes it.
  private func makeBase() -> URL {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-cache-tests/\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  /// A tiny stand-in AIFF payload on disk (content, not real audio).
  private func makeAIFF(_ base: URL, bytes: String = "AIFFDATA") -> URL {
    let url = base.appendingPathComponent("source-\(UUID().uuidString).aiff")
    try? Data(bytes.utf8).write(to: url)
    return url
  }

  @Test func storeThenLookupReturnsCachedPlanAndCacheOwnedAIFF() throws {
    let base = makeBase(); defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base)
    let plan = Fixtures.editPlan()
    let aiff = makeAIFF(base)

    let stored = try cache.store("key1", plan, aiff)
    // The stored AIFF is a cache-owned copy, not the source path.
    #expect(stored.canonicalAudioURL != aiff)
    #expect(FileManager.default.fileExists(atPath: stored.canonicalAudioURL.path))

    let hit = try #require(cache.lookup("key1"))
    expectNoDifference(hit.editPlan, plan)
    expectNoDifference(hit.canonicalAudioURL, stored.canonicalAudioURL)
  }

  @Test func lookupMissesForUnknownKey() {
    let base = makeBase(); defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base)
    #expect(cache.lookup("nope") == nil)
  }

  @Test func lookupMissesWhenManifestIsAbsent() throws {
    let base = makeBase(); defer { try? FileManager.default.removeItem(at: base) }
    // Simulate a half-written entry: plan.json + canonical.aiff but no manifest.
    let dir = base.appendingPathComponent("partial")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONEncoder().encode(Fixtures.editPlan()).write(to: dir.appendingPathComponent("plan.json"))
    try Data("x".utf8).write(to: dir.appendingPathComponent("canonical.aiff"))

    let cache = TranscriptCacheClient.onDisk(base: base)
    #expect(cache.lookup("partial") == nil)  // no manifest ⇒ not a committed entry
  }

  @Test func storeOverwritesExistingEntry() throws {
    let base = makeBase(); defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base)
    _ = try cache.store("k", Fixtures.editPlan(), makeAIFF(base, bytes: "one"))
    let second = try cache.store("k", Fixtures.editPlan(), makeAIFF(base, bytes: "two"))
    let hit = try #require(cache.lookup("k"))
    expectNoDifference(hit.canonicalAudioURL, second.canonicalAudioURL)
    #expect(try Data(contentsOf: hit.canonicalAudioURL) == Data("two".utf8))
  }

  @Test func totalSizeAndClear() throws {
    let base = makeBase(); defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base)
    _ = try cache.store("k", Fixtures.editPlan(), makeAIFF(base))
    #expect(cache.totalSize() > 0)
    try cache.clear()
    #expect(cache.totalSize() == 0)
    #expect(cache.lookup("k") == nil)
  }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make generate && make test`
Expected: FAIL — `TranscriptCacheClient` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `TranscriptCache.swift`:

```swift
import Dependencies
import Foundation

/// A finished transcription pulled from (or written to) the on-disk cache: the
/// decoded plan plus a **cache-owned** canonical AIFF URL.
struct CachedTranscription: Sendable, Equatable {
  var editPlan: EditPlan
  var canonicalAudioURL: URL
}

/// Persistent, fingerprint-keyed cache of transcription results so a re-import of a
/// byte-identical file is instant. Lives under Application Support (durable) — NOT
/// `Caches` (where `CanonicalAudioStore` keeps its session-scoped, pruned copies).
///
/// Layout: `TranscriptCache/<key>/{plan.json, canonical.aiff, manifest.json}`.
/// The cache owns its own AIFF copy; `CanonicalAudioStore.remove` is guarded to its
/// own base, so tab-close cleanup never deletes a cache-owned file.
enum TranscriptCache {
  static let schemaVersion = 1
  static let planName = "plan.json"
  static let audioName = "canonical.aiff"
  static let manifestName = "manifest.json"

  struct Manifest: Codable, Equatable {
    var schemaVersion: Int
    var key: String
  }

  static func baseDirectory() throws -> URL {
    URL.applicationSupportDirectory
      .appending(component: "QuickInterviewEditor", directoryHint: .isDirectory)
      .appending(component: "TranscriptCache", directoryHint: .isDirectory)
  }

  static func lookup(key: String, base: URL) -> CachedTranscription? {
    let dir = base.appendingPathComponent(key)
    let manifestURL = dir.appendingPathComponent(manifestName)
    let planURL = dir.appendingPathComponent(planName)
    let audioURL = dir.appendingPathComponent(audioName)
    let fm = FileManager.default
    guard
      fm.fileExists(atPath: manifestURL.path),
      fm.fileExists(atPath: planURL.path),
      fm.fileExists(atPath: audioURL.path),
      let manifestData = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
      manifest.schemaVersion == schemaVersion,
      let plan = try? EditPlan.decoded(from: planURL)
    else { return nil }
    return CachedTranscription(editPlan: plan, canonicalAudioURL: audioURL)
  }

  static func store(key: String, plan: EditPlan, canonicalAudioURL: URL, base: URL) throws
    -> CachedTranscription
  {
    let fm = FileManager.default
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let tmp = base.appendingPathComponent("\(key).tmp.\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }  // no-op once renamed away

    try JSONEncoder().encode(plan).write(to: tmp.appendingPathComponent(planName))
    try fm.copyItem(at: canonicalAudioURL, to: tmp.appendingPathComponent(audioName))
    // Manifest written LAST — its presence is the commit marker a lookup checks.
    let manifest = Manifest(schemaVersion: schemaVersion, key: key)
    try JSONEncoder().encode(manifest).write(to: tmp.appendingPathComponent(manifestName))

    let dest = base.appendingPathComponent(key)
    try? fm.removeItem(at: dest)  // replace any prior entry (force-refresh)
    try fm.moveItem(at: tmp, to: dest)
    return CachedTranscription(
      editPlan: plan, canonicalAudioURL: dest.appendingPathComponent(audioName))
  }

  static func clear(base: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: base.path) { try fm.removeItem(at: base) }
  }

  static func totalSize(base: URL) -> Int64 {
    guard
      let enumerator = FileManager.default.enumerator(
        at: base, includingPropertiesForKeys: [.fileSizeKey], options: [])
    else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      total += Int64(size)
    }
    return total
  }
}

struct TranscriptCacheClient: Sendable {
  var lookup: @Sendable (_ key: String) -> CachedTranscription?
  var store: @Sendable (_ key: String, _ plan: EditPlan, _ canonicalAudioURL: URL) throws -> CachedTranscription
  var clear: @Sendable () throws -> Void
  var totalSize: @Sendable () -> Int64

  /// Wires the client to a concrete base dir. `liveValue` uses the real Application
  /// Support base; tests pass a temp dir.
  static func onDisk(base: URL) -> TranscriptCacheClient {
    TranscriptCacheClient(
      lookup: { TranscriptCache.lookup(key: $0, base: base) },
      store: { try TranscriptCache.store(key: $0, plan: $1, canonicalAudioURL: $2, base: base) },
      clear: { try TranscriptCache.clear(base: base) },
      totalSize: { TranscriptCache.totalSize(base: base) })
  }
}

extension TranscriptCacheClient: DependencyKey {
  static let liveValue: TranscriptCacheClient = {
    // Resolve the base lazily so an unavailable Application Support dir degrades to
    // a quiet miss rather than crashing at launch.
    guard let base = try? TranscriptCache.baseDirectory() else {
      return TranscriptCacheClient(
        lookup: { _ in nil },
        store: { _, plan, url in CachedTranscription(editPlan: plan, canonicalAudioURL: url) },
        clear: {}, totalSize: { 0 })
    }
    return .onDisk(base: base)
  }()
}

extension TranscriptCacheClient: TestDependencyKey {
  /// Default: a quiet always-miss (models overriding `\.transcription` never reach it).
  static let testValue = TranscriptCacheClient(
    lookup: { _ in nil },
    store: { _, plan, url in CachedTranscription(editPlan: plan, canonicalAudioURL: url) },
    clear: {}, totalSize: { 0 })
}

extension DependencyValues {
  var transcriptCache: TranscriptCacheClient {
    get { self[TranscriptCacheClient.self] }
    set { self[TranscriptCacheClient.self] = newValue }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS (all `TranscriptCacheTests`).

- [ ] **Step 5: Format, lint, commit**

```bash
make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Core/TranscriptCache.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Core/TranscriptCacheTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(cache): on-disk transcript cache with atomic store"
```

---

### Task 3: `TranscriptionCacheKey` — key derivation + bypass rule

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Core/TranscriptionCacheKey.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditorTests/Core/TranscriptionCacheKeyTests.swift`

**Interfaces:**
- Produces: `enum TranscriptionCacheKey { static let schemaVersion: String; static func make(sourceFingerprint: String, engineFingerprint: String) -> String? }`. Returns `nil` when `sourceFingerprint` is not a `sha256:` fingerprint — the signal to bypass the cache.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing

@testable import QuickInterviewEditor

@Suite struct TranscriptionCacheKeyTests {
  @Test func sha256FingerprintProducesStableKey() {
    let a = TranscriptionCacheKey.make(sourceFingerprint: "sha256:abc", engineFingerprint: "engine:src:1")
    let b = TranscriptionCacheKey.make(sourceFingerprint: "sha256:abc", engineFingerprint: "engine:src:1")
    #expect(a != nil)
    #expect(a == b)
  }

  @Test func differentEngineFingerprintChangesKey() {
    let a = TranscriptionCacheKey.make(sourceFingerprint: "sha256:abc", engineFingerprint: "engine:src:1")
    let b = TranscriptionCacheKey.make(sourceFingerprint: "sha256:abc", engineFingerprint: "engine:src:2")
    #expect(a != b)
  }

  @Test func pathFingerprintBypassesCache() {
    let key = TranscriptionCacheKey.make(sourceFingerprint: "path:/tmp/x.wav", engineFingerprint: "engine:src:1")
    #expect(key == nil)
  }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make generate && make test`
Expected: FAIL — `TranscriptionCacheKey` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import CryptoKit
import Foundation

/// Derives the transcript-cache key. Combines the source content fingerprint, the
/// engine fingerprint, and a schema version so any of the three changing yields a
/// different cache entry. Returns `nil` for non-`sha256:` fingerprints (unreadable
/// bytes) — a `path:` key could serve a stale transcript for a different file that
/// later occupies the same path, so those imports bypass the cache entirely.
enum TranscriptionCacheKey {
  static let schemaVersion = "1"

  static func make(sourceFingerprint: String, engineFingerprint: String) -> String? {
    guard sourceFingerprint.hasPrefix("sha256:") else { return nil }
    let material = sourceFingerprint + "\n" + engineFingerprint + "\n" + schemaVersion
    let digest = SHA256.hash(data: Data(material.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Format, lint, commit**

```bash
make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Core/TranscriptionCacheKey.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Core/TranscriptionCacheKeyTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(cache): transcription cache key derivation + bypass rule"
```

---

### Task 4: `TranscriptionClient` — cache-aware wrapper over `EngineClient`

**Files:**
- Create: `QuickInterviewEditor/QuickInterviewEditor/Core/TranscriptionClient.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditorTests/Core/TranscriptionClientTests.swift`

**Interfaces:**
- Consumes: `EngineClient` (`\.engine`), `TranscriptCacheClient` (`\.transcriptCache`), `EngineFingerprintClient` (`\.engineFingerprint`), `TranscriptionCacheKey.make`, `EngineEvent` / `TranscriptionResult`.
- Produces:
  - `enum CachePolicy: Sendable, Equatable { case useCache, forceFresh }`
  - `struct TranscriptionClient: Sendable { var transcribe: @Sendable (_ source: URL, _ sourceFingerprint: String, _ policy: CachePolicy) -> AsyncThrowingStream<EngineEvent, Error> }`
  - `\.transcription` dependency (live wraps engine+cache+fingerprint; `testValue` unimplemented; `previewValue` yields `.fixture`).

Behavior: `.useCache` + `sha256` key + cache hit → synthesize `.completed` from disk, **no subprocess**. Otherwise stream the real engine; on `.completed`, if there's a key, store the result and re-emit `.completed` with the **cache-owned** AIFF URL (falling back to the engine's URL if the store fails). Non-`sha256` fingerprint (key `nil`) → forward the engine stream, never touch the cache.

- [ ] **Step 1: Write the failing tests**

```swift
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor @Suite struct TranscriptionClientTests {
  private func engineStream(_ events: [EngineEvent]) -> AsyncThrowingStream<EngineEvent, Error> {
    AsyncThrowingStream { c in
      for e in events { c.yield(e) }
      c.finish()
    }
  }

  private func tempBase() -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("qie-tc/\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  private func makeAIFF(_ base: URL) -> URL {
    let url = base.appendingPathComponent("engine-\(UUID().uuidString).aiff")
    try? Data("AIFF".utf8).write(to: url)
    return url
  }

  private func drainCompleted(_ stream: AsyncThrowingStream<EngineEvent, Error>) async throws
    -> TranscriptionResult?
  {
    var result: TranscriptionResult?
    for try await event in stream { if case .completed(let r) = event { result = r } }
    return result
  }

  @Test func missRunsEngineAndStoresResult() async throws {
    let base = tempBase(); defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base)
    let plan = Fixtures.editPlan()
    let engineAIFF = makeAIFF(base)
    let engineCalls = LockIsolated(0)

    let result = try await withDependencies {
      $0.transcriptCache = cache
      $0.engineFingerprint = EngineFingerprintClient(current: { "engine:test" })
      $0.engine.transcribe = { _ in
        engineCalls.withValue { $0 += 1 }
        return self.engineStream([.completed(TranscriptionResult(editPlan: plan, canonicalAudioURL: engineAIFF))])
      }
    } operation: {
      try await self.drainCompleted(
        TranscriptionClient.liveValue.transcribe(URL(fileURLWithPath: "/clip.wav"), "sha256:abc", .useCache))
    }

    #expect(engineCalls.value == 1)
    // Re-emitted with a cache-owned URL, and the entry is now on disk.
    #expect(result?.canonicalAudioURL != engineAIFF)
    #expect(cache.lookup(TranscriptionCacheKey.make(sourceFingerprint: "sha256:abc", engineFingerprint: "engine:test")!) != nil)
  }

  @Test func hitReturnsCachedResultWithoutRunningEngine() async throws {
    let base = tempBase(); defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base)
    let plan = Fixtures.editPlan()
    let key = TranscriptionCacheKey.make(sourceFingerprint: "sha256:abc", engineFingerprint: "engine:test")!
    _ = try cache.store(key, plan, makeAIFF(base))
    let engineCalls = LockIsolated(0)

    let result = try await withDependencies {
      $0.transcriptCache = cache
      $0.engineFingerprint = EngineFingerprintClient(current: { "engine:test" })
      $0.engine.transcribe = { _ in
        engineCalls.withValue { $0 += 1 }
        return self.engineStream([])
      }
    } operation: {
      try await self.drainCompleted(
        TranscriptionClient.liveValue.transcribe(URL(fileURLWithPath: "/clip.wav"), "sha256:abc", .useCache))
    }

    #expect(engineCalls.value == 0)  // no subprocess
    expectNoDifference(result?.editPlan, plan)
  }

  @Test func forceFreshRunsEngineEvenWithWarmEntry() async throws {
    let base = tempBase(); defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base)
    let key = TranscriptionCacheKey.make(sourceFingerprint: "sha256:abc", engineFingerprint: "engine:test")!
    _ = try cache.store(key, Fixtures.editPlan(), makeAIFF(base))
    let engineCalls = LockIsolated(0)

    _ = try await withDependencies {
      $0.transcriptCache = cache
      $0.engineFingerprint = EngineFingerprintClient(current: { "engine:test" })
      $0.engine.transcribe = { _ in
        engineCalls.withValue { $0 += 1 }
        return self.engineStream([.completed(TranscriptionResult(editPlan: Fixtures.editPlan(), canonicalAudioURL: self.makeAIFF(base)))])
      }
    } operation: {
      try await self.drainCompleted(
        TranscriptionClient.liveValue.transcribe(URL(fileURLWithPath: "/clip.wav"), "sha256:abc", .forceFresh))
    }
    #expect(engineCalls.value == 1)
  }

  @Test func nonSha256FingerprintBypassesCache() async throws {
    let base = tempBase(); defer { try? FileManager.default.removeItem(at: base) }
    let cache = TranscriptCacheClient.onDisk(base: base)
    let engineAIFF = makeAIFF(base)
    let engineCalls = LockIsolated(0)

    let result = try await withDependencies {
      $0.transcriptCache = cache
      $0.engineFingerprint = EngineFingerprintClient(current: { "engine:test" })
      $0.engine.transcribe = { _ in
        engineCalls.withValue { $0 += 1 }
        return self.engineStream([.completed(TranscriptionResult(editPlan: Fixtures.editPlan(), canonicalAudioURL: engineAIFF))])
      }
    } operation: {
      try await self.drainCompleted(
        TranscriptionClient.liveValue.transcribe(URL(fileURLWithPath: "/clip.wav"), "path:/clip.wav", .useCache))
    }
    #expect(engineCalls.value == 1)
    #expect(result?.canonicalAudioURL == engineAIFF)  // engine URL passed through, not stored
    #expect(cache.totalSize() == 0)
  }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make generate && make test`
Expected: FAIL — `TranscriptionClient` / `CachePolicy` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Dependencies
import Foundation
import IssueReporting

enum CachePolicy: Sendable, Equatable {
  case useCache
  case forceFresh
}

/// Cache-aware transcription. Wraps the pure `EngineClient` subprocess boundary with
/// the on-disk `TranscriptCacheClient`, keyed by source + engine fingerprint. A cache
/// hit skips the subprocess entirely; a miss runs the engine and stores the result.
struct TranscriptionClient: Sendable {
  var transcribe:
    @Sendable (_ source: URL, _ sourceFingerprint: String, _ policy: CachePolicy)
      -> AsyncThrowingStream<EngineEvent, Error>
}

enum LiveTranscription {
  static func stream(
    source: URL, sourceFingerprint: String, policy: CachePolicy,
    engine: EngineClient, cache: TranscriptCacheClient, engineFingerprint: String
  ) -> AsyncThrowingStream<EngineEvent, Error> {
    let key = TranscriptionCacheKey.make(
      sourceFingerprint: sourceFingerprint, engineFingerprint: engineFingerprint)

    // Cache hit → synthesize completion, no subprocess.
    if policy == .useCache, let key, let hit = cache.lookup(key) {
      return AsyncThrowingStream { continuation in
        continuation.yield(
          .completed(TranscriptionResult(editPlan: hit.editPlan, canonicalAudioURL: hit.canonicalAudioURL)))
        continuation.finish()
      }
    }

    // Miss / forced / bypass → run the engine; store on completion when we have a key.
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await event in engine.transcribe(source) {
            switch event {
            case .progress:
              continuation.yield(event)
            case .completed(let result):
              var out = result
              if let key {
                if let cached = try? cache.store(key, result.editPlan, result.canonicalAudioURL) {
                  out = TranscriptionResult(
                    editPlan: cached.editPlan, canonicalAudioURL: cached.canonicalAudioURL)
                }  // store failed → keep the engine's own URL so the session still works
              }
              continuation.yield(.completed(out))
            }
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

extension TranscriptionClient: DependencyKey {
  static let liveValue = TranscriptionClient(transcribe: { source, fingerprint, policy in
    @Dependency(\.engine) var engine
    @Dependency(\.transcriptCache) var cache
    @Dependency(\.engineFingerprint) var engineFingerprint
    return LiveTranscription.stream(
      source: source, sourceFingerprint: fingerprint, policy: policy,
      engine: engine, cache: cache, engineFingerprint: engineFingerprint.current())
  })
}

extension TranscriptionClient: TestDependencyKey {
  static let testValue = TranscriptionClient(transcribe: { _, _, _ in
    AsyncThrowingStream { continuation in
      reportIssue("TranscriptionClient.transcribe called without a test override")
      continuation.finish(throwing: EngineClientError.unimplemented("transcribe"))
    }
  })

  static let previewValue = TranscriptionClient(transcribe: { _, _, _ in
    AsyncThrowingStream { continuation in
      continuation.yield(
        .completed(
          TranscriptionResult(
            editPlan: .fixture,
            canonicalAudioURL: URL(fileURLWithPath: "/preview/canonical.aiff"))))
      continuation.finish()
    }
  })
}

extension DependencyValues {
  var transcription: TranscriptionClient {
    get { self[TranscriptionClient.self] }
    set { self[TranscriptionClient.self] = newValue }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS (all `TranscriptionClientTests`).

- [ ] **Step 5: Format, lint, commit**

```bash
make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Core/TranscriptionClient.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Core/TranscriptionClientTests.swift \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(cache): cache-aware TranscriptionClient wrapping the engine"
```

---

### Task 5: Wire `SongTabModel` to the cache + add the re-import action

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabModel.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/SongTab/SongTabTests.swift`

**Interfaces:**
- Consumes: `\.transcription` (Task 4), `CachePolicy`, `SourceFingerprint.make`.
- Produces (used by Task 6): `SongTabModel.reimportIgnoringCacheTapped()`, `SongTabModel.canReimport: Bool`.

The model swaps its `\.engine` dependency for `\.transcription`, threads a `CachePolicy` (default `.useCache`, consumed each run), and adds a re-import action that re-queues the tab with `.forceFresh`.

- [ ] **Step 1: Update the existing tests (they currently mock `\.engine`)**

In `SongTabTests.swift`, replace every `$0.engine.transcribe = { _ in stream(...) }` with the new signature `$0.transcription.transcribe = { _, _, _ in stream(...) }`. Example for `progressThenCompletedWalksToLoaded`:

```swift
await withDependencies {
  $0.transcription.transcribe = { _, _, _ in
    stream([
      .progress(.init(phase: .transcribing, message: "Transcribing")),
      .completed(Fixtures.transcriptionResult(plan, canonicalAudioURL: canonical)),
    ])
  }
} operation: {
  await model.startTranscription()
}
```

Apply the same rename to `progressUpdatesMessageBeforeCompletion`, `failureSetsFailedPhaseWithMessage`, and `completionInvokesOnReadyForNext`.

- [ ] **Step 2: Add new tests for policy + re-import**

Append to `SongTabTests.swift`:

```swift
  @Test func startPassesUseCachePolicyByDefault() async {
    let captured = LockIsolated<CachePolicy?>(nil)
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    await withDependencies {
      $0.transcription.transcribe = { _, _, policy in
        captured.setValue(policy)
        return stream([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.startTranscription()
    }
    expectNoDifference(captured.value, .useCache)
  }

  @Test func reimportIgnoringCacheRequeuesWithForceFresh() async {
    let captured = LockIsolated<CachePolicy?>(nil)
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    var readyCalled = false
    model.onReadyForNext = { readyCalled = true }

    model.reimportIgnoringCacheTapped()
    #expect(model.isQueued)   // re-enters the queue so the cap is respected
    #expect(readyCalled)

    await withDependencies {
      $0.transcription.transcribe = { _, _, policy in
        captured.setValue(policy)
        return stream([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.startTranscription()
    }
    expectNoDifference(captured.value, .forceFresh)
  }

  @Test func canReimportOnlyWhenLoaded() async {
    let model = SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.m4a"))
    #expect(!model.canReimport)  // queued
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in stream([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))]) }
    } operation: { await model.startTranscription() }
    #expect(model.canReimport)   // loaded
  }
```

Add `import Dependencies` to the test file if not already present (for `LockIsolated`).

- [ ] **Step 3: Run to verify failure**

Run: `make test`
Expected: FAIL — `\.transcription` on the model, `reimportIgnoringCacheTapped`, `canReimport`, and the `.transcribe` closure arity don't exist yet.

- [ ] **Step 4: Update `SongTabModel`**

In `SongTabModel.swift`:

Replace the dependency:
```swift
  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.transcription) var transcription
```

Add a consumed policy property in `// MARK: - Properties`:
```swift
  /// Consumed (and reset to `.useCache`) on each run. Set to `.forceFresh` by the
  /// re-import action so a single fresh transcription overwrites the cached entry.
  @ObservationIgnored private var cachePolicy: CachePolicy = .useCache
```

Add a view helper alongside the others:
```swift
  var canReimport: Bool { isLoaded }
```

Rewrite `startTranscription()` to consume the policy and call `transcription`:
```swift
  func startTranscription() async {
    editor = nil
    let policy = cachePolicy
    cachePolicy = .useCache  // a subsequent retry uses the cache again
    let fingerprint = await SourceFingerprint.make(for: sourceURL)
    do {
      for try await event in transcription.transcribe(sourceURL, fingerprint, policy) {
        switch event {
        case .progress(let progress): phase = .transcribing(progress)
        case .completed(let result):
          editor = withDependencies(from: self) {
            EditorModel(
              sourceURL: sourceURL, canonicalAudioURL: result.canonicalAudioURL,
              editPlan: result.editPlan, sourceFingerprint: fingerprint)
          }
          phase = .loaded
        }
      }
    } catch is CancellationError {
      return
    } catch {
      phase = .failed(error.localizedDescription)
    }
    onReadyForNext?()
  }
```

Add the action in `// MARK: - User Actions` (next to `retryTapped`):
```swift
  /// Re-transcribe the current source ignoring any cached result, overwriting the
  /// cache entry. Re-enters the queue (like retry) so the concurrency cap holds.
  func reimportIgnoringCacheTapped() {
    task?.cancel()
    cachePolicy = .forceFresh
    phase = .queued
    onReadyForNext?()
  }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test`
Expected: PASS (migrated + new `SongTabTests`).

- [ ] **Step 6: Format, lint, commit**

```bash
make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor/Views/Pages/SongTab/SongTabModel.swift \
        QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/SongTab/SongTabTests.swift
git commit -m "feat(cache): route SongTab through TranscriptionClient + re-import action"
```

---

### Task 6: Force-refresh menu command + Settings clear/size UI

**Files:**
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/RootPage/RootModel.swift`
- Create: `QuickInterviewEditor/QuickInterviewEditor/Views/Commands/TranscriptionCommands.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/QuickInterviewEditorApp.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Settings/SettingsModel.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditor/Views/Pages/Settings/SettingsView.swift`
- Modify: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/Settings/SettingsTests.swift` (create if absent)
- Modify: `QuickInterviewEditor/QuickInterviewEditorTests/Views/Pages/RootPage/RootModelTests.swift` (create if absent)

**Interfaces:**
- Consumes: `SongTabModel.reimportIgnoringCacheTapped()`, `SongTabModel.canReimport` (Task 5), `\.transcriptCache` (Task 2).
- Produces: `RootModel.reimportSelectedTabIgnoringCache()`, `RootModel.canReimportSelectedTab`; `SettingsModel` cache section; `TranscriptionCommands: Commands`.

> **Design note (small deviation from the spec, improves it):** the "Clear Transcription Cache" control with its live size label lives in the **Settings window** (`SettingsView` is already a fully-observable `@Observable` surface, so the size updates cleanly) rather than as a menu title (menu titles don't reliably live-refresh). Force-refresh stays a File-menu command with a ⌘⇧R shortcut.

#### 6a: RootModel action

- [ ] **Step 1: Write the failing RootModel test**

Create/append `RootModelTests.swift`:
```swift
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor struct RootModelTests {
  @Test func reimportSelectedTabRequeuesIt() async {
    let model = withDependencies { _ in } operation: { RootModel() }
    let tab = withDependencies(from: model) { SongTabModel(sourceURL: URL(fileURLWithPath: "/clip.wav")) }
    model.tabs.append(tab)
    model.selectedTabID = tab.id
    // Drive it to `.loaded` so re-import is allowed.
    await withDependencies {
      $0.transcription.transcribe = { _, _, _ in
        AsyncThrowingStream { c in c.yield(.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))); c.finish() }
      }
    } operation: { await tab.startTranscription() }

    #expect(model.canReimportSelectedTab)
    model.reimportSelectedTabIgnoringCache()
    #expect(tab.isQueued)  // re-import re-enters the queue
  }

  @Test func cannotReimportWithNoSelection() {
    let model = withDependencies { _ in } operation: { RootModel() }
    #expect(!model.canReimportSelectedTab)
  }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make generate && make test`
Expected: FAIL — `reimportSelectedTabIgnoringCache` / `canReimportSelectedTab` undefined.

- [ ] **Step 3: Add the RootModel action**

In `RootModel.swift`, add to `// MARK: - View Helpers`:
```swift
  var canReimportSelectedTab: Bool { selectedTab?.canReimport ?? false }
```
and to `// MARK: - User Actions`:
```swift
  func reimportSelectedTabIgnoringCache() { selectedTab?.reimportIgnoringCacheTapped() }
```

- [ ] **Step 4: Run RootModel tests**

Run: `make test`
Expected: PASS.

#### 6b: SettingsModel cache section

- [ ] **Step 5: Write the failing Settings test**

Create/append `SettingsTests.swift`:
```swift
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor struct SettingsTests {
  @Test func onAppearReadsCacheSizeAndClearWipesIt() {
    let size = LockIsolated<Int64>(2_300_000_000)
    let cleared = LockIsolated(false)
    let model = withDependencies {
      $0.transcriptCache = TranscriptCacheClient(
        lookup: { _ in nil },
        store: { _, plan, url in CachedTranscription(editPlan: plan, canonicalAudioURL: url) },
        clear: { cleared.setValue(true); size.setValue(0) },
        totalSize: { size.value })
    } operation: { SettingsModel() }

    model.onAppear()
    #expect(model.canClearCache)
    #expect(model.cacheStatus.contains("2.3"))  // ByteCountFormatter, GB

    model.clearCacheTapped()
    #expect(cleared.value)
    #expect(!model.canClearCache)
  }
}
```

- [ ] **Step 6: Run to verify failure**

Run: `make test`
Expected: FAIL — `cacheStatus` / `canClearCache` / `clearCacheTapped` undefined.

- [ ] **Step 7: Extend `SettingsModel`**

Add to `SettingsModel.swift`:

Dependency (in `// MARK: - Dependencies`):
```swift
  @ObservationIgnored @Dependency(\.transcriptCache) var transcriptCache
```
Property (in `// MARK: - Properties`):
```swift
  private(set) var cacheSizeBytes: Int64 = 0
```
Display text:
```swift
  let cacheSectionTitle = "Transcription Cache"
  let clearCacheLabel = "Clear Cache"
```
View helpers:
```swift
  var canClearCache: Bool { cacheSizeBytes > 0 }
  var cacheStatus: String {
    guard cacheSizeBytes > 0 else { return "No cached transcripts." }
    let formatted = ByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .file)
    return "Cached transcripts use \(formatted). Re-importing an unchanged file is instant."
  }
```
Extend `onAppear` and add the clear action:
```swift
  func onAppear() {
    refreshStoredKeyState()
    cacheSizeBytes = transcriptCache.totalSize()
  }

  func clearCacheTapped() {
    do {
      try transcriptCache.clear()
      cacheSizeBytes = 0
      statusMessage = "Transcription cache cleared."
    } catch {
      statusMessage = "Could not clear the cache. Please try again."
      reportIssue(error)
    }
  }
```
(Remove the old standalone `onAppear` body — merge into the version above.)

- [ ] **Step 8: Add the cache section to `SettingsView`**

In `SettingsView.swift`, add a second `Section` after the API-key section:
```swift
      Section {
        Text(model.cacheStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
        Button(model.clearCacheLabel, role: .destructive) { model.clearCacheTapped() }
          .disabled(!model.canClearCache)
      } header: {
        Text(model.cacheSectionTitle)
      }
```

- [ ] **Step 9: Run Settings tests**

Run: `make test`
Expected: PASS.

#### 6c: File-menu command + App wiring

- [ ] **Step 10: Create `TranscriptionCommands`**

Create `Views/Commands/TranscriptionCommands.swift`:
```swift
import SwiftUI

/// File-menu commands for the transcription cache. Reads/acts through `RootModel`;
/// no logic lives here beyond binding the menu item to the model.
struct TranscriptionCommands: Commands {
  let root: RootModel

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Re-import (Ignore Cache)") { root.reimportSelectedTabIgnoringCache() }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(!root.canReimportSelectedTab)
    }
  }
}
```

- [ ] **Step 11: Wire it into the App scene**

In `QuickInterviewEditorApp.swift`, add `.commands` to the `WindowGroup`:
```swift
    WindowGroup {
      AppLaunchView(model: model)
        .preferredColorScheme(.dark)
    }
    .defaultSize(width: 1200, height: 800)
    .commands {
      TranscriptionCommands(root: model.root)
    }
```

- [ ] **Step 12: Build + full test run**

Run: `make generate && make test`
Expected: PASS. Manually confirm the app builds and the "Re-import (Ignore Cache)" item appears in the File menu (disabled until a tab is loaded), and the Settings window shows the cache size + Clear button.

- [ ] **Step 13: Format, lint, commit**

```bash
make format && make lint
git add QuickInterviewEditor/QuickInterviewEditor QuickInterviewEditor/QuickInterviewEditorTests \
        QuickInterviewEditor/QuickInterviewEditor.xcodeproj
git commit -m "feat(cache): re-import menu command + Settings clear/size controls"
```

---

## Self-Review

**Spec coverage:**
- Instant re-import of identical file → Tasks 2–5 (hit path, no subprocess). ✓
- Auto-invalidate on engine change → Task 1 (`EngineFingerprint`) folded into the key in Task 3. ✓
- Manual force-refresh → Task 5 (`reimportIgnoringCacheTapped`) + Task 6c (⌘⇧R menu). ✓
- Manual clear + visible growth → Task 6b (Settings size label + Clear). ✓
- `sha256`-only keying / bypass on `path:` → Task 3 + Task 4 bypass test. ✓
- Atomic store (no half-written hit) → Task 2 (temp dir + manifest-last + rename), tested by `lookupMissesWhenManifestIsAbsent`. ✓
- Cache owns its AIFF, not `CanonicalAudioStore` → Task 2 layout + doc comment; `CanonicalAudioStore.remove` guard already protects it. ✓
- Clean DI test story (mock `TranscriptionClient` high, `EngineClient` low) → Tasks 4–5. ✓

**Type consistency:** `CachePolicy` (Task 4) used identically in Tasks 5–6. `TranscriptCacheClient` signature (`lookup`/`store`/`clear`/`totalSize`) consistent across Tasks 2, 4, 6. `EngineFingerprintClient.current` used in Task 4 live + tests. `reimportIgnoringCacheTapped` / `canReimport` defined in Task 5, consumed in Task 6.

**Placeholders:** none — every step carries real code.

**Open follow-ups (out of scope, documented):**
- LRU / size-cap eviction (unbounded + labeled clear for v1).
- The engine still writes a throwaway `CanonicalAudioStore` copy on the miss/store path (harmless, pruned at launch); could be skipped later.
- "Clear cache while a tab holds an open cached AIFF" is documented, not guarded (explicit user action; open tabs keep working against their in-use file).

## Adversarial review gate (per repo convention)

This change touches real product logic across many files, so before opening a PR run the Codex adversarial pass (`/codex review` then `/codex challenge`) on the final diff and fix anything it surfaces, in addition to `make test` / `make lint`.
