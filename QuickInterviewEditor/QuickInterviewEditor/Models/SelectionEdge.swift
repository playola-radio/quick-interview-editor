import Foundation

/// Which edge of the freeform audio selection an edit gesture is moving. Kept
/// separate from `SliceEdge` (fine-tune) so the two domains stay decoupled.
enum SelectionEdge: Equatable {
  case start
  case end
}
