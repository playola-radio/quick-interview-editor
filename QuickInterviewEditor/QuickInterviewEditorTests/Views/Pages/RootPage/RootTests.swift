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
    let model = withDependencies {
      $0.engine.transcribe = { _ in AsyncThrowingStream { $0.finish() } }
    } operation: {
      RootModel()
    }
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
      // The last-opened tab is the selected one; closing IT exercises the
      // `if wasSelected { … }` re-selection branch.
      let selected = model.selectedTabID!
      model.closeTab(selected)
      expectNoDifference(model.tabs.count, 1)
      #expect(model.tabs[id: selected] == nil)
      #expect(model.selectedTabID != selected)
      #expect(model.selectedTabID == model.tabs.last?.id)
    }
  }

  @Test func nonAudioDropsAreIgnored() {
    withDependencies {
      $0.engine.transcribe = { _ in neverCompleting() }
    } operation: {
      let model = RootModel()
      model.fileDropped([
        URL(fileURLWithPath: "/doc.pdf"),
        URL(fileURLWithPath: "/song.m4a"),
        URL(fileURLWithPath: "/image.png"),
      ])
      expectNoDifference(model.tabs.count, 1)  // only the audio file opens a tab
      expectNoDifference(model.tabs.first?.title, "song")
    }
  }

  @Test func dropsBeyondTheCapAreQueued() {
    withDependencies {
      $0.engine.transcribe = { _ in neverCompleting() }
    } operation: {
      let model = RootModel()
      model.fileDropped([
        URL(fileURLWithPath: "/a.m4a"),
        URL(fileURLWithPath: "/b.m4a"),
        URL(fileURLWithPath: "/c.m4a"),
      ])
      expectNoDifference(model.tabs.count, 3)
      // Only `maxConcurrentTranscriptions` (2) run; the rest wait in .queued.
      expectNoDifference(
        model.tabs.filter(\.isTranscribing).count, model.maxConcurrentTranscriptions)
      expectNoDifference(model.tabs.filter(\.isQueued).count, 1)
    }
  }

  @Test func closingARunningTabPromotesAQueuedOne() {
    withDependencies {
      $0.engine.transcribe = { _ in neverCompleting() }
    } operation: {
      let model = RootModel()
      model.fileDropped([
        URL(fileURLWithPath: "/a.m4a"),
        URL(fileURLWithPath: "/b.m4a"),
        URL(fileURLWithPath: "/c.m4a"),
      ])
      let running = model.tabs.first(where: \.isTranscribing)!.id
      model.closeTab(running)
      expectNoDifference(model.tabs.count, 2)
      expectNoDifference(model.tabs.filter(\.isTranscribing).count, 2)  // queued one promoted
      expectNoDifference(model.tabs.filter(\.isQueued).count, 0)
    }
  }
}
