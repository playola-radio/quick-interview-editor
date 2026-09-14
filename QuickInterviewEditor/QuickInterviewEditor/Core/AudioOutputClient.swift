import AudioToolbox
import CoreAudio
import Dependencies
import Foundation
import IssueReporting

/// A CoreAudio output device, identified for persistence by `uid` (never the runtime `id`).
struct OutputDevice: Equatable, Sendable {
  var id: UInt32  // AudioDeviceID — runtime only, never persisted
  var uid: String  // kAudioDevicePropertyDeviceUID — persistent key
  var name: String  // kAudioObjectPropertyName — display
}

/// Reads the current default output device and notifies when it changes. Isolated as a dependency
/// so the player and Settings resolve device identity/latency without a real HAL in tests.
struct AudioOutputClient: Sendable {
  /// The current default output device, or nil if it can't be resolved.
  var current: @Sendable () -> OutputDevice?
  /// Fires (no payload) whenever the system default output device changes. Read `current()` after.
  var changes: @Sendable () -> AsyncStream<Void>
}

extension AudioOutputClient: DependencyKey {
  static let liveValue = AudioOutputClient(
    current: { Self.readDefaultOutputDevice() },
    changes: {
      AsyncStream { continuation in
        let box = DefaultOutputListenerBox(continuation: continuation)
        let status = box.startListening()
        if status != noErr { continuation.finish() }
        continuation.onTermination = { _ in box.stopListening() }
      }
    }
  )

  private static func readDefaultOutputDevice() -> OutputDevice? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
      deviceID != 0,
      let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
      let name = stringProperty(deviceID, kAudioObjectPropertyName)
    else { return nil }
    return OutputDevice(id: deviceID, uid: uid, name: name)
  }

  private static func stringProperty(
    _ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    return value as String
  }
}

extension AudioOutputClient: TestDependencyKey {
  static let testValue = AudioOutputClient(
    current: {
      reportIssue("AudioOutputClient.current called without a test override")
      return nil
    },
    changes: { AsyncStream { $0.finish() } }
  )
  static let previewValue = AudioOutputClient(
    current: { OutputDevice(id: 0, uid: "preview", name: "Built-in Output") },
    changes: { AsyncStream { $0.finish() } })
}

extension DependencyValues {
  var audioOutput: AudioOutputClient {
    get { self[AudioOutputClient.self] }
    set { self[AudioOutputClient.self] = newValue }
  }
}

/// Owns one HAL property-listener registration for `kAudioHardwarePropertyDefaultOutputDevice`,
/// so the block/address pair has a single mutable owner instead of being captured by both the
/// `AsyncStream` body and its `onTermination` closure (which Swift 6 flags as a potential
/// concurrent-mutation race). The HAL delivers listener callbacks serially, never overlapping
/// our own add/remove calls, so `@unchecked Sendable` is safe here — mirroring the
/// `SingleFileDownload` delegate box in `LiveModelDownloader.swift`.
private final class DefaultOutputListenerBox: @unchecked Sendable {
  private var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  private var listener: AudioObjectPropertyListenerBlock?
  private let continuation: AsyncStream<Void>.Continuation

  init(continuation: AsyncStream<Void>.Continuation) {
    self.continuation = continuation
  }

  func startListening() -> OSStatus {
    let listener: AudioObjectPropertyListenerBlock = { [continuation] _, _ in
      continuation.yield(())
    }
    self.listener = listener
    return AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
  }

  func stopListening() {
    guard let listener else { return }
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
  }
}
