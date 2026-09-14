import Foundation
import Sharing

/// `@Shared` keys for output-latency compensation.
///
/// `.outputLatencyOffsets` is the user's signed per-device manual correction (seconds, keyed by
/// CoreAudio device UID), persisted as one JSON file so it survives relaunch and follows the
/// device. `.outputLatencyEstimates` is the automatic `outputPresentationLatency` the player
/// measures during playback, published in-memory for the Settings readout (session-only; there is
/// nothing to persist — it is re-measured each playback).
extension SharedKey where Self == FileStorageKey<[String: Double]>.Default {
  static var outputLatencyOffsets: Self {
    Self[.fileStorage(outputLatencyOffsetsURL), default: [:]]
  }
}

extension SharedKey where Self == InMemoryKey<[String: Double]>.Default {
  static var outputLatencyEstimates: Self {
    Self[.inMemory("outputLatencyEstimates"), default: [:]]
  }
}

/// `…/Application Support/Playola Interview Editor/PlaybackLatency/output-offsets.json`.
private let outputLatencyOffsetsURL: URL =
  URL.applicationSupportDirectory
  .appending(component: AppDirectories.folderName, directoryHint: .isDirectory)
  .appending(component: "PlaybackLatency", directoryHint: .isDirectory)
  .appending(component: "output-offsets.json", directoryHint: .notDirectory)

enum OutputLatencyOffsets {
  /// The stored signed offset (seconds) for a device UID, or 0 for a nil/absent/non-finite entry.
  /// A missing UID must never reuse another device's value.
  static func offsetSeconds(for uid: String?, in map: [String: Double]) -> Double {
    guard let uid, let value = map[uid], value.isFinite else { return 0 }
    return value
  }
}
