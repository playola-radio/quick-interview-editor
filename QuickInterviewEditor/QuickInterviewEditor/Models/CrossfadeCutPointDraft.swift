import Foundation

/// Which bound of a `TimelineRemoval.removedRange` a cut-point drag/nudge moves. `.lower` is the
/// left cut `cL` (grabbed via the outside audio left of the bowtie); `.upper` is the right cut `cR`
/// (grabbed via the outside audio right of the bowtie). Distinct from `CrossfadeEdge` (leading/
/// trailing bowtie edges, which drive length) because on the edited axis the overlap inverts the
/// mapping — `cL` sits at the trailing edge, `cR` at the leading edge — so a dedicated,
/// unambiguous type keeps the removal-bound intent clear.
enum RemovalBoundary: Equatable {
  case lower
  case upper
}

/// Transient view-state for an in-progress crossfade cut-point drag: the moving bound, the committed
/// and drafted removal ranges, the frozen EFFECTIVE fade length (pinned across the move), the whole
/// committed timeline frozen at drag begin (the invalidation baseline), and the viewport geometry
/// frozen at drag begin. Mirrors `CrossfadeStretchDraft`: the document is untouched mid-drag (only the
/// adapter's preview timeline reflows); the single commit lands on mouse-up. Drag math maps x → edited
/// sample against the FROZEN viewport so the live reflow (which shifts content under the pointer) can't
/// feed back on itself.
///
/// `frozenCommittedTimeline` is the drop trigger: the drafted range was clamped against this exact
/// layout, so if ANY committed removal changes underneath a live drag (an undo/redo of this seam OR a
/// neighbor, a nudge, a restore) the draft is stale and must not commit. Comparing the whole timeline
/// catches neighbor-only reflows that leave this seam's own range and effective fade length unchanged
/// yet still move its clamp bounds.
struct CrossfadeCutPointDraft: Equatable {
  var id: UUID
  var edge: RemovalBoundary
  var committedRange: Range<Int>
  var draftedRange: Range<Int>
  var frozenCrossfadeLength: Int
  var frozenCommittedTimeline: EditedTimeline
  var dragStartEditedSample: Int
  var frozenVisibleStart: Int
  var frozenSamplesPerPixel: Double
}
