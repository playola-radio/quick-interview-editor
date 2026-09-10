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

  @Test func deviceChangeReresolvesDeviceAndOffset() async {
    @Shared(.outputLatencyOffsets) var offsets = ["uid-a": 0.02, "uid-b": -0.05]
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    let currentDevice = LockIsolated(OutputDevice(id: 1, uid: "uid-a", name: "Built-in"))
    let model = withDependencies {
      $0.audioOutput = AudioOutputClient(
        current: { currentDevice.value },
        changes: { stream })
    } operation: {
      PlaybackLatencySettingsModel()
    }
    model.viewAppeared()
    expectNoDifference(model.deviceName, "Built-in")
    expectNoDifference(model.offsetMs, 20)
    currentDevice.setValue(OutputDevice(id: 2, uid: "uid-b", name: "AirPods"))
    continuation.yield(())
    await settle { model.deviceName == "AirPods" }
    expectNoDifference(model.deviceName, "AirPods")
    expectNoDifference(model.offsetMs, -50)  // -0.05 s → -50 ms, the NEW device's stored offset
  }

  private func settle(until condition: () -> Bool) async {
    for _ in 0..<1000 where !condition() { await Task.yield() }
  }
}
