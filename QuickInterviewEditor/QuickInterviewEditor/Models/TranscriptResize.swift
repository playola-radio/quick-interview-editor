import Foundation

/// Tuning constants for the resize-handle overlay: how close a click/drag needs to be to an
/// edge to grab it, and how far a drag must travel before it counts as a resize gesture.
enum TranscriptResizeMetrics {
  static let grabTolerance: CGFloat = 6
  static let dragThreshold: CGFloat = 6
}

enum TranscriptResizeEdge: Equatable, Sendable { case start, end }

enum TranscriptResizeItemIdentity: Equatable, Hashable, Sendable {
  case selection
  case clip(Slice.ID)
  case suggestion(CutSuggestion.ID)

  /// D2 priority: Selection > Clip > Suggestion.
  var priority: Int {
    switch self {
    case .selection: 3
    case .clip: 2
    case .suggestion: 1
    }
  }
}

/// The semantic (non-occluded) span of a resizable item, in transcript order.
struct TranscriptResizeItem: Equatable, Sendable {
  var identity: TranscriptResizeItemIdentity
  var wordIDs: [Word.ID]
}

/// A grab zone published by the coordinator to the overlay.
struct TranscriptResizeHandleZone: Equatable {
  var identity: TranscriptResizeItemIdentity
  var edge: TranscriptResizeEdge
  var rect: CGRect
  var priority: Int
}

/// In-flight resize. Non-nil only for the duration of a drag; the document is
/// untouched while it lives.
struct TranscriptResizeDraft: Equatable, Sendable {
  var identity: TranscriptResizeItemIdentity
  var edge: TranscriptResizeEdge
  var originalWordIDs: [Word.ID]
  var draftedWordIDs: [Word.ID]
  /// The exact `audioSelection` at grab time, captured only for `.selection` drafts so cancel
  /// restores it precisely instead of expanding a freeform selection to whole-word bounds.
  var originalSelectionRange: Range<Int>?
}

enum TranscriptResizeMath {
  /// New contiguous word run after dragging `edge` to `target`. Whole-word snap,
  /// min one word, cannot cross the opposite edge. `nil` when inputs are invalid.
  static func resized(
    itemWordIDs: [Word.ID],
    edge: TranscriptResizeEdge,
    toTargetWord target: Word.ID,
    transcriptOrder: [Word.ID]
  ) -> [Word.ID]? {
    guard !itemWordIDs.isEmpty else { return nil }
    var position: [Word.ID: Int] = [:]
    for (index, id) in transcriptOrder.enumerated() where position[id] == nil {
      position[id] = index
    }
    guard let targetIndex = position[target] else { return nil }
    let itemIndices = itemWordIDs.compactMap { position[$0] }
    guard itemIndices.count == itemWordIDs.count,
      let first = itemIndices.min(), let last = itemIndices.max()
    else { return nil }

    let lo: Int
    let hi: Int
    switch edge {
    case .start:
      lo = min(max(targetIndex, 0), last)
      hi = last
    case .end:
      lo = first
      hi = max(min(targetIndex, transcriptOrder.count - 1), first)
    }
    return Array(transcriptOrder[lo...hi])
  }
}
