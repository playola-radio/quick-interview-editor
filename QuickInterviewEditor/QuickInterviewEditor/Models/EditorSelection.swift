import Foundation

enum TranscriptObjectID: Hashable, Sendable {
  case clip(UUID)
  case suggestion(UUID)
}

enum EditorSelection: Equatable, Sendable {
  case none
  case object(TranscriptObjectID)
  case range(Range<Int>, anchor: Int)
  case seam(UUID)

  var objectID: TranscriptObjectID? {
    guard case .object(let id) = self else { return nil }
    return id
  }

  var freeformRange: Range<Int>? {
    guard case .range(let range, _) = self else { return nil }
    return range
  }
}

struct SidebarReveal: Equatable, Sendable {
  let objectID: TranscriptObjectID
  let token: Int
}
