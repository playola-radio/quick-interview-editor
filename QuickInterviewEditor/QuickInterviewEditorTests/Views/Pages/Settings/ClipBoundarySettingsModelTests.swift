import CustomDump
import Dependencies
import Foundation
import Sharing
import Testing

@testable import QuickInterviewEditor

@MainActor
struct ClipBoundarySettingsModelTests {
  @Test func defaultOffsetsAreZero() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "clip-settings-default-\(UUID())")!
    } operation: {
      let model = ClipBoundarySettingsModel()
      expectNoDifference(model.startOffsetMs, 0)
      expectNoDifference(model.endOffsetMs, 0)
      expectNoDifference(model.startOffsetLabel, "0 ms")
      expectNoDifference(model.endOffsetLabel, "0 ms")
      expectNoDifference(model.canReset, false)
    }
  }

  @Test func settingAValueRoundTripsThroughSharedStorage() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "clip-settings-roundtrip-\(UUID())")!
    } operation: {
      let model = ClipBoundarySettingsModel()
      model.startOffsetChanged(-15)
      model.endOffsetChanged(20)

      expectNoDifference(model.startOffsetMs, -15)
      expectNoDifference(model.endOffsetMs, 20)

      @Shared(.clipStartOffsetMs) var persistedStart
      @Shared(.clipEndOffsetMs) var persistedEnd
      expectNoDifference(persistedStart, -15)
      expectNoDifference(persistedEnd, 20)
    }
  }

  @Test func changesAreClampedToFiftyMilliseconds() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "clip-settings-clamp-\(UUID())")!
    } operation: {
      let model = ClipBoundarySettingsModel()
      model.startOffsetChanged(-500)
      model.endOffsetChanged(500)
      expectNoDifference(model.startOffsetMs, -50)
      expectNoDifference(model.endOffsetMs, 50)
    }
  }

  @Test func outOfRangeStoredValueIsNormalizedOnInit() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "clip-settings-normalize-\(UUID())")!
    } operation: {
      @Shared(.clipStartOffsetMs) var startOffsetMs = 500.0
      @Shared(.clipEndOffsetMs) var endOffsetMs = -500.0

      let model = ClipBoundarySettingsModel()

      expectNoDifference(model.startOffsetMs, 50)
      expectNoDifference(model.endOffsetMs, -50)

      @Shared(.clipStartOffsetMs) var persistedStart
      @Shared(.clipEndOffsetMs) var persistedEnd
      expectNoDifference(persistedStart, 50)
      expectNoDifference(persistedEnd, -50)
    }
  }

  @Test func readoutLabelFormatting() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "clip-settings-labels-\(UUID())")!
    } operation: {
      let model = ClipBoundarySettingsModel()

      model.startOffsetChanged(15)
      expectNoDifference(model.startOffsetLabel, "+15 ms")

      model.startOffsetChanged(0)
      expectNoDifference(model.startOffsetLabel, "0 ms")

      model.startOffsetChanged(-20)
      expectNoDifference(model.startOffsetLabel, "\u{2212}20 ms")
    }
  }

  @Test func resetTappedZeroesBothAndFlipsCanReset() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "clip-settings-reset-\(UUID())")!
    } operation: {
      let model = ClipBoundarySettingsModel()
      model.startOffsetChanged(-15)
      model.endOffsetChanged(20)
      #expect(model.canReset)

      model.resetTapped()

      expectNoDifference(model.startOffsetMs, 0)
      expectNoDifference(model.endOffsetMs, 0)
      expectNoDifference(model.canReset, false)
    }
  }
}
