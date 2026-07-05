import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing
@testable import QuickInterviewEditor

private func neverCompleting() -> AsyncThrowingStream<EngineEvent, Error> {
  AsyncThrowingStream { _ in }  // holds the tab in .transcribing; no completion
}

@MainActor
struct RootTests {
  @Test func startsEmpty() {
    let model = withDependencies { $0.engine.transcribe = { _ in AsyncThrowingStream { $0.finish() } } }
      operation: { RootModel() }
    #expect(model.tabs.isEmpty)
    #expect(model.showsEmptyState)
  }

  @Test func openingAFileAddsAndSelectsATab() {
    withDependencies {
      $0.engine.transcribe = { _ in neverCompleting() }
    } operation: {
      let model = RootModel()
      model.filePicked(URL(fileURLWithPath: "/a/clip.m4a"))
      expectNoDifference(model.tabs.count, 1)
      #expect(model.selectedTabID == model.tabs.last?.id)
      #expect(!model.showsEmptyState)
    }
  }

  @Test func droppingTwoFilesOpensTwoTabs() {
    withDependencies {
      $0.engine.transcribe = { _ in neverCompleting() }
    } operation: {
      let model = RootModel()
      model.fileDropped([URL(fileURLWithPath: "/a.m4a"), URL(fileURLWithPath: "/b.m4a")])
      expectNoDifference(model.tabs.count, 2)
    }
  }

  @Test func closingATabRemovesItAndFixesSelection() {
    withDependencies {
      $0.engine.transcribe = { _ in neverCompleting() }
    } operation: {
      let model = RootModel()
      model.fileDropped([URL(fileURLWithPath: "/a.m4a"), URL(fileURLWithPath: "/b.m4a")])
      let first = model.tabs[0].id
      model.closeTab(first)
      expectNoDifference(model.tabs.count, 1)
      #expect(model.tabs[id: first] == nil)
      #expect(model.selectedTabID == model.tabs.first?.id)
    }
  }
}
