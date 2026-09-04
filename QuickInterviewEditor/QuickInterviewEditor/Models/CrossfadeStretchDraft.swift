import Foundation

/// The live edge-drag stretch of a seam's crossfade: which seam, and the drafted length in SOURCE
/// samples. Non-nil only for the duration of a drag. The document is untouched while it lives — the
/// main editor reflows a preview timeline into the waveform adapter from it (downstream content
/// moves live, so the release repositions nothing), the slice sheet previews the bowtie
/// center-anchored from it, and `crossfadeStretchEnded` is the one place that commits (decision 7:
/// draft-during-drag, one commit on mouse-up). Length only for now;
/// curve/center stay deferred. Shared by the main editor (`EditorModel`) and the slice-edit sheet
/// (`EditSliceModel`) so a stretch on either surface drafts and commits identically.
struct CrossfadeStretchDraft: Equatable {
  var id: TimelineRemoval.ID
  var length: Int
  /// The rendered (clamped) crossfade length when the drag began — the baseline for the viewport
  /// compensation (ΔL = `length − committedLength`). Defaults keep the plain `id`/`length`
  /// construction the tests and the modal use valid.
  var committedLength: Int = 0
  /// Twice the seam's exact edited center (`2·start + length`) when the drag began, frozen so
  /// cursor→length maps against a stable axis even as the live preview reflows the timeline
  /// underneath. Doubled (not the rounded center) so odd lengths stay reachable — see
  /// `TimelineSeam.editedCrossfadeDoubledCenter`.
  var committedDoubledCenterEdited: Int = 0
  /// The viewport when the drag began, frozen so cursor→edited-sample stays stable while the
  /// preview shifts the live viewport to keep the seam growing symmetrically on screen.
  var frozenVisibleStart: Int = 0
  var frozenSamplesPerPixel: Double = 0
}
