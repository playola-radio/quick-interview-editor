import CustomDump
import Dependencies
import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct PlaybackLatencySettingsModelTests {

  @Test func viewAppearedResolvesCurrentDeviceNameAndOffset() {
    @Shared(.outputLatencyOffsets) var offsets = ["uid-buds": 0.05]
    let model = withDependencies {
      $0.audioOutput = AudioOutputClient(
        current: { OutputDevice(id: 1, uid: "uid-buds", name: "AirPods") },
        changes: { AsyncStream { $0.finish() } })
    } operation: {
      PlaybackLatencySettingsModel()
    }
    model.viewAppeared()
    expectNoDifference(model.deviceName, "AirPods")
    expectNoDifference(model.offsetMs, 50)  // 0.05 s → 50 ms
  }

  @Test func offsetChangedWritesSignedMillisecondsForCurrentDevice() {
    @Shared(.outputLatencyOffsets) var offsets = [:]
    let model = withDependencies {
      $0.audioOutput = AudioOutputClient(
        current: { OutputDevice(id: 1, uid: "uid-buds", name: "AirPods") },
        changes: { AsyncStream { $0.finish() } })
    } operation: {
      PlaybackLatencySettingsModel()
    }
    model.viewAppeared()
    model.offsetChanged(-30)
    expectNoDifference(offsets["uid-buds"], -0.030)  // stored in seconds
  }

  @Test func offsetChangedIsNoOpWhenNoDevice() {
    @Shared(.outputLatencyOffsets) var offsets = [:]
    let model = withDependencies {
      $0.audioOutput = AudioOutputClient(current: { nil }, changes: { AsyncStream { $0.finish() } })
    } operation: {
      PlaybackLatencySettingsModel()
    }
    model.viewAppeared()
    model.offsetChanged(-30)
    expectNoDifference(offsets, [:])
  }
}
