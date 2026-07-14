import Foundation
import Testing

@testable import QuickInterviewEditor

/// Opt-in, real-subprocess integration coverage for the live engine.
///
/// This suite drives the actual Python engine, so it is **skipped by default**.
/// It runs only when `QIE_RUN_LIVE_ENGINE=1` AND `QIE_ENGINE_REPO` points at a
/// checkout with a working `.venv/bin/python`. In every normal run (CI, local
/// `xcodebuild test`) it is skipped, keeping the suite green with no `.venv` and
/// no subprocess.
struct LiveEngineIntegrationTests {

  /// The engine's `.venv` python, or `nil` when it isn't available.
  private var venvPython: String? {
    guard let repo = ProcessInfo.processInfo.environment["QIE_ENGINE_REPO"] else { return nil }
    let path = repo + "/.venv/bin/python"
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
  }

  /// A committed sample clip inside the engine repo to transcribe.
  private var sampleClip: String? {
    guard let repo = ProcessInfo.processInfo.environment["QIE_ENGINE_REPO"] else { return nil }
    let candidates = [
      ProcessInfo.processInfo.environment["QIE_SAMPLE_CLIP"],
      repo + "/tests/fixtures/sample.wav",
      repo + "/tests/fixtures/sample.m4a",
    ].compactMap { $0 }
    return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["QIE_RUN_LIVE_ENGINE"] == "1"))
  func transcribesASampleClipEndToEnd() async throws {
    try #require(venvPython != nil, "QIE_ENGINE_REPO must have a working .venv/bin/python")
    let clip = try #require(sampleClip, "no sample clip found (set QIE_SAMPLE_CLIP)")

    var sawProgress = false
    var completedResult: TranscriptionResult?
    for try await event in LiveEngine.transcribe(audio: URL(fileURLWithPath: clip)) {
      switch event {
      case .progress:
        sawProgress = true
      case .completed(let result):
        completedResult = result
      }
    }

    #expect(sawProgress)
    let result = try #require(completedResult, "engine produced no completed result")
    #expect(!result.editPlan.words.isEmpty)
    // The canonical AIFF was copied into the app cache and exists on disk.
    #expect(FileManager.default.fileExists(atPath: result.canonicalAudioURL.path))
    CanonicalAudioStore.remove(result.canonicalAudioURL)
  }
}
