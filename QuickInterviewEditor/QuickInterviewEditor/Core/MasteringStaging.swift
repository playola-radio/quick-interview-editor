import Darwin
import Foundation

// swiftlint:disable:next inclusive_language
final class StagedMasteringArtifact: Sendable, Equatable {
  let url: URL
  private let leaseDescriptor: Int32

  fileprivate init(url: URL, leaseDescriptor: Int32) {
    self.url = url
    self.leaseDescriptor = leaseDescriptor
  }

  deinit {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    close(leaseDescriptor)
  }

  static func == (lhs: StagedMasteringArtifact, rhs: StagedMasteringArtifact) -> Bool {
    lhs === rhs
  }
}

// swiftlint:disable:next inclusive_language
enum MasteringStagingStore {
  static func baseDirectory() throws -> URL {
    try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    .appendingPathComponent("\(AppDirectories.folderName)/Mastering")
  }

  static func makeWorkDirectory(in base: URL? = nil) throws -> URL {
    let base = try base ?? baseDirectory()
    let dir = base.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func adopt(_ source: URL, as name: String, in base: URL? = nil) throws
    -> StagedMasteringArtifact
  {
    try stage(source, as: name, in: base, move: true)
  }

  static func copy(_ source: URL, as name: String, in base: URL? = nil) throws
    -> StagedMasteringArtifact
  {
    try stage(source, as: name, in: base, move: false)
  }

  private static func stage(_ source: URL, as name: String, in base: URL?, move: Bool) throws
    -> StagedMasteringArtifact
  {
    guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent,
      name != ".", name != ".."
    else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    let dir = try makeWorkDirectory(in: base)
    do {
      let lock = dir.appendingPathComponent(".lease")
      let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        close(descriptor)
        throw CocoaError(.fileWriteUnknown)
      }
      let target = dir.appendingPathComponent(name)
      do {
        if move {
          try FileManager.default.moveItem(at: source, to: target)
        } else {
          try FileManager.default.copyItem(at: source, to: target)
        }
      } catch {
        close(descriptor)
        throw error
      }
      return StagedMasteringArtifact(url: target, leaseDescriptor: descriptor)
    } catch {
      try? FileManager.default.removeItem(at: dir)
      throw error
    }
  }

  static func removeDirectory(_ dir: URL, in base: URL? = nil) {
    guard let base = try? base ?? baseDirectory(),
      dir.deletingLastPathComponent().standardizedFileURL == base.standardizedFileURL
    else { return }
    try? FileManager.default.removeItem(at: dir)
  }

  static func reapStale(
    olderThan maxAge: TimeInterval = CanonicalAudioStore.staleAfter,
    in base: URL? = nil, now: Date = Date()
  ) {
    guard let base = try? base ?? baseDirectory(),
      let dirs = try? FileManager.default.contentsOfDirectory(
        at: base, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
    else { return }
    for dir in dirs {
      guard
        let modified = try? dir.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate, now.timeIntervalSince(modified) > maxAge
      else { continue }
      let descriptor = open(dir.appendingPathComponent(".lease").path, O_RDWR)
      if descriptor >= 0 {
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
          close(descriptor)
          continue
        }
      }
      try? FileManager.default.removeItem(at: dir)
      if descriptor >= 0 { close(descriptor) }
    }
  }
}
