import Foundation
import Synchronization

// MARK: - LiveCutSuggester

/// Drives the Python `cut_suggester` CLI as a subprocess to turn a
/// ``CutSuggestRequest`` into ranked ``CutSuggestion``s. The live boundary of
/// ``CutSuggestClient``.
///
/// Mirrors ``LiveEngine`` (write a request file → spawn → stream `QIE_EVENT`
/// progress on stderr → decode a single JSON payload from stdout → cancel the whole
/// process group on teardown). The validated two-stage cutting logic and the
/// regression eval both live in Python, so this shells to them rather than
/// reimplementing the algorithm in Swift.
///
/// Auth: the model/provider come from `request.options`; the resolved API key arrives as
/// the `apiKey` argument (BYO Anthropic key from the Keychain, or the `ANTHROPIC_API_KEY`
/// env fallback — resolved upstream by the model) and is injected only into the child's
/// environment as `ANTHROPIC_API_KEY`. No credential is ever hardcoded, written to the
/// request file, passed on the command line, or logged.
/// - TODO(auth): the provider stays a knob (`request.options.model`); when a Playola
///   gateway replaces BYO keys, swap the resolved value at the call site — the injection
///   seam here (`extraEnvironment`) does not change.
enum LiveCutSuggester {

  // MARK: Launch resolution

