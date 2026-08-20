import Foundation

/// Everything needed to render ONE slice of an edited timeline: a render plan whose
/// source ranges are ABSOLUTE (canonical-file coordinates) but whose edited axis is
/// slice-local (0 ..< `editedDurationSamples`).
struct SliceRenderPlan: Equatable {
  var plan: AudioEditRenderPlan
  var localTimeline: EditedTimeline
  var sliceStart: Int
  var editedDurationSamples: Int
}

/// Builds the slice-LOCAL view of a document's removals (design spec §3 composition
/// rule): a slice export clips to the slice's own source range, so a crossfade may
/// never pull audio from outside it. Intersecting the removals with the slice and
/// rebasing them to slice-relative coordinates lets `EditedTimeline`'s own handle
/// clamping do the rest — a removal straddling a slice edge has no handle on that
/// side and collapses to a hard cut, and a removal covering the whole slice leaves
/// nothing to export.
enum SliceRenderPlanBuilder {

  /// The slice-local timeline: removals clipped to `sliceRange` and rebased so source
  /// sample 0 is the slice's first sample. Crossfade lengths are passed through as
  /// stored — `EditedTimeline.init` owns all clamping.
  static func localTimeline(sliceRange: Range<Int>, removals: [TimelineRemoval]) -> EditedTimeline {
    let rebased = removals.compactMap { removal -> TimelineRemoval? in
      let clipped = removal.removedRange.clamped(to: sliceRange)
      guard !clipped.isEmpty else { return nil }
      var updated = removal
      updated.removedRange =
        (clipped.lowerBound - sliceRange.lowerBound)..<(clipped.upperBound - sliceRange.lowerBound)
      return updated
    }
    return EditedTimeline(sourceDurationSamples: sliceRange.count, removals: rebased)
  }

  static func plan(sliceRange: Range<Int>, removals: [TimelineRemoval]) -> SliceRenderPlan {
    let timeline = localTimeline(sliceRange: sliceRange, removals: removals)
    return SliceRenderPlan(
      plan: AudioEditRenderPlan(timeline: timeline).offsettingSources(by: sliceRange.lowerBound),
      localTimeline: timeline,
      sliceStart: sliceRange.lowerBound,
      editedDurationSamples: timeline.editedDurationSamples)
  }

  /// Maps ABSOLUTE source marker positions (word starts, in spoken order) to
  /// slice-relative EDITED positions. Markers outside the slice, or inside a removal,
  /// are dropped. Ties are nudged one frame forward — the same invariant as
  /// `EditorModel.renderRequest` and the engine's `build_markers`, so two markers can
  /// never stack or get reordered by Logic. A marker that lands at or past the end of
  /// the rendered audio is dropped: Logic has nothing to mark there.
  static func markers(
    _ markers: [RenderMarker],
    sliceRange: Range<Int>,
    localTimeline: EditedTimeline
  ) -> [RenderMarker] {
    let editedDuration = localTimeline.editedDurationSamples
    var lastPosition = Int.min
    var result: [RenderMarker] = []
    for marker in markers {
      guard sliceRange.contains(marker.position) else { continue }
      guard
        var edited = localTimeline.editedSample(
          forSource: marker.position - sliceRange.lowerBound)
      else { continue }
      if edited <= lastPosition { edited = lastPosition + 1 }
      lastPosition = edited
      guard edited < editedDuration else { continue }
      result.append(RenderMarker(position: edited, name: marker.name))
    }
    return result
  }
}
