import Foundation

/// Which bowtie edge a crossfade stretch drag grabbed. Center-offset is deferred, so the fade stays
/// centered on the cut: dragging either edge outward lengthens the one `lengthSamples` value
/// symmetrically. Both edges drive the same length; the edge only sets the sign. Kept a top-level
/// domain enum (like `SelectionEdge`) so the reusable waveform lane and `EditorModel` share it.
enum CrossfadeEdge: Equatable {
  case leading
  case trailing
}
