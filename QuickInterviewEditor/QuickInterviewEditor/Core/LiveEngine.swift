import Foundation
import Synchronization

// MARK: - LiveEngine

/// Drives the Python `logic_markers` CLI as a subprocess to transcribe an audio
/// file into an ``EditPlan``.
///
/// DEV ONLY: this resolves a `.venv` inside the `logic-utils` checkout. The
/// notarized, bundled helper is roadmap Phase 1. Override the repo location with
/// the `QIE_ENGINE_REPO` environment variable.
enum LiveEngine {

  // MARK: Dev engine resolution

  /// The `logic-utils` checkout that contains the Python engine and its `.venv`.
  ///
  /// `#filePath` is `.../<repo>/QuickInterviewEditor/QuickInterviewEditor/Core/LiveEngine.swift`,
  /// so four `deletingLastPathComponent()` calls (Core → QuickInterviewEditor →
  /// QuickInterviewEditor → <repo>) land on the repo root.
  private static var repoRoot: URL {
    if let path = ProcessInfo.processInfo.environment["QIE_ENGINE_REPO"] {
      return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Core
      .deletingLastPathComponent()  // QuickInterviewEditor (inner)
      .deletingLastPathComponent()  // QuickInterviewEditor (outer)
      .deletingLastPathComponent()  // repo root
  }

  private static var pythonURL: URL {
    repoRoot.appendingPathComponent(".venv/bin/python")
  }

  // MARK: Work directory

  /// Creates a fresh per-job scratch directory under Application Support (never
  /// beside the user's audio file).
  private static func makeWorkDir() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    .appendingPathComponent("Quick Interview Editor/Jobs/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  // MARK: Logging

  /// Where per-run engine logs land (Application Support/…/Logs), for QA/inspection.
  static var logsDirectory: URL? {
    guard
      let base = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return nil }
    let dir = base.appendingPathComponent("Quick Interview Editor/Logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Writes a per-run log (command, exit code, full stdout, stderr tail) and
  /// returns its URL so error messages can point the user at it. Returns nil if
  /// the write fails, so error messages never point at a path that isn't there.
  private static func writeJobLog(
    kind: String, audio: URL, exitCode: Int32, stdout: Data, stderr: String
  ) -> URL? {
    guard let dir = logsDirectory else { return nil }
    pruneOldLogs(in: dir, prefix: "\(kind)-", keepingLast: 20)
    let file = dir.appendingPathComponent("\(kind)-\(logTimestamp()).log")
    // `String(decoding:as:)` substitutes U+FFFD for any invalid byte rather than
    // yielding nil, so a stray non-UTF-8 byte can't blank the whole log body.
    // swiftlint:disable:next optional_data_string_conversion
    let stdoutText = String(decoding: stdout, as: UTF8.self)
    let body = """
      audio: \(audio.path)
      exit: \(exitCode)

      ===== STDOUT (\(stdout.count) bytes) =====
      \(stdoutText)

      ===== STDERR (tail) =====
      \(stderr)
      """
    guard (try? body.write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
    return file
  }

  /// Keeps only the most recent `keepingLast` `transcribe-*.log` files. Logs hold
  /// transcribed speech, so they shouldn't accumulate on disk unbounded. The
  /// timestamped names sort chronologically, so lexical order is chronological.
  private static func pruneOldLogs(in dir: URL, prefix: String, keepingLast: Int) {
    guard
      let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    else { return }
    let logs = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".log") }.sorted()
    guard logs.count > keepingLast else { return }
    for name in logs.dropLast(keepingLast) {
      try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
  }

  private static func logHint(_ url: URL?) -> String {
    guard let url else { return "" }
    return "\n\nFull engine log: \(url.path)"
  }

  private static func logTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return formatter.string(from: Date())
  }

  // MARK: transcribe

  // swiftlint:disable:next function_body_length
  static func transcribe(audio: URL) -> AsyncThrowingStream<EngineEvent, Error> {
    AsyncThrowingStream { continuation in
      // Published so `onTermination` can kill the process group directly; merely
      // cancelling the Task would not interrupt the blocking waitpid/read.
      let procBox = Mutex<SpawnedProcess?>(nil)

      let task = Task {
        do {
          guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            throw EngineClientError.engineNotFound(pythonURL.path)
          }
          let work = try makeWorkDir()
          // Remove the scratch dir (cached AIFF + transcript JSON, both derived
          // from the user's audio) on every exit path — success, failure, cancel.
          defer { try? FileManager.default.removeItem(at: work) }
          let proc = try SpawnedProcess(
            executable: pythonURL,
            arguments: [
              "-m", "logic_markers.cli", "plan", audio.path,
              "--work-dir", work.path, "--sample-rate", "44100",
            ],
            currentDirectory: repoRoot
          )
          procBox.withLock { $0 = proc }
          // If cancellation landed before the process was published, kill now.
          if Task.isCancelled { proc.terminate() }

          // Drain stdout and reap the child concurrently with the stderr loop.
          // Draining stdout in parallel keeps a full stdout pipe buffer from
          // stalling the child while we read stderr. Reaping in parallel means we
          // don't gate `waitpid` behind stdout/stderr EOF — if a grandchild
          // inherits a pipe and lingers, the child is still reaped the moment it
          // exits, so it never becomes a zombie.
          async let stdoutData = proc.readStdoutToEnd()
          async let exitCode = proc.waitForExit()

          for await line in proc.stderrLines() {
            guard line.hasPrefix("QIE_EVENT ") else { continue }
            let json = Data(line.dropFirst("QIE_EVENT ".count).utf8)
            guard
              let wire = try? JSONDecoder().decode(WireEvent.self, from: json),
              wire.type == "progress",
              let phaseRaw = wire.phase,
              let phase = EngineProgress.Phase(rawValue: phaseRaw)
            else { continue }
            continuation.yield(
              .progress(EngineProgress(phase: phase, message: wire.message ?? ""))
            )
          }

          let out = await stdoutData
          let code = await exitCode

          // Persist a per-run log (command, exit, full stdout, stderr tail) so any
          // transcription is inspectable after the fact.
          let logURL = writeJobLog(
            kind: "transcribe", audio: audio, exitCode: code, stdout: out, stderr: proc.stderrTail()
          )

          if Task.isCancelled {
            continuation.finish()
            return
          }
          guard code == 0 else {
            throw EngineClientError.engineFailed(proc.stderrTail() + logHint(logURL))
          }
          do {
            let plan = try JSONDecoder().decode(EditPlan.self, from: out)
            continuation.yield(.completed(plan))
            continuation.finish()
          } catch {
            // Include a preview of what the engine actually emitted — a decode
            // failure almost always means non-JSON leaked onto stdout.
            // swiftlint:disable:next optional_data_string_conversion
            let preview = String(decoding: out.prefix(500), as: UTF8.self)
            throw EngineClientError.decodeFailed(
              "\(error)\n\nEngine output was not valid JSON. It began with:\n\(preview)"
                + logHint(logURL))
          }
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

  private struct WireEvent: Decodable {
    var type: String
    var phase: String?
    var message: String?
  }

  // MARK: render

  // swiftlint:disable function_body_length
  /// Renders the request's slices to app-owned temp AIFFs (one per slice id) by
  /// driving `logic_markers.cli render`. Mirrors `transcribe` (streaming progress,
  /// process-group cancel), with one difference: on **success** the work-dir is
  /// left in place because the caller (EditorModel) copies the AIFFs to the user's
  /// folder and deletes the work-dir afterward. On failure/cancel it's removed here.
  static func render(_ request: RenderRequest) -> AsyncThrowingStream<RenderEvent, Error> {
    AsyncThrowingStream { continuation in
      let procBox = Mutex<SpawnedProcess?>(nil)

      let task = Task {
        var succeeded = false
        do {
          guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            throw EngineClientError.engineNotFound(pythonURL.path)
          }
          let work = try makeWorkDir()
          // Keep the rendered AIFFs on success (the caller copies + cleans up);
          // remove the scratch dir on every failure/cancel path.
          defer { if !succeeded { try? FileManager.default.removeItem(at: work) } }

          let requestURL = work.appendingPathComponent("request.json")
          try writeRequest(request, to: requestURL)

          let proc = try SpawnedProcess(
            executable: pythonURL,
            arguments: [
              "-m", "logic_markers.cli", "render", request.sourceURL.path,
              "--request", requestURL.path, "--work-dir", work.path,
              "--sample-rate", String(request.sampleRate),
            ],
            currentDirectory: repoRoot
          )
          procBox.withLock { $0 = proc }
          if Task.isCancelled { proc.terminate() }

          async let stdoutData = proc.readStdoutToEnd()
          async let exitCode = proc.waitForExit()

          for await line in proc.stderrLines() {
            guard line.hasPrefix("QIE_EVENT ") else { continue }
            let json = Data(line.dropFirst("QIE_EVENT ".count).utf8)
            guard
              let wire = try? JSONDecoder().decode(RenderWireEvent.self, from: json),
              wire.type == "progress"
            else { continue }
            continuation.yield(
              .progress(
                RenderProgress(
                  message: wire.message ?? "", index: wire.index ?? 0, total: wire.total ?? 0)))
          }

          let out = await stdoutData
          let code = await exitCode
          let logURL = writeJobLog(
            kind: "render", audio: request.sourceURL, exitCode: code, stdout: out,
            stderr: proc.stderrTail())

          if Task.isCancelled {
            continuation.finish()
            return
          }
          guard code == 0 else {
            throw EngineClientError.renderFailed(proc.stderrTail() + logHint(logURL))
          }
          let slices = try decodeRenderResult(out, workDir: work, logURL: logURL)
          succeeded = true
          continuation.yield(.completed(RenderResult(slices: slices, workDir: work)))
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
  // swiftlint:enable function_body_length

  private static func writeRequest(_ request: RenderRequest, to url: URL) throws {
    let wire = RenderWireRequest(
      sampleRate: request.sampleRate,
      markers: request.markers.map {
        RenderWireRequest.Marker(position: $0.position, name: $0.name)
      },
      slices: request.slices.map {
        RenderWireRequest.Slice(
          id: $0.id.uuidString, startSample: $0.startSample, endSample: $0.endSample)
      }
    )
    try JSONEncoder().encode(wire).write(to: url)
  }

  /// Decodes the engine's result into `RenderedSlice`s. The engine's `path` field is
  /// **ignored** — each output URL is derived from our own `workDir` and the returned
  /// id (validated as a UUID), so a malformed/hostile result can never point the copy
  /// at a file outside the scratch dir. The derived file must exist on disk.
  private static func decodeRenderResult(
    _ out: Data, workDir: URL, logURL: URL?
  ) throws -> [RenderedSlice] {
    do {
      let wire = try JSONDecoder().decode(RenderWireResult.self, from: out)
      return try wire.slices.map { slice in
        guard let id = UUID(uuidString: slice.id) else {
          throw EngineClientError.renderDecodeFailed(
            "engine returned an unrecognized slice id: \(slice.id)")
        }
        let url = workDir.appendingPathComponent("\(id.uuidString).aiff")
        guard FileManager.default.fileExists(atPath: url.path) else {
          throw EngineClientError.renderDecodeFailed(
            "engine did not produce the expected file for slice \(id.uuidString)")
        }
        return RenderedSlice(id: id, url: url)
      }
    } catch let error as EngineClientError {
      throw error
    } catch {
      // swiftlint:disable:next optional_data_string_conversion
      let preview = String(decoding: out.prefix(500), as: UTF8.self)
      throw EngineClientError.renderDecodeFailed(
        "\(error)\n\nEngine output was not valid JSON. It began with:\n\(preview)" + logHint(logURL)
      )
    }
  }

}

// MARK: - Render wire types

/// Snake-cased JSON shapes exchanged with `logic_markers.cli render` — the request
/// file Swift writes and the result/progress it reads back.
private struct RenderWireRequest: Encodable {
  var sampleRate: Int
  var markers: [Marker]
  var slices: [Slice]
  enum CodingKeys: String, CodingKey {
    case sampleRate = "sample_rate"
    case markers, slices
  }
  struct Marker: Encodable {
    var position: Int
    var name: String
  }
  struct Slice: Encodable {
    var id: String
    var startSample: Int
    var endSample: Int
    enum CodingKeys: String, CodingKey {
      case id
      case startSample = "start_sample"
      case endSample = "end_sample"
    }
  }
}

private struct RenderWireResult: Decodable {
  struct Slice: Decodable {
    var id: String
    var path: String
  }
  var slices: [Slice]
}

private struct RenderWireEvent: Decodable {
  var type: String
  var phase: String?
  var message: String?
  var index: Int?
  var total: Int?
}

// MARK: - SpawnedProcess

/// A minimal `posix_spawn` wrapper that runs a child in its **own process
/// group** so the whole tree (e.g. `afconvert`, model downloads) can be signalled
/// together.
///
/// `Foundation.Process` offers no clean API to place a child in a new process
/// group, so we drop to `posix_spawn` with `POSIX_SPAWN_SETPGROUP` (pgid 0 makes
/// the child its own group leader). On cancel/deinit we `kill(-pid, SIGTERM)` the
/// whole group, then `SIGKILL` after a short grace, and always drain/close the
/// pipes so shutdown can't deadlock.
final class SpawnedProcess: Sendable {

  /// Read ends of the child's stdout/stderr pipes. Raw POSIX fds are trivially
  /// `Sendable`; each is owned (read to EOF, then closed) by exactly one reader.
  private let stdoutReadFD: Int32
  private let stderrReadFD: Int32

  /// Rolling tail of stderr (for `engineFailed` messages).
  private let stderrCollector = StderrTail()

  /// Guards one-shot teardown so terminate/deinit are idempotent.
  private let didTerminate = Mutex(false)
  /// Coordinates reap-vs-signal atomically. A shared reference so background
  /// closures capture *it* — never `self`, which may be mid-`deinit` when the
  /// delayed SIGKILL is scheduled.
  private let reaper: ChildReaper

  // A posix_spawn wrapper is inherently a long, branchy linear sequence (pipe
  // setup, CLOEXEC, attr/file-action config, per-step error cleanup). Splitting
  // it hurts the fd-cleanup correctness that was carefully reviewed, so keep it
  // whole and suppress the length/complexity rules here.
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  init(executable: URL, arguments: [String], currentDirectory: URL) throws {
    // Create pipes with raw fds so nothing crosses concurrency domains as a
    // non-Sendable FileHandle, and closing is a plain `close(fd)`.
    var outFDs: [Int32] = [-1, -1]  // [read, write]
    var errFDs: [Int32] = [-1, -1]
    guard pipe(&outFDs) == 0 else {
      throw EngineClientError.engineFailed(
        "pipe() failed (\(errno): \(String(cString: strerror(errno))))")
    }
    guard pipe(&errFDs) == 0 else {
      // Don't leak the first pipe if the second fails.
      close(outFDs[0])
      close(outFDs[1])
      throw EngineClientError.engineFailed(
        "pipe() failed (\(errno): \(String(cString: strerror(errno))))")
    }
    let outReadFD = outFDs[0]
    let outWriteFD = outFDs[1]
    let errReadFD = errFDs[0]
    let errWriteFD = errFDs[1]

    // The app can run multiple transcriptions concurrently (one per open tab), so
    // two `posix_spawn` calls can race in the same process. These pipe fds are not
    // close-on-exec by default, so a *different* tab's spawn could inherit our
    // write ends and hold them open, and our reader would never see EOF. Setting
    // FD_CLOEXEC here makes any other spawn/exec drop them automatically; our own
    // intended child still gets working stdin/stdout/stderr because those are
    // delivered via `posix_spawn_file_actions_adddup2` below, whose dup2'd target
    // fd does not inherit FD_CLOEXEC. The whole concurrent-spawn safety story rests
    // on this taking effect, so a failed fcntl must not slip through silently.
    for fd in [outReadFD, outWriteFD, errReadFD, errWriteFD] {
      guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else {
        let err = errno
        close(outReadFD)
        close(outWriteFD)
        close(errReadFD)
        close(errWriteFD)
        throw EngineClientError.engineFailed(
          "fcntl(F_SETFD, FD_CLOEXEC) failed (\(err): \(String(cString: strerror(err))))")
      }
    }

    // These import into Swift as optional opaque pointers; init allocates. Every
    // configuration call's return code is checked: the cancellation-safety model
    // depends on POSIX_SPAWN_SETPGROUP actually taking effect (see class doc), so
    // a silently-ignored ENOMEM/EINVAL here must not be allowed to slip through.
    var attr: posix_spawnattr_t?
    var attrInitialized = false
    func destroyAttrIfNeeded() {
      if attrInitialized { posix_spawnattr_destroy(&attr) }
    }
    var rc = posix_spawnattr_init(&attr)
    guard rc == 0 else {
      close(outReadFD)
      close(outWriteFD)
      close(errReadFD)
      close(errWriteFD)
      throw EngineClientError.engineFailed(
        "posix_spawnattr_init failed (\(rc): \(String(cString: strerror(rc))))")
    }
    attrInitialized = true

    // Child becomes leader of a new process group (pgid 0 ⇒ pgid = child pid).
    rc = posix_spawnattr_setpgroup(&attr, 0)
    guard rc == 0 else {
      destroyAttrIfNeeded()
      close(outReadFD)
      close(outWriteFD)
      close(errReadFD)
      close(errWriteFD)
      throw EngineClientError.engineFailed(
        "posix_spawnattr_setpgroup failed (\(rc): \(String(cString: strerror(rc))))")
    }
    rc = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    guard rc == 0 else {
      destroyAttrIfNeeded()
      close(outReadFD)
      close(outWriteFD)
      close(errReadFD)
      close(errWriteFD)
      throw EngineClientError.engineFailed(
        "posix_spawnattr_setflags failed (\(rc): \(String(cString: strerror(rc))))")
    }

    var fileActions: posix_spawn_file_actions_t?
    var fileActionsInitialized = false
    func destroyFileActionsIfNeeded() {
      if fileActionsInitialized { posix_spawn_file_actions_destroy(&fileActions) }
    }
    rc = posix_spawn_file_actions_init(&fileActions)
    guard rc == 0 else {
      destroyAttrIfNeeded()
      close(outReadFD)
      close(outWriteFD)
      close(errReadFD)
      close(errWriteFD)
      throw EngineClientError.engineFailed(
        "posix_spawn_file_actions_init failed (\(rc): \(String(cString: strerror(rc))))")
    }
    fileActionsInitialized = true

    let devNullFD = open("/dev/null", O_RDONLY)
    // stdin ← /dev/null so the child never blocks waiting on input.
    if devNullFD >= 0 {
      rc = posix_spawn_file_actions_adddup2(&fileActions, devNullFD, STDIN_FILENO)
      if rc == 0 {
        rc = posix_spawn_file_actions_addclose(&fileActions, devNullFD)
      }
      guard rc == 0 else {
        close(devNullFD)
        destroyFileActionsIfNeeded()
        destroyAttrIfNeeded()
        close(outReadFD)
        close(outWriteFD)
        close(errReadFD)
        close(errWriteFD)
        throw EngineClientError.engineFailed(
          "posix_spawn_file_actions failed configuring stdin (\(rc): \(String(cString: strerror(rc))))"
        )
      }
    }
    rc = posix_spawn_file_actions_adddup2(&fileActions, outWriteFD, STDOUT_FILENO)
    if rc == 0 {
      rc = posix_spawn_file_actions_adddup2(&fileActions, errWriteFD, STDERR_FILENO)
    }
    // The child inherits only the dup2'd descriptors; close every raw pipe fd it
    // would otherwise inherit (both read and write ends).
    if rc == 0 {
      rc = posix_spawn_file_actions_addclose(&fileActions, outWriteFD)
    }
    if rc == 0 {
      rc = posix_spawn_file_actions_addclose(&fileActions, errWriteFD)
    }
    if rc == 0 {
      rc = posix_spawn_file_actions_addclose(&fileActions, outReadFD)
    }
    if rc == 0 {
      rc = posix_spawn_file_actions_addclose(&fileActions, errReadFD)
    }
    guard rc == 0 else {
      if devNullFD >= 0 { close(devNullFD) }
      destroyFileActionsIfNeeded()
      destroyAttrIfNeeded()
      close(outReadFD)
      close(outWriteFD)
      close(errReadFD)
      close(errWriteFD)
      throw EngineClientError.engineFailed(
        "posix_spawn_file_actions failed configuring stdout/stderr (\(rc): \(String(cString: strerror(rc))))"
      )
    }

    // argv[0] is the executable path by convention.
    let argv = [executable.path] + arguments
    let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    defer { for ptr in cArgv where ptr != nil { free(ptr) } }

    // `python -m logic_markers.cli` resolves the package from `sys.path`. Rather
    // than chdir the child (the non-deprecated file action is macOS 26+ only),
    // prepend the repo root to PYTHONPATH so the module is found regardless of
    // the inherited working directory.
    let childEnv = Self.environment(prependingPythonPath: currentDirectory.path)
    let cEnv: [UnsafeMutablePointer<CChar>?] = childEnv.map { strdup($0) } + [nil]
    defer { for ptr in cEnv where ptr != nil { free(ptr) } }

    var spawnedPID: pid_t = 0
    rc = posix_spawn(&spawnedPID, executable.path, &fileActions, &attr, cArgv, cEnv)

    // posix_spawn has consumed attr/fileActions; free them on both paths. (The
    // earlier configuration-failure guards already destroyed + threw, so no path
    // reaching here has run these helpers yet — no double-free.)
    destroyFileActionsIfNeeded()
    destroyAttrIfNeeded()

    // The parent never writes the child's stdout/stderr, nor uses /dev/null.
    if devNullFD >= 0 { close(devNullFD) }
    close(outWriteFD)
    close(errWriteFD)

    guard rc == 0 else {
      close(outReadFD)
      close(errReadFD)
      throw EngineClientError.engineFailed(
        "posix_spawn failed (\(rc): \(String(cString: strerror(rc))))")
    }

    self.stdoutReadFD = outReadFD
    self.stderrReadFD = errReadFD
    self.reaper = ChildReaper(pid: spawnedPID)
  }

  // MARK: Environment

  /// The parent environment as `KEY=VALUE` strings, with `path` prepended to
  /// `PYTHONPATH` so `python -m logic_markers.cli` finds the package.
  private static func environment(prependingPythonPath path: String) -> [String] {
    var env = ProcessInfo.processInfo.environment
    if let existing = env["PYTHONPATH"], !existing.isEmpty {
      env["PYTHONPATH"] = path + ":" + existing
    } else {
      env["PYTHONPATH"] = path
    }
    return env.map { "\($0.key)=\($0.value)" }
  }

  // MARK: Reads

  /// Reads stdout to EOF, then closes the fd. Runs on a background queue so it can
  /// proceed concurrently with `stderrLines()`; a SIGKILL delivers EOF here, so a
  /// hung child can never park this read indefinitely.
  func readStdoutToEnd() async -> Data {
    let fd = stdoutReadFD
    return await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        let data = Self.readToEOF(fd)
        close(fd)
        continuation.resume(returning: data)
      }
    }
  }

  /// Yields stderr line-by-line (newline-delimited, UTF-8), recording each line
  /// into the rolling tail as it goes. Closes the fd at EOF.
  func stderrLines() -> AsyncStream<String> {
    let fd = stderrReadFD
    let collector = stderrCollector
    return AsyncStream { continuation in
      DispatchQueue.global().async {
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = scratch.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
          if count < 0 && errno == EINTR { continue }
          if count <= 0 { break }
          buffer.append(contentsOf: scratch[0..<count])
          while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            let line = String(bytes: lineData, encoding: .utf8) ?? ""
            collector.append(line)
            continuation.yield(line)
          }
        }
        if !buffer.isEmpty {
          let line = String(bytes: buffer, encoding: .utf8) ?? ""
          collector.append(line)
          continuation.yield(line)
        }
        close(fd)
        continuation.finish()
      }
    }
  }

  private static func readToEOF(_ fd: Int32) -> Data {
    var out = Data()
    var scratch = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = scratch.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      if count <= 0 { break }
      out.append(contentsOf: scratch[0..<count])
    }
    return out
  }

  // MARK: Wait / status

  /// Reaps the child and returns its exit code (a signal-terminated child reports
  /// `128 + signal`, which is nonzero). Polls `reaper.tryReap()`, whose `waitpid`
  /// runs under the same lock as signaling, so the reap can't race a `kill` onto a
  /// reused pid. The 20 ms poll interval keeps this off a busy-wait while adding
  /// negligible latency to a multi-second transcription.
  func waitForExit() async -> Int32 {
    let reaper = reaper
    return await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        while true {
          if let code = reaper.tryReap() {
            continuation.resume(returning: code)
            return
          }
          usleep(20_000)
        }
      }
    }
  }

  func stderrTail() -> String {
    stderrCollector.snapshot()
  }

  // MARK: Termination

  /// SIGTERMs the whole process group, then SIGKILLs it after a short grace.
  ///
  /// It never reaps (that is `waitForExit()`'s job, so there is no double-`waitpid`)
  /// and never touches the read fds (so there is no concurrent-close race with the
  /// readers). All signaling goes through `reaper.signalGroupIfAlive`, which holds
  /// the reap lock across the alive-check and the `kill`, closing the pid-reuse
  /// window. The kill closes the child's write ends, delivering EOF to the reader
  /// tasks so they finish, and lets the parked `waitForExit()` reap the child.
  func terminate() {
    let alreadyTerminating = didTerminate.withLock { flag -> Bool in
      if flag { return true }
      flag = true
      return false
    }
    guard !alreadyTerminating else { return }

    let reaper = reaper
    // No-op if the child was already reaped (returns false).
    guard reaper.signalGroupIfAlive(SIGTERM) else { return }
    // Escalate to SIGKILL after a brief grace, without blocking the caller.
    // Capture only the reaper box (not self, which may be mid-deinit).
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
      reaper.signalGroupIfAlive(SIGKILL)
    }
  }