  /// Resolves how to launch the cutter (bundled helper → dev `.venv`), reusing the
  /// same repo-root discovery the engine uses. See ``CutSuggesterResolver``.
  static func resolvedLaunch() -> EngineLaunch {
    CutSuggesterResolver.resolve(
      bundledHelper: bundledHelperURL,
      repoRootOverride: ProcessInfo.processInfo.environment["QIE_ENGINE_REPO"],
      filePathRepoRoot: filePathRepoRoot,
      isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) }
    )
  }

  /// The packaged cutter helper's expected location, or `nil` when there is no bundle
  /// resource URL. Not built yet (see ``CutSuggesterResolver``); the dev path runs today.
  private static var bundledHelperURL: URL? {
    Bundle.main.resourceURL?.appendingPathComponent("engine/cut-suggester-engine")
  }

  /// The `logic-utils` checkout inferred from `#filePath` (dev default). `#filePath` is
  /// `.../<repo>/QuickInterviewEditor/QuickInterviewEditor/Core/LiveCutSuggester.swift`,
  /// so four `deletingLastPathComponent()` calls land on the repo root.
  private static var filePathRepoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Core
      .deletingLastPathComponent()  // QuickInterviewEditor (inner)
      .deletingLastPathComponent()  // QuickInterviewEditor (outer)
      .deletingLastPathComponent()  // repo root
  }

  // MARK: Work & cache directories

  /// A fresh per-run scratch dir under Application Support. Holds only the request
  /// JSON (which contains transcript text) and is removed on every exit path so no
  /// interview content lingers on disk.
  private static func makeWorkDir() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    .appendingPathComponent("Quick Interview Editor/CutSuggestJobs/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  /// The app-owned response cache. `temperature:0` is not deterministic, so raw LLM
  /// responses are cached here (keyed by model / prompt / spec / window params in
  /// Python). It persists across runs — a re-suggest of the same transcript is free.
  ///
  /// The cache can contain transcript-derived text, so it lives in the app's own
  /// Application Support (not a shared tmp) and is lightly pruned to bound growth.
  /// Returns `nil` when Application Support is unavailable, in which case the run
  /// proceeds with no cache rather than failing.
  static func cacheDirectory() -> URL? {
    guard
      let base = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return nil }
    let dir = base.appendingPathComponent("Quick Interview Editor/CutSuggestCache")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    pruneCache(in: dir, keepingNewest: 1000)
    return dir
  }

  /// Bounds cache growth by keeping only the newest `keepingNewest` entries (by
  /// modification time). Recent interviews' responses survive; stale ones age out.
  private static func pruneCache(in dir: URL, keepingNewest: Int) {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    let files = entries.filter { $0.pathExtension == "json" }
    guard files.count > keepingNewest else { return }
    func modified(_ url: URL) -> Date {
      (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
    }
    let sorted = files.sorted { modified($0) > modified($1) }  // newest first
    for url in sorted.dropFirst(keepingNewest) {
      try? FileManager.default.removeItem(at: url)
    }
  }

  // MARK: suggestCuts

  // swiftlint:disable:next function_body_length
  static func suggestCuts(_ request: CutSuggestRequest, apiKey: String?)
    -> AsyncThrowingStream<CutSuggestEvent, Error>
  {
    AsyncThrowingStream { continuation in
      let procBox = Mutex<SpawnedProcess?>(nil)

      let task = Task {
        do {
          let launch = resolvedLaunch()
          guard FileManager.default.isExecutableFile(atPath: launch.executable.path) else {
            throw CutSuggestClientError.helperNotFound(launch.executable.path)
          }
          let work = try makeWorkDir()
          // The request JSON carries transcript text; remove the scratch dir on every
          // exit path (success, failure, cancel).
          defer { try? FileManager.default.removeItem(at: work) }

          let requestURL = work.appendingPathComponent("request.json")
          try writeRequest(request, to: requestURL)

          var args = ["--request", requestURL.path]
          if let cache = cacheDirectory() {
            args += ["--cache-dir", cache.path]
          }
          let proc = try SpawnedProcess(
            executable: launch.executable,
            arguments: launch.arguments(subcommand: "suggest", args),
            currentDirectory: launch.workingDirectory,
            extraEnvironment: childEnvironment(base: launch.environment, apiKey: apiKey)
          )
          procBox.withLock { $0 = proc }
          if Task.isCancelled { proc.terminate() }

          async let stdoutData = proc.readStdoutToEnd()
          async let exitCode = proc.waitForExit()

          for await line in proc.stderrLines() {
            guard line.hasPrefix("QIE_EVENT ") else { continue }
            let json = Data(line.dropFirst("QIE_EVENT ".count).utf8)
            guard
              let wire = try? JSONDecoder().decode(WireEvent.self, from: json),
              wire.type == "progress", let message = wire.message, !message.isEmpty
            else { continue }
            continuation.yield(.progress(message))
          }

          let out = await stdoutData
          let code = await exitCode

          if Task.isCancelled {
            continuation.finish()
            return
          }
          guard code == 0 else {
            throw mapFailure(stderr: proc.stderrTail())
          }
          let provenance = provenance(for: request)
          let suggestions = try CutSuggestion.decodeSuggestions(
            from: out, provenance: provenance, makeID: { UUID() })
          continuation.yield(.completed(suggestions))
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
        procBox.withLock { $0 }?.terminate()
      }
    }
  }

  /// The child's environment: the launch base plus the resolved credential injected as
  /// `ANTHROPIC_API_KEY` (only here — never argv, visible in `ps`, nor the on-disk request
  /// file). A whitespace-only key is treated as absent so the provider returns a clean auth
  /// error rather than a malformed header.
  private static func childEnvironment(base: [String: String], apiKey: String?)
    -> [String: String]
  {
    var environment = base
    if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
      environment[anthropicAPIKeyEnvVar] = apiKey
    }
    return environment
  }

  /// The provenance stamped onto each produced suggestion. The `CutSuggestionsPageModel`
  /// re-stamps this identically from the request; building it here keeps the client
  /// correct even if used directly.
  private static func provenance(for request: CutSuggestRequest) -> CutSuggestion.Provenance {
    CutSuggestion.Provenance(
      model: request.options.model,
      promptVersion: request.options.promptVersion,
      productSpecVersion: request.options.productSpecVersion,
      transcriptHash: request.transcriptHash,
      sourceFingerprint: request.sourceFingerprint,
      diarizationHash: request.diarization?.diarizationHash)
  }

  /// Classifies a nonzero-exit failure from the helper's stderr tail. A missing
  /// credential is called out distinctly so the UI can prompt for auth instead of
  /// showing a generic failure.
  private static func mapFailure(stderr: String) -> CutSuggestClientError {
    // The QIE_EVENT progress lines share this stream and carry free-form message
    // text + counts (a partition index or candidate count could contain "401"), so
    // they must not drive the classification — match only the non-progress lines.
    let lowered =
      stderr
      .split(separator: "\n", omittingEmptySubsequences: true)
      .filter { !$0.hasPrefix("QIE_EVENT ") }
      .joined(separator: "\n")
      .lowercased()
    let authSignals = [
      "openai_key", "anthropic_api_key", "api key", "api_key", "authentication",
      "unauthorized", "credential",
    ]
    // Bounded match for the bare status code so an unrelated "401" substring
    // (a sample index, a byte count) doesn't misclassify a genuine failure.
    let statusUnauthorized = lowered.range(of: #"\b401\b"#, options: .regularExpression) != nil
    if statusUnauthorized || authSignals.contains(where: lowered.contains) {
      return .authMissing(stderr)
    }
    return .suggestFailed(stderr)
  }

  private struct WireEvent: Decodable {
    var type: String
    var message: String?
  }

  // MARK: Request encoding

  private static func writeRequest(_ request: CutSuggestRequest, to url: URL) throws {
    try encodedRequest(request).write(to: url)
  }

  /// The request as the snake-cased JSON the Python CLI reads. Exposed (not private)
  /// so the Swift→Python wire contract is unit-tested without spawning a subprocess.
  static func encodedRequest(_ request: CutSuggestRequest) throws -> Data {
    try JSONEncoder().encode(RequestWire(request))
  }
}

// MARK: - Request wire types

/// The snake-cased request the app writes for `cut_suggester.cli suggest`. Mirrors the
/// contract documented in `cut_suggester/cli.py`.
private struct RequestWire: Encodable {
  var transcriptUnits: [Unit]
  var productSpecs: [Spec]
  var options: Options
  var diarization: Diarization?

  enum CodingKeys: String, CodingKey {
    case transcriptUnits = "transcript_units"
    case productSpecs = "product_specs"
    case options
    case diarization
  }

  init(_ request: CutSuggestRequest) {
    self.transcriptUnits = request.transcriptUnits.map(Unit.init)
    self.productSpecs = request.productSpecs.map(Spec.init)
    self.options = Options(request.options, sampleRate: request.sampleRate)
    self.diarization = request.diarization.map { Diarization(diarizationHash: $0.diarizationHash) }
  }

  struct Unit: Encodable {
    var id: Int
    var text: String
    var wordIDs: [Int]
    var startSample: Int
    var endSample: Int
    var startSec: Double
    var endSec: Double
    var speakerID: String?

    enum CodingKeys: String, CodingKey {
      case id, text
      case wordIDs = "word_ids"
      case startSample = "start_sample"
      case endSample = "end_sample"
      case startSec = "start_sec"
      case endSec = "end_sec"
      case speakerID = "speaker_id"
    }

    init(_ unit: TranscriptUnit) {
      self.id = unit.id
      self.text = unit.text
      self.wordIDs = unit.wordIDs
      self.startSample = unit.startSample
      self.endSample = unit.endSample
      self.startSec = unit.startSec
      self.endSec = unit.endSec
      self.speakerID = unit.speakerID
    }
  }

  struct Spec: Encodable {
    var productType: String
    var targetMinSec: Double
    var targetMaxSec: Double
    var hardMinSec: Double
    var hardMaxSec: Double
    var description: String

    enum CodingKeys: String, CodingKey {
      case productType = "product_type"
      case targetMinSec = "target_min_sec"
      case targetMaxSec = "target_max_sec"
      case hardMinSec = "hard_min_sec"
      case hardMaxSec = "hard_max_sec"
      case description
    }

    init(_ spec: ProductSpec) {
      self.productType = spec.productType.rawValue
      self.targetMinSec = spec.targetMinSec
      self.targetMaxSec = spec.targetMaxSec
      self.hardMinSec = spec.hardMinSec
      self.hardMaxSec = spec.hardMaxSec
      self.description = spec.description
    }
  }

  struct Options: Encodable {
    var model: String
    var promptVersion: String
    var productSpecVersion: String
    var stage1Window: Int
    var stage1Step: Int
    var sampleRate: Int

    enum CodingKeys: String, CodingKey {
      case model
      case promptVersion = "prompt_version"
      case productSpecVersion = "product_spec_version"
      case stage1Window = "stage1_window"
      case stage1Step = "stage1_step"
      case sampleRate = "sample_rate"
    }

    init(_ options: CutSuggestOptions, sampleRate: Int) {
      self.model = options.model
      self.promptVersion = options.promptVersion
      self.productSpecVersion = options.productSpecVersion
      self.stage1Window = options.stage1Window
      self.stage1Step = options.stage1Step
      self.sampleRate = sampleRate
    }
  }

  struct Diarization: Encodable {
    var diarizationHash: String
    enum CodingKeys: String, CodingKey {
      case diarizationHash = "diarization_hash"
    }
  }
}
