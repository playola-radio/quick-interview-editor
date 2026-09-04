import Foundation

/// The live edge-drag stretch of a seam's crossfade: which seam, and the drafted length in SOURCE
/// samples. Non-nil only for the duration of a drag. The document is untouched while it lives —
/// `seamOverlays` previews the bowtie from it, and `crossfadeStretchEnded` is the one place that
/// commits (decision 7: draft-during-drag, one commit on mouse-up). Length only for now;
/// curve/center stay deferred. Shared by the main editor (`EditorModel`) and the slice-edit sheet
/// (`EditSliceModel`) so a stretch on either surface drafts and commits identically.
struct CrossfadeStretchDraft: Equatable {
  var id: TimelineRemoval.ID
  var length: Int
}
