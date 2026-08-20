import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing

@testable import QuickInterviewEditor

/// Export behavior once `timelineRemovals` are in play: the render plan a removal produces,
/// the markers that survive it, and how the gating/warning surfaces react. `EditorRemovalTests`
/// already covers the gating predicates (`sliceIsExportable`, `canExportAll`) in isolation;
/// this file drives the removal-aware pieces through the real `performExport` pipeline.
@MainActor
struct EditorExportRemovalTests {
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
        id: UUID(), name: "A", startSample: 0, endSample: 20000, wordIDs: [], snippet: "x",
        warnings: []))
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
        snippet: "x", warnings: []))
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
        id: UUID(), name: "A", startSample: 1000, endSample: 2000, wordIDs: [], snippet: "x",
        warnings: []))
    model.slices.append(
      Slice(
        id: UUID(), name: "B", startSample: 3000, endSample: 4000, wordIDs: [], snippet: "x",
        warnings: []))
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

  /// `exportWarnings(for:)` recomputes tight-join status from the EXPORT-effective boundary
  /// (post-removal), not the slice's own stored `warnings` (computed once, at creation, from
  /// its original cut points): a removal that eats the slice's original start moves the
  /// effective start deeper into the file, which can turn a join that was never tight into one
  /// that is — and the stored `warnings` field has no way to know that after the fact.
  @Test func exportWarningsReflectARemovalShiftedBoundaryNotTheStoredWarnings() async throws {
    let plan = EditPlan(
      schemaVersion: 1,
      source: .init(path: "/clip.m4a", sampleRate: 44100, channels: 1, durationSamples: 100_000),
      words: [], silences: [], segments: [])
    let model = editor(plan)
    let slice = Slice(
      id: UUID(), name: "Intro", startSample: 0, endSample: 20000, wordIDs: [], snippet: "x",
      warnings: [])  // stored at creation: starts at sample 0, so no tight-start warning.
    model.slices.append(slice)
    model.mutateDocument { doc in
      doc.timelineRemovals.append(
        TimelineRemoval(
          id: UUID(), removedRange: 0..<3000,
          crossfade: Crossfade(lengthSamples: 0, curve: .equalPower)))
    }

    // The stored warnings are stale (still empty)...
    expectNoDifference(model.slices[id: slice.id]?.warnings, [])
    // ...but the export-effective start is now sample 3000, away from any silence, so both
    // edges are freshly tight.
    expectNoDifference(
      model.exportWarnings(for: model.slices[id: slice.id]!), [.tightStart, .tightEnd])

    let destination = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: destination) }
    await withDependencies {
      $0.exportRender.renderSlice = { try writeStubAIFF($0) }
      $0.engine.injectMarkers = { _ in }
      $0.workspace.reveal = { _ in }
    } operation: {
      model.destinationURL = destination
      model.exportAllTapped()
      await model.exportTask?.value
    }

    #expect(model.exportTightWarning.contains("Intro"))
  }

  /// A slice with reversed bounds must read as unexportable (and warn nothing), not trap
  /// forming its range — `sliceIsExportable` runs from `sliceRows` on every render.
  @Test func aSliceWithReversedBoundsIsUnexportableWithoutTrapping() {
    let model = editor(Fixtures.editPlan())
    let reversed = Slice(
      id: UUID(), name: "Broken", startSample: 5000, endSample: 4000, wordIDs: [],
      snippet: "x", warnings: [])
    #expect(!model.sliceIsExportable(reversed))
    expectNoDifference(model.exportWarnings(for: reversed), [])
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
        snippet: "x", warnings: []))
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
        id: UUID(), name: "A", startSample: 0, endSample: 20000, wordIDs: [], snippet: "x",
        warnings: []))
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
        id: UUID(), name: "A", startSample: 0, endSample: 20000, wordIDs: [], snippet: "x",
        warnings: []))
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
