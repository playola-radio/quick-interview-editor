import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct AppLaunchTests {

  @Test func devSkipsModelSetupAndGoesStraightToEditor() {
    let model = withDependencies {
      $0.modelDownloader.installedLocation = { _ in nil }
    } operation: {
      AppLaunchModel(requiresManagedModels: false)
    }
    #expect(!model.showsModelSetup)
    expectNoDifference(model.phase, .ready)
    #expect(model.modelSetup == nil)
  }

  @Test func packagedShowsModelSetupUntilReady() {
    let model = withDependencies {
      // Not yet installed -> the gate is presented.
      $0.modelDownloader.installedLocation = { _ in nil }
      $0.modelDownloader.download = { _ in AsyncThrowingStream { $0.finish() } }
    } operation: {
      AppLaunchModel(requiresManagedModels: true)
    }
    #expect(model.showsModelSetup)
    #expect(model.modelSetup != nil)
  }

  @Test func modelSetupCompletionAdvancesToEditor() async {
    let installation = ModelInstallation(
      whisperModelDir: URL(fileURLWithPath: "/Models/w"),
      alignModelDir: URL(fileURLWithPath: "/Models/align"))

    let model = withDependencies {
      $0.modelDownloader.installedLocation = { _ in installation }  // already installed
    } operation: {
      AppLaunchModel(requiresManagedModels: true)
    }

    // Driving the child model's viewAppeared (installed -> ready) flips the gate.
    await model.modelSetup?.viewAppeared()
    expectNoDifference(model.phase, .ready)
    #expect(!model.showsModelSetup)
  }
}
