import Dependencies
import Foundation
import Observation
import Sharing

/// Drives the "Playback Latency" settings tab: shows the current output device and its
/// auto-measured latency, and a signed manual nudge (Earlier ↔ Later) persisted per device UID.
/// Auto-detection handles the baseline; this only corrects what the OS under/over-reports on a
/// given device (notably Bluetooth). All copy/bounds/derived values live here; the view binds only.
@MainActor
@Observable
final class PlaybackLatencySettingsModel: ViewModel {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.audioOutput) var audioOutput

  // MARK: - Shared State
  @ObservationIgnored @Shared(.outputLatencyOffsets) var offsets: [String: Double]
  @ObservationIgnored @Shared(.outputLatencyEstimates) var estimates: [String: Double]

  // MARK: - Properties
  let minMs = -300.0
  let maxMs = 300.0
  private var deviceUID: String?
  var deviceName: String = "No output device"
  var offsetMs: Double = 0
  @ObservationIgnored private var deviceObservationTask: Task<Void, Never>?

  // MARK: - Display Text
  let title = "Playback Latency"
  let sectionHeader = "Bluetooth A/V Sync"
  let helpText =
    "The app automatically delays the playhead to match when you hear the audio, so it lines up "
    + "over Bluetooth. If the playhead still leads or trails what you hear on this device, nudge "
    + "it Earlier or Later. Saved per output device."
  let offsetSliderLabel = "Adjust"
  let resetLabel = "Reset"

  // MARK: - View Helpers
  var deviceLabel: String { "Output: \(deviceName)" }
  var autoEstimateLabel: String {
    guard let uid = deviceUID, let seconds = estimates[uid] else {
      return "Auto-detected: measured during playback"
    }
    return "Auto-detected: \(Int((seconds * 1000).rounded())) ms"
  }
  var offsetLabel: String { Self.readoutLabel(for: offsetMs) }
  var canReset: Bool { offsetMs != 0 }

  // MARK: - User Actions
  func viewAppeared() {
    resolveCurrentDevice()
    startObservingDeviceChanges()
  }

  func offsetChanged(_ ms: Double) {
    guard let device = audioOutput.current() else { return }
    let uid = device.uid
    deviceUID = uid
    deviceName = device.name  // keep the visible target in step with the device we write to
    let clampedMs = min(max(ms, minMs), maxMs).rounded()
    offsetMs = clampedMs
    $offsets.withLock { $0[uid] = clampedMs / 1000 }
  }

  func resetTapped() {
    guard let device = audioOutput.current() else { return }
    let uid = device.uid
    deviceUID = uid
    deviceName = device.name
    offsetMs = 0
    $offsets.withLock { $0[uid] = 0 }
  }

  // MARK: - Private Helpers
  private func resolveCurrentDevice() {
    let device = audioOutput.current()
    deviceUID = device?.uid
    deviceName = device?.name ?? "No output device"
    let seconds = OutputLatencyOffsets.offsetSeconds(for: deviceUID, in: offsets)
    offsetMs = (seconds * 1000).rounded()
  }

  private func startObservingDeviceChanges() {
    guard deviceObservationTask == nil else { return }
    let changes = audioOutput.changes
    deviceObservationTask = Task { [weak self] in
      for await _ in changes() {
        guard let self else { return }
        self.resolveCurrentDevice()
      }
    }
  }

  deinit { deviceObservationTask?.cancel() }

  private static func readoutLabel(for ms: Double) -> String {
    let rounded = Int(ms.rounded())
    if rounded == 0 { return "0 ms" }
    if rounded > 0 { return "+\(rounded) ms later" }
    return "\u{2212}\(abs(rounded)) ms earlier"
  }
}
