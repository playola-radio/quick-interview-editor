import CryptoKit
import Foundation

/// Live implementation of ``ModelDownloadClient``: downloads each manifest file
/// with a `URLSessionDownloadTask` (streams straight to disk — never holds a
/// multi-GB body in memory), **resumes** on transient failure via `resumeData`,
/// and **verifies** SHA-256 before moving the file into place. A per-version
/// sentinel marks a fully-verified install so relaunch is a fast size check
/// rather than re-hashing gigabytes.
enum LiveModelDownloader {

  private static let maxAttemptsPerFile = 4
  private static let bufferBytes = 1 << 20  // 1 MiB hashing chunks

  // MARK: Installed check

  static func installedLocation(_ manifest: ModelManifest) -> ModelInstallation? {
    guard
      let root = try? ModelLocations.modelsRoot(),
      let installation = try? ModelLocations.installation()
    else { return nil }

    // The sentinel is written only after every file passed checksum, so its
    // presence + correct file sizes is enough — no need to re-hash on launch.
    let sentinel = root.appendingPathComponent(".complete-v\(manifest.version)")
    guard FileManager.default.fileExists(atPath: sentinel.path) else { return nil }
    for file in manifest.files {
      let dest = root.appendingPathComponent(file.relativePath)
      guard fileSize(dest) == file.byteCount else { return nil }
    }
    return installation
  }

  // MARK: Download

  static func download(_ manifest: ModelManifest) -> AsyncThrowingStream<ModelDownloadEvent, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let root = try ModelLocations.modelsRoot()
          let total = manifest.totalByteCount
          var completed: Int64 = 0

          // Clear any prior completion sentinel up front: while we're (re)downloading
          // or repairing, the install must read as incomplete, so a crash mid-repair
          // can't leave a sentinel next to a missing/half-written file.
          try? FileManager.default.removeItem(
            at: root.appendingPathComponent(".complete-v\(manifest.version)"))

          for file in manifest.files {
            try Task.checkCancellation()
            let dest = root.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(
              at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let name = (file.relativePath as NSString).lastPathComponent

            // Already downloaded + verified? count it and skip.
            if fileSize(dest) == file.byteCount, (try? verify(dest, sha256: file.sha256)) == true {
              completed += file.byteCount
              continuation.yield(
                .progress(
                  .init(completedBytes: completed, totalBytes: total, currentFileName: name)))
              continue
            }

            let base = completed
            try await downloadWithResume(file, to: dest) { fileBytes in
              continuation.yield(
                .progress(
                  .init(
                    completedBytes: base + fileBytes, totalBytes: total, currentFileName: name)))
            }
            completed += file.byteCount
          }

          // Every file verified: mark the install complete.
          try Data().write(
            to: root.appendingPathComponent(".complete-v\(manifest.version)"), options: .atomic)
          continuation.yield(.completed(try ModelLocations.installation()))
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

  // MARK: - One file, with resume + checksum

  private static func downloadWithResume(
    _ file: ModelFile,
    to dest: URL,
    onProgress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    var resumeData: Data?
    var lastError: Error?

    for _ in 0..<maxAttemptsPerFile {
      try Task.checkCancellation()
      do {
        let tempURL = try await SingleFileDownload.run(
          url: file.remoteURL, resumeData: resumeData, onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let size = fileSize(tempURL) ?? 0
        guard size == file.byteCount else {
          throw ModelDownloadError.incompleteDownload(
            file: file.relativePath, expected: file.byteCount, actual: size)
        }
        let actual = try sha256Hex(of: tempURL)
        guard actual == file.sha256 else {
          throw ModelDownloadError.checksumMismatch(
            file: file.relativePath, expected: file.sha256, actual: actual)
        }
        // Atomic-ish swap into place.
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return
      } catch let error as ModelDownloadError {
        // A checksum/size failure won't fix itself on retry — surface it.
        throw error
      } catch {
        lastError = error
        resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
      }
    }
    throw lastError
      ?? ModelDownloadError.incompleteDownload(
        file: file.relativePath, expected: file.byteCount, actual: 0)
  }

  // MARK: - Helpers

  private static func fileSize(_ url: URL) -> Int64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
  }

  private static func verify(_ url: URL, sha256: String) throws -> Bool {
    try sha256Hex(of: url) == sha256
  }

  /// Streaming SHA-256 so a 3 GB file never lands in memory at once.
  private static func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: bufferBytes), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - SingleFileDownload

/// Bridges one `URLSessionDownloadTask` to async/await, reporting byte progress
/// and preserving `resumeData` on failure (so the caller can resume).
private final class SingleFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

  private let onProgress: @Sendable (Int64) -> Void
  private var continuation: CheckedContinuation<URL, Error>?
  /// The delegate hands back a temp file that URLSession will delete when the
  /// delegate callback returns, so we copy it out synchronously and hand the copy up.
  private var deliveredURL: URL?

  private init(onProgress: @escaping @Sendable (Int64) -> Void) {
    self.onProgress = onProgress
  }

  static func run(
    url: URL,
    resumeData: Data?,
    onProgress: @escaping @Sendable (Int64) -> Void
  ) async throws -> URL {
    let delegate = SingleFileDownload(onProgress: onProgress)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        delegate.continuation = continuation
        let task =
          resumeData.map { session.downloadTask(withResumeData: $0) }
          ?? session.downloadTask(with: url)
        task.resume()
      }
    } onCancel: {
      session.invalidateAndCancel()
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    onProgress(totalBytesWritten)
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    // Must copy synchronously: `location` is removed once this returns.
    let copy = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    do {
      try FileManager.default.moveItem(at: location, to: copy)
      deliveredURL = copy
    } catch {
      deliveredURL = nil
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    if let error {
      continuation?.resume(throwing: error)
    } else if let url = deliveredURL {
      continuation?.resume(returning: url)
    } else {
      continuation?.resume(
        throwing: URLError(.cannotWriteToFile))
    }
    continuation = nil
  }
}
