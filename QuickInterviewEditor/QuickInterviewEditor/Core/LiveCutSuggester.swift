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
          let run = HelperRun(
            subcommand: "suggest", exitCode: code, stdout: out, stderr: proc.stderrTail(),
            apiKey: apiKey, logsDirectory: runner.logsDirectory)
          let events = try completedEvents(run, request: request, latestRevision: latestRevision)
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

  // MARK: nameClip

  static func nameClip(_ request: ClipNamingRequest, apiKey: String, runner: Runner = .live)
    async throws -> ClipNamingResult?
  {
    let procBox = Mutex<ProcessHandle?>(nil)
    return try await withTaskCancellationHandler {
      let launch = runner.resolveLaunch()
      let work = try runner.makeWorkDirectory()
      defer { try? FileManager.default.removeItem(at: work) }

      let requestURL = work.appendingPathComponent("request.json")
      try encodedNameClipRequest(request).write(to: requestURL)

      let proc = try runner.spawn(
        launch, launch.arguments(subcommand: "name-clip", ["--request", requestURL.path]),
        childEnvironment(base: launch.environment, apiKey: apiKey))
      procBox.withLock { $0 = proc }
      if Task.isCancelled { proc.terminate() }

      async let stdoutData = proc.readStdoutToEnd()
      async let exitCode = proc.waitForExit()
      for await _ in proc.stderrLines() {}
      let out = await stdoutData
      let code = await exitCode

      try Task.checkCancellation()
      let run = HelperRun(
        subcommand: "name-clip", exitCode: code, stdout: out, stderr: proc.stderrTail(),
        apiKey: apiKey, logsDirectory: runner.logsDirectory)
      guard code == 0 else { throw CutSuggestClientError.helperFailed(run.failure()) }
      do {
        return try decodeNameClipResult(from: out)
      } catch {
        throw run.unreadable(unreadableDetail(error))
      }
    } onCancel: {
      procBox.withLock { $0 }?.terminate()
    }
  }

  private static func decodeNameClipResult(from out: Data) throws -> ClipNamingResult? {
    let wire = try JSONDecoder().decode(ClipNamingResultWire.self, from: out)
    guard let typeID = wire.typeID else { return nil }
    return ClipNamingResult(typeID: typeID, fields: wire.fields)
  }

  private struct ClipNamingResultWire: Decodable {
    var typeID: String?
    var fields: [String: String?]
    enum CodingKeys: String, CodingKey {
      case typeID = "type_id"
      case fields
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
    _ run: HelperRun, request: CutSuggestRequest, latestRevision: Int
  ) throws -> [CutSuggestEvent] {
    if let snapshot = request.snapshot {
      return try configuredCompletionEvents(run, snapshot: snapshot, latestRevision: latestRevision)
    }
    guard run.exitCode == 0 else { throw CutSuggestClientError.helperFailed(run.failure()) }
    let payload: (suggestions: [CutSuggestion], meta: CutSuggestion.WireMeta?)
    do {
      payload = try CutSuggestion.decodeSuggestionPayload(
        from: run.stdout, provenance: provenance(for: request), makeID: { UUID() })
    } catch {
      throw run.unreadable(unreadableDetail(error))
    }
    var events: [CutSuggestEvent] = []
    if payload.suggestions.isEmpty, let meta = payload.meta {
      events.append(.diagnostic(meta.diagnosticDescription))
    }
    return events + [.completed(payload.suggestions)]
  }

  /// A V2 result is trusted only when its status agrees with the exit code: `ready` exits 0
  /// and `needs_retry` exits 1. Anything else — including a signal after printing — is a
  /// hard failure, as is output that can't be read.
  private static func configuredCompletionEvents(
    _ run: HelperRun, snapshot: SuggestionRunSnapshot, latestRevision: Int
  ) throws -> [CutSuggestEvent] {
    let result: SuggestionRunWireResult
    do {
      guard !run.stdout.isEmpty else {
        throw CutSuggestClientError.decodeFailed("The helper returned no result JSON.")
      }
      result = try SuggestionRunWireResult.decode(from: run.stdout, snapshot: snapshot)
    } catch {
      guard run.exitCode == 0 else { throw CutSuggestClientError.helperFailed(run.failure()) }
      throw run.unreadable(unreadableDetail(error))
    }
    switch (result.status, run.exitCode) {
    case (.ready, 0), (.needsRetry, 1): break
    default:
      throw CutSuggestClientError.exitMismatch(status: result.status.rawValue, run.failure())
    }
    guard result.checkpointRevision >= latestRevision else {
      throw run.unreadable(
        "Final result revision \(result.checkpointRevision) is older than checkpoint "
          + "\(latestRevision).")
    }
    var events: [CutSuggestEvent] = []
    if result.checkpointRevision > latestRevision {
      events.append(.checkpoint(runID: snapshot.runID, revision: result.checkpointRevision))
    }
    if result.status == .needsRetry {
      return events + [
        .recoverableFailure(
          runID: snapshot.runID,
          failedRequestKeys: result.failedRequestKeys, failures: result.failures)
      ]
    }
    if result.candidates.isEmpty, let meta = result.meta {
      events.append(.diagnostic(meta.diagnosticDescription))
    }
    return events + [.completed(result.candidates)]
  }

  private static func unreadableDetail(_ error: Error) -> String {
    if case .decodeFailed(let detail) = error as? CutSuggestClientError { return detail }
    switch error as? DecodingError {
    case .dataCorrupted(let context), .keyNotFound(_, let context),
      .typeMismatch(_, let context), .valueNotFound(_, let context):
      return context.debugDescription
    default:
      return error.localizedDescription
    }
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

  /// One finished helper run. A failure parses its stderr and writes a diagnostic log; the
  /// API key is scrubbed from both, and the environment is never recorded.
  private struct HelperRun {
    var subcommand: String
    var exitCode: Int32
    var stdout: Data
    var stderr: String
    var logsDirectory: @Sendable () -> URL?
    private var key: String

    init(
      subcommand: String, exitCode: Int32, stdout: Data, stderr: String, apiKey: String?,
      logsDirectory: @escaping @Sendable () -> URL?
    ) {
      self.subcommand = subcommand
      self.exitCode = exitCode
      self.stdout = stdout
      self.logsDirectory = logsDirectory
      key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      self.stderr = Self.redacting(key, in: stderr)
    }

    private static func redacting(_ key: String, in text: String) -> String {
      key.isEmpty ? text : text.replacingOccurrences(of: key, with: "[redacted]")
    }

    /// Call once per failure: each call writes a log.
    func failure(problem: String? = nil) -> HelperFailure {
      var failure = HelperFailure(exitCode: exitCode, stderr: stderr, logURL: nil)
      failure.logURL = HelperLog.write(
        logBody(failure.report, problem: problem), prefix: "cut-suggester", in: logsDirectory())
      return failure
    }

    func unreadable(_ detail: String) -> CutSuggestClientError {
      .unreadableOutput(detail, failure(problem: detail))
    }

    private func logBody(_ report: HelperErrorReport?, problem: String?) -> String {
      var lines = ["subcommand: \(subcommand)", "exit: \(exitCode)"]
      if let problem { lines.append("problem: \(problem)") }
      if let report {
        lines.append(
          "error: \(report.domain) \(report.operation) phase=\(report.phase ?? "none") "
            + "type=\(report.errorType)")
        lines.append("message: \(report.message)")
      }
      if let provider = report?.providerError {
        lines.append(
          "provider: category=\(provider.category.wireName) "
            + "status=\(provider.statusCode.map(String.init) ?? "none") "
            + "request=\(provider.requestID ?? "none") "
            + "retry_after=\(provider.retryAfter.map { "\($0)" } ?? "none") "
            + "retryable=\(provider.retryable)")
      }
      // swiftlint:disable:next optional_data_string_conversion
      let stdoutText = String(decoding: stdout, as: UTF8.self)
      return lines.joined(separator: "\n") + "\n\n"
        + HelperLog.streams(stdout: Data(Self.redacting(key, in: stdoutText).utf8), stderr: stderr)
    }
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
    var logsDirectory: @Sendable () -> URL?
    var spawn: @Sendable (EngineLaunch, [String], [String: String]) throws -> ProcessHandle

    static var live: Self {
      Self(
        resolveLaunch: { resolvedLaunch() }, makeWorkDirectory: { try makeWorkDir() },
        cacheDirectory: { LiveCutSuggester.cacheDirectory() },
        logsDirectory: { LiveEngine.logsDirectory },
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
      let mismatched = [
        request.transcriptHash == snapshot.transcriptHash ? nil : "transcript hash",
        request.sourceFingerprint == snapshot.sourceFingerprint ? nil : "source fingerprint",
        request.sampleRate == snapshot.sampleRate ? nil : "sample rate",
      ].compactMap { $0 }
      guard mismatched.isEmpty else {
        throw CutSuggestClientError.decodeFailed(
          "Request \(mismatched.joined(separator: ", ")) does not match its run snapshot.")
      }
      return try JSONEncoder().encode(ConfiguredRequestWire(request: request, snapshot: snapshot))
    }
    return try JSONEncoder().encode(RequestWire(request))
  }

  /// The `name-clip` request as the snake-cased JSON the Python CLI reads. Exposed (not
  /// private) so the wire contract is unit-tested without spawning a subprocess.
  static func encodedNameClipRequest(_ request: ClipNamingRequest) throws -> Data {
    try JSONEncoder().encode(ClipNamingRequestWire(request))
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

private struct ClipNamingRequestWire: Encodable {
  var schemaVersion = 1
  var model: String
  var configuration: SuggestionConfiguration
  var clip: Clip
  var transcriptUnits: [RequestWire.Unit]
  var interviewArtist: String?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case model, configuration, clip
    case transcriptUnits = "transcript_units"
    case interviewArtist = "interview_artist"
  }

  init(_ request: ClipNamingRequest) {
    model = request.model
    configuration = request.configuration
    clip = Clip(
      text: request.clipText, startSample: request.clipStartSample,
      endSample: request.clipEndSample)
    transcriptUnits = request.transcriptUnits.map(RequestWire.Unit.init)
    interviewArtist = request.interviewArtist
  }

  struct Clip: Encodable {
    var text: String
    var startSample: Int
    var endSample: Int
    enum CodingKeys: String, CodingKey {
      case text
      case startSample = "start_sample"
      case endSample = "end_sample"
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
