import CustomDump
import Dependencies
import Foundation
import IdentifiedCollections
import Testing

@testable import QuickInterviewEditor

/// Stand-in for `exportRender.renderSlice`: writes a stub AIFF at the job's output URL. Free
/// (non-isolated) function so it can be called directly from a `@Sendable` test override
/// without crossing back onto `EditorExportRemovalTests`'s `@MainActor` isolation.
private func writeStubAIFF(_ job: ExportRenderJob) throws {
  try Data("aiff".utf8).write(to: job.outputURL)
}

/// Export behavior once `timelineRemovals` are in play: the render plan a removal produces,
/// the markers that survive it, and how the gating/warning surfaces react. `EditorRemovalTests`
/// already covers the gating predicates (`sliceIsExportable`, `canExportAll`) in isolation;
/// this file drives the removal-aware pieces through the real `performExport` pipeline.
@MainActor
struct EditorExportRemovalTests {
  private func editor(_ plan: EditPlan) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan)
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
}
