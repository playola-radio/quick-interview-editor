import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

private func stream(_ events: [ModelDownloadEvent], throwing error: Error? = nil)
  -> AsyncThrowingStream<ModelDownloadEvent, Error>
{
  AsyncThrowingStream { continuation in
    for event in events { continuation.yield(event) }
    continuation.finish(throwing: error)
  }
}

private let installation = ModelInstallation(
  whisperModelDir: URL(fileURLWithPath: "/Models/faster-whisper-large-v2"),
  alignModelDir: URL(fileURLWithPath: "/Models/align")
)

private let smallManifest = ModelManifest(
  version: 1,
  files: [
    ModelFile(
      remoteURL: URL(string: "https://example.com/a.bin")!, relativePath: "a.bin",
      sha256: "aa", byteCount: 100),
    ModelFile(
      remoteURL: URL(string: "https://example.com/b.bin")!, relativePath: "b.bin",
      sha256: "bb", byteCount: 300),
  ]
)

@MainActor
struct ModelSetupTests {

  @Test func alreadyInstalledGoesStraightToReady() async {
    let model = ModelSetupModel(manifest: smallManifest)
    var readyWith: ModelInstallation?
    model.onReady = { readyWith = $0 }

    await withDependencies {
      $0.modelDownloader.installedLocation = { _ in installation }
    } operation: {
      await model.viewAppeared()
    }

    #expect(model.isReady)
    expectNoDifference(readyWith, installation)
  }

  @Test func downloadsWhenNotInstalledThenBecomesReady() async {
    let model = ModelSetupModel(manifest: smallManifest)
    var readyWith: ModelInstallation?
    model.onReady = { readyWith = $0 }

    await withDependencies {
      $0.modelDownloader.installedLocation = { _ in nil }
      $0.modelDownloader.download = { _ in
        stream([
          .progress(.init(completedBytes: 100, totalBytes: 400, currentFileName: "a.bin")),
          .progress(.init(completedBytes: 400, totalBytes: 400, currentFileName: "b.bin")),
          .completed(installation),
        ])
      }
    } operation: {
      await model.viewAppeared()
    }

    #expect(model.isReady)
    expectNoDifference(readyWith, installation)
  }

  @Test func progressDrivesFractionAndStatusText() async {
    let model = ModelSetupModel(manifest: smallManifest)

    await withDependencies {
      $0.modelDownloader.installedLocation = { _ in nil }
      $0.modelDownloader.download = { _ in
        stream(
          [.progress(.init(completedBytes: 200, totalBytes: 400, currentFileName: "b.bin"))],
          throwing: CancellationError())
      }
    } operation: {
      await model.viewAppeared()
    }

    expectNoDifference(model.progressFraction, 0.5)
    #expect(model.statusMessage.contains("50%"))
    #expect(model.statusMessage.contains("b.bin"))
    #expect(model.showsProgressBar)
  }

  @Test func failureSetsFailedPhaseAndShowsRetry() async {
    let model = ModelSetupModel(manifest: smallManifest)

    await withDependencies {
      $0.modelDownloader.installedLocation = { _ in nil }
      $0.modelDownloader.download = { _ in
        stream(
          [],
          throwing: ModelDownloadError.checksumMismatch(
            file: "a.bin", expected: "aa", actual: "zz"))
      }
    } operation: {
      await model.viewAppeared()
    }

    #expect(!model.isReady)
    #expect(model.errorMessage != nil)
    #expect(model.showsRetry)
    #expect(!model.showsProgressBar)
  }

  @Test func cancelSetsFailedPhaseWithRetryHint() {
    let model = ModelSetupModel(manifest: smallManifest)
    model.cancelTapped()
    #expect(model.showsRetry)
    #expect(model.errorMessage?.contains(model.retryButtonLabel) == true)
  }

  /// Regression: cancel must actually stop an in-flight download. The stubbed
  /// stream never finishes on its own, so `viewAppeared()` only returns if
  /// `cancelTapped()` cancels the stored task — otherwise this test hangs.
  @Test func cancelStopsAnInFlightDownload() async {
    let model = ModelSetupModel(manifest: smallManifest)
    let started = AsyncStream<Void>.makeStream()

    await withDependencies {
      $0.modelDownloader.installedLocation = { _ in nil }
      $0.modelDownloader.download = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(
            .progress(.init(completedBytes: 0, totalBytes: 400, currentFileName: "a.bin")))
          started.continuation.yield()
          started.continuation.finish()
          // Never finishes on its own — only cancellation ends it.
        }
      }
    } operation: {
      let running = Task { await model.viewAppeared() }
      var iterator = started.stream.makeAsyncIterator()
      _ = await iterator.next()  // wait until the download is live (deterministic)
      model.cancelTapped()
      await running.value  // returns only if cancel truly stopped the task
    }

    #expect(model.showsRetry)
    #expect(!model.isReady)
  }

  @Test func engineEnvironmentMapsInstallationToQIEVars() {
    expectNoDifference(
      installation.engineEnvironment,
      [
        "QIE_WHISPER_MODEL_DIR": "/Models/faster-whisper-large-v2",
        "QIE_ALIGN_MODEL_DIR": "/Models/align",
        "QIE_OFFLINE": "1",
      ]
    )
  }

  @Test func manifestTotalIsSumOfFileSizes() {
    expectNoDifference(smallManifest.totalByteCount, 400)
    expectNoDifference(ModelManifest.current.files.count, 5)
  }
}
