import CustomDump
import Dependencies
import Foundation
import Sharing
import Testing

@testable import QuickInterviewEditor

@MainActor
struct TranscriptZoomTests {
  @Test func defaultFontSizeIs17() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "zoom-default")!
    } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      expectNoDifference(model.fontSize, 17)
    }
  }

  @Test func zoomInAndOutStepBy2AndClamp() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "zoom-step-\(UUID())")!
    } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      model.zoomInTapped()
      expectNoDifference(model.fontSize, 19)
      for _ in 0..<20 { model.zoomInTapped() }
      expectNoDifference(model.fontSize, model.maxFontSize)  // clamped at 36
      expectNoDifference(model.canZoomIn, false)
      for _ in 0..<40 { model.zoomOutTapped() }
      expectNoDifference(model.fontSize, model.minFontSize)  // clamped at 11
      expectNoDifference(model.canZoomOut, false)
    }
  }

  @Test func zoomResetReturnsTo17() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "zoom-reset-\(UUID())")!
    } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      model.zoomInTapped()
      model.zoomResetTapped()
      expectNoDifference(model.fontSize, 17)
    }
  }

  @Test func zoomChangedClampsToBounds() {
    withDependencies {
      $0.defaultAppStorage = UserDefaults(suiteName: "zoom-clamp-\(UUID())")!
    } operation: {
      let model = TranscriptPageModel(editPlan: .fixture)
      model.zoomChanged(100)
      expectNoDifference(model.fontSize, model.maxFontSize)
      model.zoomChanged(1)
      expectNoDifference(model.fontSize, model.minFontSize)
    }
  }
}
