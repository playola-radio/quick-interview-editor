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

  @Test func filePickFailureIsSurfacedNotSwallowed() {
    let model = withDependencies {
      $0.engine.transcribe = { _ in neverCompleting() }
    } operation: {
      RootModel()
    }
    withKnownIssue {
      model.filePickFailed(NSError(domain: "test", code: 1))
    }
    #expect(model.tabs.isEmpty)  // no phantom tab created on a failed import
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

  @Test func closingATabCancelsAnInFlightExport() async throws {
    let plan = Fixtures.editPlan()
    let (stream, continuation) = AsyncThrowingStream<RenderEvent, Error>.makeStream()
    let terminated = LockIsolated(false)
    continuation.onTermination = { _ in terminated.setValue(true) }
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-root-export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: destination) }

    try await withDependencies {
      $0.engine.transcribe = { _ in
        AsyncThrowingStream {
          $0.yield(.completed(Fixtures.transcriptionResult(plan)))
          $0.finish()
        }
      }
      $0.engine.renderSlices = { _ in stream }
      $0.workspace.reveal = { _ in }
      $0.audioPlayer.stop = {}  // closeTab also stops playback
    } operation: {
      let model = RootModel()
      model.filePicked(URL(fileURLWithPath: "/clip.m4a"))
      let tabID = model.tabs.first!.id
      for _ in 0..<1000 where model.tabs[id: tabID]?.editor == nil { await Task.yield() }
      let editor = try #require(model.tabs[id: tabID]?.editor)

      editor.destinationURL = destination
      editor.slices.append(
        Slice(
          id: UUID(), name: "A", startSample: 0, endSample: 100, wordIDs: [], snippet: "x",
          warnings: []))
      editor.exportAllTapped()
      #expect(editor.isExporting)

      model.closeTab(tabID)  // must cancel the export, not let it outlive the tab
      await editor.exportTask?.value
      #expect(terminated.value)
      guard case .failed = editor.exportPhase else {
        Issue.record("expected .failed after close, got \(editor.exportPhase)")
        return
      }
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

  @Test func closingATabRemovesItsCanonicalAudio() async throws {
    // Seed a real cached canonical AIFF, then drive a tab whose completion carries
    // its URL; closing the tab must delete the cache dir.
    let planAIFF = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-root-canonical-\(UUID().uuidString).aiff")
    try Data("canonical".utf8).write(to: planAIFF)
    defer { try? FileManager.default.removeItem(at: planAIFF) }
    let canonical = try CanonicalAudioStore.store(planAIFF: planAIFF)
    let plan = Fixtures.editPlan()

    await withDependencies {
      $0.engine.transcribe = { _ in
        AsyncThrowingStream {
          $0.yield(.completed(Fixtures.transcriptionResult(plan, canonicalAudioURL: canonical)))
          $0.finish()
        }
      }
      $0.audioPlayer.stop = {}  // closeTab also stops playback
    } operation: {
      let model = RootModel()
      model.filePicked(URL(fileURLWithPath: "/clip.m4a"))
      let tabID = model.tabs.first!.id
      for _ in 0..<1000 where model.tabs[id: tabID]?.editor == nil { await Task.yield() }
      #expect(FileManager.default.fileExists(atPath: canonical.path))
      model.closeTab(tabID)
      #expect(!FileManager.default.fileExists(atPath: canonical.path))
    }
  }
}
