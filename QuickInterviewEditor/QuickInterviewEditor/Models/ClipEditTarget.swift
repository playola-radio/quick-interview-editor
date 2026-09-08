import Foundation

enum ClipEditTarget: Equatable, Sendable {
  case savedClip(UUID)
  case suggestionDraft(CutSuggestion)
  case freeformDraft(UUID)

  var isDraft: Bool {
    if case .savedClip = self { return false }
    return true
  }

  var resultingClipID: UUID {
    switch self {
    case .savedClip(let id), .freeformDraft(let id): id
    case .suggestionDraft(let suggestion): suggestion.id
    }
  }
}

enum ClipEditCommitResult: Equatable, Sendable {
  case committed
  case failed(String)
}