  deinit {
    terminate()
  }
}

// MARK: - ChildReaper

/// Owns a child pid and serializes reaping against signaling under one lock, so
/// a signal can never target a pid the kernel has already freed (and possibly
/// reused). The crucial invariant: the `waitpid` that frees the pid and the state
/// transition to `.reaped` happen **atomically under the same lock** as the
/// alive-check that guards `kill`. Reference-typed and `Sendable` so background
/// closures capture *it* — never the `SpawnedProcess`, which may be mid-`deinit`.
private final class ChildReaper: Sendable {
  private enum State {
    case running
    case exited(Int32)
  }
  private let pid: pid_t
  private let state = Mutex<State>(.running)

  init(pid: pid_t) { self.pid = pid }

  /// One non-blocking reap attempt, performed **under the lock** so the pid can't
  /// be signalled by `signalGroupIfAlive` between the `waitpid` that frees it and
  /// the state transition. Returns the exit code once reaped, else `nil`.
  func tryReap() -> Int32? {
    state.withLock { current in
      if case .exited(let code) = current { return code }
      var status: Int32 = 0
      let result = waitpid(pid, &status, WNOHANG)
      if result == 0 { return nil }  // still running
      if result == -1 {
        if errno == EINTR { return nil }  // caller retries
        // ECHILD or other: already reaped/unwaitable. Treat as abnormal exit.
        current = .exited(-1)
        return -1
      }
      let code: Int32 =
        (status & 0x7f) == 0
        ? (status >> 8) & 0xff  // WIFEXITED → WEXITSTATUS
        : 128 + (status & 0x7f)  // signalled → 128 + WTERMSIG
      current = .exited(code)
      return code
    }
  }

  /// Sends `signal` to the whole process group *iff* the child hasn't been reaped
  /// yet, holding the lock across the check and the `kill`. Because `tryReap`
  /// performs its `waitpid` under this same lock, a reap can never interleave
  /// between our check and our `kill`, so we can't signal a reused pgid. Returns
  /// false if the child was already reaped (nothing sent).
  @discardableResult
  func signalGroupIfAlive(_ signal: Int32) -> Bool {
    state.withLock { current in
      guard case .running = current else { return false }
      kill(-pid, signal)  // negative pid ⇒ the whole process group
      return true
    }
  }
}

// MARK: - StderrTail

/// Thread-safe rolling capture of the last stderr lines, used to build a concise
/// `engineFailed` message without holding the entire stream in memory.
private final class StderrTail: Sendable {
  private let maxLines = 40
  private let storage = Mutex<[String]>([])

  func append(_ line: String) {
    storage.withLock { lines in
      lines.append(line)
      if lines.count > maxLines {
        lines.removeFirst(lines.count - maxLines)
      }
    }
  }

  func snapshot() -> String {
    storage.withLock { $0.joined(separator: "\n") }
  }
}
