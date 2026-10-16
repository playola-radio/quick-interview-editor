import Foundation

enum TranscriptObjectID: Hashable, Sendable {
  case clip(UUID)
  case suggestion(UUID)
}

enum EditorSelection: Equatable, Sendable {
  case none
  case object(TranscriptObjectID)
  case range(Range<Int>, anchor: Int)
  /// Cmd-click pieces. Always ≥ 2 disjoint, non-abutting pieces; one piece is a `.range`.
  case ranges(MultiRangeSelection)
  case seam(UUID)

  var objectID: TranscriptObjectID? {
    guard case .object(let id) = self else { return nil }
    return id
  }

  /// Single-range only — nil for `.ranges`, so single-range features (fine-tune, audition, edge
  /// drag, nudge, Mark as Clip, open) stay unavailable for a multi-selection.
  var freeformRange: Range<Int>? {
    guard case .range(let range, _) = self else { return nil }
    return range
  }

  var selectedRanges: [Range<Int>] {
    switch self {
    case .range(let range, _): return [range]
    case .ranges(let multi): return multi.allRanges
    case .none, .object, .seam: return []
    }
  }

  /// Cmd-click: adds `piece` to a `.range`/`.ranges` selection. Add-only — a piece fully inside a
  /// selected piece is a no-op; a partial overlap extends that piece. Other selections are
  /// returned unchanged.
  func adding(_ piece: Range<Int>) -> EditorSelection {
    let primary: Range<Int>
    let anchor: Int
    let others: [Range<Int>]
    switch self {
    case .range(let range, let rangeAnchor):
      (primary, anchor, others) = (range, rangeAnchor, [])
    case .ranges(let multi):
      (primary, anchor, others) = (multi.primary, multi.anchor, multi.additional)
    case .none, .object, .seam:
      return self
    }
    let isContained = ([primary] + others).contains {
      $0.lowerBound <= piece.lowerBound && piece.upperBound <= $0.upperBound
    }
    guard !piece.isEmpty, !isContained else { return self }
    return Self.normalized(primary: primary, anchor: anchor, pieces: others + [piece])
  }

  /// Merges touching pieces (`pieces` may include `primary`). The merged piece holding `primary`
  /// stays primary and the anchor snaps to its nearest edge; a single piece demotes to `.range`.
  static func normalized(primary: Range<Int>, anchor: Int, pieces: [Range<Int>]) -> EditorSelection
  {
    let merged = ([primary] + pieces).mergingTouching()
    let newPrimary = merged.first { $0.contains(primary.lowerBound) } ?? primary
    let snappedAnchor: Int
    if anchor <= newPrimary.lowerBound {
      snappedAnchor = newPrimary.lowerBound
    } else if anchor >= newPrimary.upperBound {
      snappedAnchor = newPrimary.upperBound
    } else {
      snappedAnchor =
        anchor - newPrimary.lowerBound <= newPrimary.upperBound - anchor
        ? newPrimary.lowerBound : newPrimary.upperBound
    }
    let additional = merged.filter { $0 != newPrimary }
    guard !additional.isEmpty else { return .range(newPrimary, anchor: snappedAnchor) }
    return .ranges(
      MultiRangeSelection(primary: newPrimary, anchor: snappedAnchor, additional: additional))
  }
}

struct MultiRangeSelection: Equatable, Sendable {
  /// The piece the Shift-extend anchor belongs to.
  var primary: Range<Int>
  var anchor: Int
  /// Sorted, disjoint, and non-abutting with `primary`.
  var additional: [Range<Int>]

  var allRanges: [Range<Int>] {
    (additional + [primary]).sorted { $0.lowerBound < $1.lowerBound }
  }
}

struct SidebarReveal: Equatable, Sendable {
  let objectID: TranscriptObjectID
  let token: Int
}
