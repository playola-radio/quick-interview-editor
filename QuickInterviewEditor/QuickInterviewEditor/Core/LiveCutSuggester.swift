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
    .appendingPathComponent("\(AppDirectories.folderName)/CutSuggestJobs/\(UUID().uuidString)")
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
    let dir = base.appendingPathComponent("\(AppDirectories.folderName)/CutSuggestCache")
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

  static func suggestCuts(_ request: CutSuggestRequest, apiKey: String?, runner: Runner = .live)
    -> AsyncThrowingStream<CutSuggestEvent, Error>
  {
    AsyncThrowingStream { continuation in
      let procBox = Mutex<ProcessHandle?>(nil)

      let task = Task {
        do {
          let launch = runner.resolveLaunch()
          let work = try runner.makeWorkDirectory()
          // The request JSON carries transcript text; remove the scratch dir on every
          // exit path (success, failure, cancel).
          defer { try? FileManager.default.removeItem(at: work) }

          let requestURL = work.appendingPathComponent("request.json")
          try writeRequest(request, to: requestURL)

          let args = arguments(
            for: request, requestURL: requestURL, cacheDirectory: runner.cacheDirectory)
          let proc = try runner.spawn(
            launch, launch.arguments(subcommand: "suggest", args),
            childEnvironment(base: launch.environment, apiKey: apiKey))
          procBox.withLock { $0 = proc }
          if Task.isCancelled { proc.terminate() }

          async let stdoutData = proc.readStdoutToEnd()
          async let exitCode = proc.waitForExit()

          var latestRevision = 0
          for await line in proc.stderrLines() {
            guard !Task.isCancelled else { break }
            if let event = progressEvent(line, request: request, latestRevision: &latestRevision) {
              continuation.yield(event)
            }
          }

          let out = await stdoutData
          let code = await exitCode

          try Task.checkCancellation()
          let events = try completedEvents(
            from: out, request: request, exitCode: code,
            stderr: proc.stderrTail(), latestRevision: latestRevision)
          try Task.checkCancellation()
          for event in events { continuation.yield(event) }
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

  private static func completedEvents(
    from out: Data, request: CutSuggestRequest,
    exitCode: Int32, stderr: String, latestRevision: Int
  ) throws -> [CutSuggestEvent] {
    if let snapshot = request.snapshot, !out.isEmpty {
      return try configuredCompletionEvents(
        from: out, snapshot: snapshot, exitCode: exitCode,
        stderr: stderr, latestRevision: latestRevision)
    }
    guard exitCode == 0 else { throw mapFailure(stderr: stderr) }
    guard request.snapshot == nil else {
      throw CutSuggestClientError.decodeFailed("The helper returned no result JSON.")
    }
    let payload = try CutSuggestion.decodeSuggestionPayload(
      from: out, provenance: provenance(for: request), makeID: { UUID() })
    var events: [CutSuggestEvent] = []
    if payload.suggestions.isEmpty, let meta = payload.meta {
      events.append(.diagnostic(meta.diagnosticDescription))
    }
    return events + [.completed(payload.suggestions)]
  }

  private static func configuredCompletionEvents(
    from out: Data, snapshot: SuggestionRunSnapshot,
    exitCode: Int32, stderr: String, latestRevision: Int
  ) throws -> [CutSuggestEvent] {
    let result = try SuggestionRunWireResult.decode(from: out, snapshot: snapshot)
    guard result.checkpointRevision >= latestRevision else {
      throw CutSuggestClientError.decodeFailed("Final result is older than the latest checkpoint.")
    }
    var events: [CutSuggestEvent] = []
    if result.checkpointRevision > latestRevision {
      events.append(.checkpoint(runID: snapshot.runID, revision: result.checkpointRevision))
    }
    if result.status == .needsRetry {
      return events + [
        .recoverableFailure(
          runID: snapshot.runID,
          failedRequestKeys: result.failedRequestKeys, message: result.failureMessage)
      ]
    }
    guard exitCode == 0 else { throw mapFailure(stderr: stderr) }
    if result.candidates.isEmpty, let meta = result.meta {
      events.append(.diagnostic(meta.diagnosticDescription))
    }
    return events + [.completed(result.candidates)]
  }

  private static func arguments(
    for request: CutSuggestRequest, requestURL: URL,
    cacheDirectory: @Sendable () -> URL?
  ) -> [String] {
    var args = ["--request", requestURL.path]
    if request.snapshot != nil {
      if let journal = request.journalDirectory { args += ["--journal-dir", journal.path] }
      if request.mode == .fresh { args.append("--refresh") }
    } else if let cache = cacheDirectory() {
      args += ["--cache-dir", cache.path]
    }
    return args
  }

  private static func progressEvent(
    _ line: String, request: CutSuggestRequest,
    latestRevision: inout Int
  ) -> CutSuggestEvent? {
    guard line.hasPrefix("QIE_EVENT "),
      let wire = try? JSONDecoder().decode(
        WireEvent.self,
        from: Data(line.dropFirst("QIE_EVENT ".count).utf8))
    else { return nil }
    if wire.type == "checkpoint", let runID = wire.runID,
      runID == request.snapshot?.runID, let revision = wire.revision, revision > latestRevision
    {
      latestRevision = revision
      return .checkpoint(runID: runID, revision: revision)
    }
    guard wire.type == "progress", let message = wire.message, !message.isEmpty else { return nil }
    return .progress(message)
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
    var runID: UUID?
    var revision: Int?
    enum CodingKeys: String, CodingKey {
      case type, message, revision
      case runID = "run_id"
    }
  }

  struct ProcessHandle: Sendable {
    var readStdoutToEnd: @Sendable () async -> Data
    var waitForExit: @Sendable () async -> Int32
    var stderrLines: @Sendable () -> AsyncStream<String>
    var stderrTail: @Sendable () -> String
    var terminate: @Sendable () -> Void
  }

  struct Runner: Sendable {
    var resolveLaunch: @Sendable () -> EngineLaunch
    var makeWorkDirectory: @Sendable () throws -> URL
    var cacheDirectory: @Sendable () -> URL?
    var spawn: @Sendable (EngineLaunch, [String], [String: String]) throws -> ProcessHandle

    static var live: Self {
      Self(
        resolveLaunch: { resolvedLaunch() }, makeWorkDirectory: { try makeWorkDir() },
        cacheDirectory: { LiveCutSuggester.cacheDirectory() },
        spawn: { launch, arguments, environment in
          guard FileManager.default.isExecutableFile(atPath: launch.executable.path) else {
            throw CutSuggestClientError.helperNotFound(launch.executable.path)
          }
          let process = try SpawnedProcess(
            executable: launch.executable, arguments: arguments,
            currentDirectory: launch.workingDirectory, extraEnvironment: environment)
          return ProcessHandle(
            readStdoutToEnd: { await process.readStdoutToEnd() },
            waitForExit: { await process.waitForExit() }, stderrLines: { process.stderrLines() },
            stderrTail: { process.stderrTail() }, terminate: { process.terminate() })
        })
    }
  }

  // MARK: Request encoding

  private static func writeRequest(_ request: CutSuggestRequest, to url: URL) throws {
    try encodedRequest(request).write(to: url)
  }

  /// The request as the snake-cased JSON the Python CLI reads. Exposed (not private)
  /// so the Swift→Python wire contract is unit-tested without spawning a subprocess.
  static func encodedRequest(_ request: CutSuggestRequest) throws -> Data {
    if let snapshot = request.snapshot {
      guard request.transcriptHash == snapshot.transcriptHash,
        request.sourceFingerprint == snapshot.sourceFingerprint,
        request.sampleRate == snapshot.sampleRate
      else { throw CutSuggestClientError.decodeFailed("Request does not match its run snapshot.") }
      return try JSONEncoder().encode(ConfiguredRequestWire(request: request, snapshot: snapshot))
    }
    return try JSONEncoder().encode(RequestWire(request))
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

private struct ConfiguredRequestWire: Encodable {
  var schemaVersion = 2
  var runID: UUID
  var mode: SuggestionSearchMode
  var transcriptHash: String
  var sourceFingerprint: String
  var transcriptUnits: [RequestWire.Unit]
  var interviewArtist: String?
  var configuration: SuggestionConfiguration
  var options: Options

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case runID = "run_id"
    case mode, configuration, options
    case transcriptHash = "transcript_hash"
    case sourceFingerprint = "source_fingerprint"
    case transcriptUnits = "transcript_units"
    case interviewArtist = "interview_artist"
  }

  init(request: CutSuggestRequest, snapshot: SuggestionRunSnapshot) {
    runID = snapshot.runID
    mode = request.mode
    transcriptHash = snapshot.transcriptHash
    sourceFingerprint = snapshot.sourceFingerprint
    transcriptUnits = request.transcriptUnits.map(RequestWire.Unit.init)
    interviewArtist = snapshot.interviewArtist
    configuration = snapshot.configuration
    options = Options(
      model: snapshot.model, sampleRate: snapshot.sampleRate,
      stage1Window: snapshot.stage1Window, stage1Step: snapshot.stage1Step,
      discoveryPromptVersion: snapshot.discoveryPromptVersion,
      extractionPromptVersion: snapshot.extractionPromptVersion,
      productSpecVersion: snapshot.productSpecVersion)
  }

  struct Options: Encodable {
    var model: String
    var sampleRate: Int
    var stage1Window: Int
    var stage1Step: Int
    var discoveryPromptVersion: String
    var extractionPromptVersion: String
    var productSpecVersion: String
    enum CodingKeys: String, CodingKey {
      case model
      case sampleRate = "sample_rate"
      case stage1Window = "stage1_window"
      case stage1Step = "stage1_step"
      case discoveryPromptVersion = "discovery_prompt_version"
      case extractionPromptVersion = "extraction_prompt_version"
      case productSpecVersion = "product_spec_version"
    }
  }
}
