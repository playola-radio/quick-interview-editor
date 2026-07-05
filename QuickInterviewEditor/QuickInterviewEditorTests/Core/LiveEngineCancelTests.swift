import Foundation
import Testing

@testable import QuickInterviewEditor

/// Opt-in integration test for the live-engine cancellation path.
///
/// The whole cancel UX rests on `SpawnedProcess` killing the child's entire
/// **process group** (the Python engine plus its `afconvert`/model-download
/// children) when the transcription stream is cancelled. That path can't be
/// exercised by the pure-model suite, and running the real WhisperX engine needs
/// gigabytes of models. Instead we point `QIE_ENGINE_REPO` at a throwaway repo
/// whose `.venv/bin/python` is a shim that spawns a uniquely-named `sleep`
/// grandchild and then blocks. Cancelling the stream must reap the grandchild.
///
/// Gated behind `QIE_RUN_CANCEL_TEST=1` because it spawns real OS processes and
/// polls in real time — not something to run on every unit-test pass.
struct LiveEngineCancelTests {

  @Test(.enabled(if: ProcessInfo.processInfo.environment["QIE_RUN_CANCEL_TEST"] == "1"))
  func cancellingTranscriptionKillsTheProcessGroup() async throws {
    let token = "qieprobe" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let fakeRepo = try makeFakeEngineRepo(probeToken: token)
    defer { try? FileManager.default.removeItem(at: fakeRepo) }

    setenv("QIE_ENGINE_REPO", fakeRepo.path, 1)
    setenv("QIE_PROBE_TOKEN", token, 1)
    defer {
      unsetenv("QIE_ENGINE_REPO")
      unsetenv("QIE_PROBE_TOKEN")
    }

    // Consume the stream until the first progress event, then cancel — mirroring
    // a user cancel (SongTabModel.cancel() -> task.cancel()).
    let consume = Task {
      for try await event in LiveEngine.transcribe(audio: URL(fileURLWithPath: "/tmp/unused.m4a")) {
        if case .progress = event { break }
      }
    }

    // The grandchild should appear once the shim runs. Generous timeout: spawning
    // real processes (bash + sleep) can be slow when the machine is saturated.
    try await pollUntil(timeoutMs: 20000) { probeIsAlive(token) }
    #expect(probeIsAlive(token), "grandchild should be running before cancel")

    consume.cancel()

    // The process-group kill (SIGTERM, then SIGKILL after the grace period) must
    // reap the grandchild. Allow generous headroom over the 2s SIGKILL escalation.
    try await pollUntil(timeoutMs: 8000) { !probeIsAlive(token) }
    #expect(
      !probeIsAlive(token), "grandchild must be gone after cancel — process group was not killed")

    _ = await consume.result
  }

  // MARK: - Helpers

  /// Writes a fake `<repo>/.venv/bin/python` shim and returns the repo dir.
  private func makeFakeEngineRepo(probeToken: String) throws -> URL {
    let repo = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-fake-engine-\(UUID().uuidString)")
    let binDir = repo.appendingPathComponent(".venv/bin")
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

    // Ignores all args. Spawns a uniquely-named grandchild in the same process
    // group, emits one progress event on stderr, then blocks so the stream never
    // completes on its own (only cancellation ends it).
    let shim = """
      #!/bin/bash
      /bin/bash -c "exec -a ${QIE_PROBE_TOKEN} sleep 600" &
      echo 'QIE_EVENT {"type":"progress","phase":"transcribing","message":"probe"}' >&2
      sleep 600
      """
    let python = binDir.appendingPathComponent("python")
    try shim.write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    return repo
  }

  /// True if a process whose argv[0] matches `token` is running.
  private func probeIsAlive(_ token: String) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-f", token]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do { try proc.run() } catch { return false }
    proc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return !data.isEmpty
  }

  private func pollUntil(timeoutMs: Int, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(nanoseconds: 100_000_000)  // 100ms — real subprocess timing
    }
  }
}
