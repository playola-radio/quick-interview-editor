import Foundation

/// Tuning constants for the resize-handle overlay: how close a click/drag needs to be to an
/// edge to grab it, and how far a drag must travel before it counts as a resize gesture.
enum TranscriptResizeMetrics {
  static let grabTolerance: CGFloat = 6
  static let dragThreshold: CGFloat = 6
}

enum TranscriptResizeEdge: Equatable, Sendable {
  case start, end

  /// Stable ordinal for the deterministic hit-resolution tie-break.
  fileprivate var tieBreakOrdinal: Int { self == .start ? 0 : 1 }
}

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

  /// Stable descriptor for the deterministic hit-resolution tie-break among zones that share
  /// both priority and edge-distance, so hit-testing resolves the same handle every time.
  fileprivate var tieBreakDescriptor: String {
    switch self {
    case .selection: "selection"
    case .clip(let id): "clip:\(id)"
    case .suggestion(let id): "suggestion:\(id)"
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
  /// The transcript gesture anchor/focus at grab time, captured only for `.selection` drafts so
  /// cancel can restore the Shift-extend pivot the drag's `applyEdgeEdit` invalidated.
  var originalAnchorID: Word.ID?
  var originalFocusID: Word.ID?
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

  /// D2 hit resolution: among the zones whose `rect` contains `point`, the highest `priority`
  /// wins (Selection > Clip > Suggestion); ties break by nearest edge-x, then by a stable
  /// identity/edge key so hit-testing never flickers between equally-eligible zones. `nil` when
  /// no zone contains the point. The zone geometry lives in the coordinator; this is the pure
  /// resolution over it.
  static func resolveHandle(
    hitting point: CGPoint, in zones: [TranscriptResizeHandleZone]
  ) -> (TranscriptResizeItemIdentity, TranscriptResizeEdge)? {
    let hits = zones.filter { $0.rect.contains(point) }
    guard
      let best = hits.max(by: { lhs, rhs in
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        let ldx = abs(point.x - lhs.rect.midX)
        let rdx = abs(point.x - rhs.rect.midX)
        if ldx != rdx { return ldx > rdx }
        return (lhs.identity.tieBreakDescriptor, lhs.edge.tieBreakOrdinal)
          > (rhs.identity.tieBreakDescriptor, rhs.edge.tieBreakOrdinal)
      })
    else { return nil }
    return (best.identity, best.edge)
  }
}
