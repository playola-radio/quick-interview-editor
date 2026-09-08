import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

/// Export behavior once `timelineRemovals` are in play: the render plan a removal produces,
/// the markers that survive it, and how the gating/warning surfaces react. `EditorRemovalTests`
/// already covers the gating predicates (`sliceIsExportable`, `canExportAll`) in isolation;
/// this file drives the removal-aware pieces through the real `performExport` pipeline.
@MainActor
struct EditorExportRemovalTests {
  @Test func generatedCollisionRetainsRenderUntilApprovedAndFreezesClipEdits() async throws {
    let model = editor(Fixtures.editPlan())
    var slice = Slice(
      id: Fixtures.uuid(1), name: "ID 1", startSample: 1000, endSample: 2000, wordIDs: [],
      snippet: "")
    slice.suggestionNaming = .init(
      runID: Fixtures.uuid(90), typeID: "image-id", typeName: "ID", typeGroup: .audioImages,
      discoveryLabel: "ID", extractedValues: [:], missingFieldIDs: [], correctedValues: [:],
      reservation: nil)
    model.slices = [slice]
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    let existing = destination.appendingPathComponent("ID 1.aiff")
    let original = Data("existing file".utf8)
    try original.write(to: existing)
    let jobs = LockIsolated<[ExportRenderJob]>([])
    try await withDependencies {
      $0.exportRender.renderSlice = { job in
        jobs.withValue { $0.append(job) }
        try writeStubAIFF(job)
      }
      $0.engine.injectMarkers = { _ in }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
      let review = try #require(model.exportReview)
      #expect(model.isExporting)
      #expect(!model.canUndo)
      let rendered = try #require(jobs.value.first?.outputURL)
      #expect(FileManager.default.fileExists(atPath: rendered.path))
      model.renameSlice(slice.id, to: "Changed")
      await model.deleteSlice(slice.id)
      expectNoDifference(model.slices.first?.name, "ID 1")
      review.exportWithSuffixesTapped()
      let approvedTask = model.exportTask
      review.exportWithSuffixesTapped()
      #expect(model.exportTask == approvedTask)
      #expect(model.exportReview === review)
      await model.exportTask?.value
      await approvedTask?.value
      expectNoDifference(model.exportPhase, .done(count: 1))
      expectNoDifference(jobs.value.count, 1)
      expectNoDifference(try Data(contentsOf: existing), original)
      #expect(
        FileManager.default.fileExists(
          atPath: destination.appendingPathComponent("ID 1 2.aiff").path))
      #expect(!FileManager.default.fileExists(atPath: rendered.path))
    }
  }

  @Test(arguments: [false, true])
  func cancellingReviewCleansScratchWithoutCopying(viaSheetDismissal: Bool) async throws {
    let model = editor(Fixtures.editPlan())
    var slice = Slice(
      id: Fixtures.uuid(1), name: "ID 1", startSample: 1000, endSample: 2000, wordIDs: [],
      snippet: "")
    slice.suggestionNaming = .init(
      runID: Fixtures.uuid(90), typeID: "image-id", typeName: "ID", typeGroup: .audioImages,
      discoveryLabel: "ID", extractedValues: [:], missingFieldIDs: [], correctedValues: [:],
      reservation: nil)
    model.slices = [slice]
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    try Data().write(to: destination.appendingPathComponent("ID 1.aiff"))
    let output = LockIsolated<URL?>(nil)
    try await withDependencies {
      $0.exportRender.renderSlice = { job in
        output.setValue(job.outputURL)
        try writeStubAIFF(job)
      }
      $0.engine.injectMarkers = { _ in }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
      let review = try #require(model.exportReview)
      if viaSheetDismissal {
        model.exportReview = nil
        model.exportReviewDismissed()
      } else {
        review.reviewNamesTapped()
      }
      await model.awaitExportTeardown()
      #expect(model.exportReview == nil)
      #expect(!model.isExporting)
      let rendered = try #require(output.value)
      #expect(!FileManager.default.fileExists(atPath: rendered.path))
      expectNoDifference(
        try FileManager.default.contentsOfDirectory(atPath: destination.path), ["ID 1.aiff"])
    }
  }

  @Test func partialCopyRaceCancelKeepsCopiedFileAndCleansRemainingRender() async throws {
    let model = editor(Fixtures.editPlan())
    model.slices = IdentifiedArray(
      uniqueElements: [1, 2].map { index in
        var slice = Slice(
          id: Fixtures.uuid(index), name: "ID \(index)", startSample: 1000, endSample: 2000,
          wordIDs: [], snippet: "")
        slice.suggestionNaming = .init(
          runID: Fixtures.uuid(90), typeID: "image-id", typeName: "ID", typeGroup: .audioImages,
          discoveryLabel: "ID", extractedValues: [:], missingFieldIDs: [], correctedValues: [:],
          reservation: nil)
        return slice
      })
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    let outputs = LockIsolated<[URL]>([])
    try await withDependencies {
      $0.exportRender.renderSlice = { job in
        outputs.withValue { $0.append(job.outputURL) }
        try writeStubAIFF(job)
      }
      $0.engine.injectMarkers = { _ in }
      $0.workspace.reveal = { _ in }
      $0.exportCopy.copy = { source, target in
        if target.lastPathComponent == "ID 2.aiff" {
          try Data("other writer".utf8).write(to: target)
          throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.copyItem(at: source, to: target)
      }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
      let review = try #require(model.exportReview)
      expectNoDifference(review.copied.count, 1)
      expectNoDifference(review.total, 2)
      #expect(outputs.value.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
      model.cancelExportTapped()
      await model.awaitExportTeardown()
      expectNoDifference(model.exportPhase, .failed("Export cancelled — 1 of 2 exported."))
      #expect(outputs.value.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
      #expect(
        FileManager.default.fileExists(atPath: destination.appendingPathComponent("ID 1.aiff").path)
      )
      #expect(
        !FileManager.default.fileExists(
          atPath: destination.appendingPathComponent("ID 2 2.aiff").path))
    }
  }

  @Test func lateDismissalCannotCancelARevisedCollisionReview() async throws {
    let model = editor(Fixtures.editPlan())
    var slice = Slice(
      id: Fixtures.uuid(1), name: "ID 1", startSample: 1000, endSample: 2000, wordIDs: [],
      snippet: "")
    slice.suggestionNaming = .init(
      runID: Fixtures.uuid(90), typeID: "image-id", typeName: "ID", typeGroup: .audioImages,
      discoveryLabel: "ID", extractedValues: [:], missingFieldIDs: [], correctedValues: [:],
      reservation: nil)
    model.slices = [slice]
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    try Data("original".utf8).write(to: destination.appendingPathComponent("ID 1.aiff"))
    let outputs = LockIsolated<[URL]>([])
    try await withDependencies {
      $0.exportRender.renderSlice = { job in
        outputs.withValue { $0.append(job.outputURL) }
        try writeStubAIFF(job)
      }
      $0.engine.injectMarkers = { _ in }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
      let first = try #require(model.exportReview)
      expectNoDifference(first.mappings.first?.proposedName, "ID 1 2.aiff")
      try Data("racing writer".utf8).write(to: destination.appendingPathComponent("ID 1 2.aiff"))
      first.exportWithSuffixesTapped()
      await model.exportTask?.value
      let revised = try #require(model.exportReview)
      expectNoDifference(revised.mappings.first?.proposedName, "ID 1 3.aiff")
      model.exportReviewDismissed()
      await model.exportTask?.value
      #expect(model.exportReview === revised)
      #expect(outputs.value.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
      revised.exportWithSuffixesTapped()
      await model.exportTask?.value
      expectNoDifference(model.exportPhase, .done(count: 1))
      expectNoDifference(outputs.value.count, 1)
      #expect(
        FileManager.default.fileExists(
          atPath: destination.appendingPathComponent("ID 1 3.aiff").path))
    }
  }
  /// Every model gets its own unique sidecar fingerprint so `mutateDocument`'s
  /// `persistTimelineRemovals` writes can never collide across tests (or with a real
  /// file's sidecar) — the same isolation `EditorSeamSelectionTests` gets from per-test
  /// fingerprints, without threading a name through every call site.
  private func editor(_ plan: EditPlan) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan,
      sourceFingerprint: "fp-export-removal-\(UUID().uuidString)")
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("qie-export-removal-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// A removal inside the slice must collapse the render plan's edited duration (source minus
  /// the removed span), not just leave a gap silently baked into the output — this is
  /// `SliceRenderPlanBuilder.plan` wired all the way through `performExport`'s render job.
  @Test func exportCollapsesRenderedAudioAroundARemoval() async throws {
    let plan = EditPlan(
      schemaVersion: 1,
      source: .init(path: "/clip.m4a", sampleRate: 44100, channels: 1, durationSamples: 100_000),
      words: [], silences: [], segments: [])
    let model = editor(plan)
    model.slices.append(
      Slice(
        id: UUID(), name: "A", startSample: 0, endSample: 20000, wordIDs: [], snippet: "x"))
    model.mutateDocument { doc in
      doc.timelineRemovals.append(
        TimelineRemoval(
          id: UUID(), removedRange: 5000..<8000,
          crossfade: Crossfade(lengthSamples: 0, curve: .equalPower)))
    }
    let renderedJobs = LockIsolated<[ExportRenderJob]>([])
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }

    await withDependencies {
      $0.exportRender.renderSlice = { job in
        renderedJobs.withValue { $0.append(job) }
        try writeStubAIFF(job)
      }
      $0.engine.injectMarkers = { _ in }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    expectNoDifference(model.exportPhase, .done(count: 1))
    // Slice is 20000 samples wide; the 3000-sample removal collapses it to 17000.
    expectNoDifference(renderedJobs.value.map(\.editedDurationSamples), [17000])
  }

  /// Markers injected into the rendered file are slice-relative EDITED positions (not the
  /// absolute source positions the plan stores words at): a marker whose word falls entirely
  /// inside the removed span is dropped, and the surviving markers land where the collapsed
  /// timeline actually put that audio.
  @Test func exportMarkersAreEditedPositionsWithRemovedWordsDropped() async throws {
    let plan = EditPlan(
      schemaVersion: 1,
      source: .init(path: "/clip.m4a", sampleRate: 44100, channels: 1, durationSamples: 100_000),
      words: [
        .init(id: 1, text: "a", start: 0, end: 0, startSample: 1000, endSample: 1500),
        .init(id: 2, text: "b", start: 0, end: 0, startSample: 6000, endSample: 6500),
        .init(id: 3, text: "c", start: 0, end: 0, startSample: 9000, endSample: 9500),
      ],
      silences: [], segments: [])
    let model = editor(plan)
    model.slices.append(
      Slice(
        id: UUID(), name: "A", startSample: 0, endSample: 20000, wordIDs: [1, 2, 3],
        snippet: "x"))
    model.mutateDocument { doc in
      doc.timelineRemovals.append(
        TimelineRemoval(
          id: UUID(), removedRange: 5000..<8000,
          crossfade: Crossfade(lengthSamples: 0, curve: .equalPower)))
    }
    let captured = LockIsolated<[MarkerInjectionFile]>([])
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }

    await withDependencies {
      $0.exportRender.renderSlice = { try writeStubAIFF($0) }
      $0.engine.injectMarkers = { files in captured.setValue(files) }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    // "b" (source 6000..<6500) sits entirely inside the removed 5000..<8000 span and is
    // dropped; "a" and "c" survive, remapped to their EDITED (post-collapse) positions:
    // "a" is untouched (before the removal), "c" shifts left by the 3000-sample cut.
    expectNoDifference(
      captured.value.first?.markers,
      [
        RenderMarker(position: 1000, name: "a"),
        RenderMarker(position: 6000, name: "c"),
      ])
  }

  /// When every slice's audio falls entirely inside a removed section, "Export all" has
  /// nothing left to offer — `canExportAll` must go false rather than let the button sit
  /// enabled with no exportable target.
  @Test func allSlicesRemovedDisablesExportAll() {
    let model = editor(Fixtures.editPlan())
    model.slices.append(
      Slice(
        id: UUID(), name: "A", startSample: 1000, endSample: 2000, wordIDs: [], snippet: "x"))
    model.slices.append(
      Slice(
        id: UUID(), name: "B", startSample: 3000, endSample: 4000, wordIDs: [], snippet: "x"))
    expectNoDifference(model.canExportAll, true)

    model.mutateDocument { doc in
      doc.timelineRemovals.append(
        TimelineRemoval(
          id: UUID(), removedRange: 500..<4500,
          crossfade: Crossfade(lengthSamples: 0, curve: .equalPower)))
    }

    #expect(!model.sliceIsExportable(model.slices[0]))
    #expect(!model.sliceIsExportable(model.slices[1]))
    expectNoDifference(model.canExportAll, false)
  }

  /// A slice with reversed bounds must read as unexportable, not trap forming its range —
  /// `sliceIsExportable` runs from `sliceRows` on every render.
  @Test func aSliceWithReversedBoundsIsUnexportableWithoutTrapping() {
    let model = editor(Fixtures.editPlan())
    let reversed = Slice(
      id: UUID(), name: "Broken", startSample: 5000, endSample: 4000, wordIDs: [],
      snippet: "x")
    #expect(!model.sliceIsExportable(reversed))
  }

  /// The bounds check the Python engine used to do: a stale slice whose range runs past the
  /// recording's end must fail the export with a clear message BEFORE any render job is
  /// issued, not trap forming a range or read past EOF inside the renderer.
  @Test func aSliceRangePastTheRecordingEndFailsTheExportBeforeRendering() async throws {
    let plan = EditPlan(
      schemaVersion: 1,
      source: .init(path: "/clip.m4a", sampleRate: 44100, channels: 1, durationSamples: 100_000),
      words: [], silences: [], segments: [])
    let model = editor(plan)
    model.slices.append(
      Slice(
        id: UUID(), name: "Stale", startSample: 90_000, endSample: 120_000, wordIDs: [],
        snippet: "x"))
    let renderedJobs = LockIsolated<[ExportRenderJob]>([])
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }

    await withDependencies {
      $0.exportRender.renderSlice = { job in
        renderedJobs.withValue { $0.append(job) }
        try writeStubAIFF(job)
      }
      $0.engine.injectMarkers = { _ in }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    if case .failed(let message) = model.exportPhase {
      #expect(message.contains("Stale"))
    } else {
      Issue.record("expected .failed, got \(model.exportPhase)")
    }
    expectNoDifference(renderedJobs.value, [])
  }

  /// Undo/redo rewind the document wholesale — mid-export that would make the finished AIFFs
  /// stale relative to what the user sees (same rationale as blocking new removals during an
  /// export). Blocked while the export runs, available again once it's done.
  @Test func undoIsBlockedWhileAnExportIsRunning() async throws {
    let plan = EditPlan(
      schemaVersion: 1,
      source: .init(path: "/clip.m4a", sampleRate: 44100, channels: 1, durationSamples: 100_000),
      words: [], silences: [], segments: [])
    let model = editor(plan)
    model.slices.append(
      Slice(
        id: UUID(), name: "A", startSample: 0, endSample: 20000, wordIDs: [], snippet: "x"))
    model.mutateDocument { doc in
      doc.timelineRemovals.append(
        TimelineRemoval(
          id: UUID(), removedRange: 5000..<8000,
          crossfade: Crossfade(lengthSamples: 0, curve: .equalPower)))
    }
    expectNoDifference(model.canUndo, true)
    let removalsBefore = model.timelineRemovals
    let (gateStream, gate) = AsyncStream.makeStream(of: Void.self)
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }

    await withDependencies {
      $0.exportRender.renderSlice = { job in
        try writeStubAIFF(job)
        // Suspend until the test releases the gate, so assertions run mid-export.
        for await _ in gateStream {}
      }
      $0.engine.injectMarkers = { _ in }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      expectNoDifference(model.canUndo, false)
      // A menu/shortcut invocation must no-op too, not just disable the button.
      await model.undoTapped()
      expectNoDifference(model.timelineRemovals, removalsBefore)
      gate.finish()
      await model.exportTask?.value
    }

    expectNoDifference(model.exportPhase, .done(count: 1))
    expectNoDifference(model.canUndo, true)
  }

  /// The removal set is frozen at the tap that passed the export gate: a document mutation
  /// landing between the tap and the render (the destination picker sits between them) must
  /// not change what gets rendered — the export ships exactly the timeline that enabled it.
  @Test func exportRendersTheRemovalSetThatGatedIt() async throws {
    let plan = EditPlan(
      schemaVersion: 1,
      source: .init(path: "/clip.m4a", sampleRate: 44100, channels: 1, durationSamples: 100_000),
      words: [], silences: [], segments: [])
    let model = editor(plan)
    model.slices.append(
      Slice(
        id: UUID(), name: "A", startSample: 0, endSample: 20000, wordIDs: [], snippet: "x"))
    model.mutateDocument { doc in
      doc.timelineRemovals.append(
        TimelineRemoval(
          id: UUID(), removedRange: 5000..<8000,
          crossfade: Crossfade(lengthSamples: 0, curve: .equalPower)))
    }
    let renderedJobs = LockIsolated<[ExportRenderJob]>([])
    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }

    await withDependencies {
      $0.exportRender.renderSlice = { job in
        renderedJobs.withValue { $0.append(job) }
        try writeStubAIFF(job)
      }
      $0.engine.injectMarkers = { _ in }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      // The export task hasn't run yet (it starts at the next suspension); a mutation
      // sneaking in here must not leak into the render.
      model.mutateDocument { doc in
        doc.timelineRemovals.append(
          TimelineRemoval(
            id: UUID(), removedRange: 10000..<15000,
            crossfade: Crossfade(lengthSamples: 0, curve: .equalPower)))
      }
      await model.exportTask?.value
    }

    expectNoDifference(model.exportPhase, .done(count: 1))
    // Only the first (gating-time) removal is rendered out: 20000 - 3000 = 17000. Had the
    // late removal leaked in, the edited duration would be 12000.
    expectNoDifference(renderedJobs.value.map(\.editedDurationSamples), [17000])
  }
}
