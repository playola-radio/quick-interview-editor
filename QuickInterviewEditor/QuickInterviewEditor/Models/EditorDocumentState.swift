import Foundation
import IdentifiedCollections

/// The editor's undoable document: slices and timeline removals move together, so
/// undo/redo restores both in one step. Deliberately excludes everything else the
/// editor tracks (selection, zoom, playback, export phase) — only the document itself.
struct EditorDocumentState: Equatable {
  var slices: IdentifiedArrayOf<Slice>
  var timelineRemovals: IdentifiedArrayOf<TimelineRemoval>
}
