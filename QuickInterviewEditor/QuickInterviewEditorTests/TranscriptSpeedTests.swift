import CustomDump
import Dependencies
import Foundation
import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct TranscriptSpeedTests {
  @Test func defaultPlaybackRateIsNormalSpeed() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "speed-default")!
    } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      expectNoDifference(model.playbackRate, 1.0)
      expectNoDifference(model.speedLabel, "1.0×")
    }
  }

  @Test func speedSelectedPersistsAndNotifiesOnlyOnChange() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "speed-select-\(UUID())")!
    } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      var received: [Double] = []
      model.onPlaybackRateChanged = { received.append($0) }
      model.speedSelected(1.5)
      expectNoDifference(model.playbackRate, 1.5)
      expectNoDifference(received, [1.5])
      model.speedSelected(1.5)  // re-selecting the current speed is inert
      expectNoDifference(received, [1.5])
    }
  }

  @Test func speedUpStepsThroughPresetsAndClampsAtMax() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "speed-up-\(UUID())")!
    } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      model.speedUpTapped()
      expectNoDifference(model.playbackRate, 1.25)
      model.speedUpTapped()
      expectNoDifference(model.playbackRate, 1.5)
      for _ in 0..<20 { model.speedUpTapped() }
      expectNoDifference(model.playbackRate, 3.0)  // clamped at the fastest preset
      expectNoDifference(model.canSpeedUp, false)
    }
  }

  @Test func speedDownStepsThroughPresetsAndClampsAtMin() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "speed-down-\(UUID())")!
    } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      model.speedDownTapped()
      expectNoDifference(model.playbackRate, 0.75)
      model.speedDownTapped()
      expectNoDifference(model.playbackRate, 0.5)
      for _ in 0..<20 { model.speedDownTapped() }
      expectNoDifference(model.playbackRate, 0.5)  // clamped at the slowest preset
      expectNoDifference(model.canSpeedDown, false)
    }
  }

  @Test func speedSelectedClampsOutOfRange() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "speed-clamp-\(UUID())")!
    } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      model.speedSelected(10)
      expectNoDifference(model.playbackRate, model.maxRate)
      model.speedSelected(0.1)
      expectNoDifference(model.playbackRate, model.minRate)
    }
  }

  @Test func menuOptionsCoverEveryPresetAndFlagTheCurrent() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "speed-menu-\(UUID())")!
    } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      model.speedSelected(1.5)
      expectNoDifference(model.speedMenuOptions.map(\.rate), model.speedPresets)
      expectNoDifference(model.speedMenuOptions.filter(\.isCurrent).map(\.rate), [1.5])
    }
  }

  @Test func speedLabelFormatsWithTrimmedTrailingZero() {
    expectNoDifference(TranscriptPageModel.speedLabel(0.5), "0.5×")
    expectNoDifference(TranscriptPageModel.speedLabel(0.75), "0.75×")
    expectNoDifference(TranscriptPageModel.speedLabel(1.0), "1.0×")
    expectNoDifference(TranscriptPageModel.speedLabel(1.25), "1.25×")
    expectNoDifference(TranscriptPageModel.speedLabel(1.5), "1.5×")
    expectNoDifference(TranscriptPageModel.speedLabel(2.0), "2.0×")
    expectNoDifference(TranscriptPageModel.speedLabel(3.0), "3.0×")
  }
}
