import Foundation

/// The two Playola radio deliverables a cut suggestion targets. Raw values mirror
/// the Python cut-suggester contract (`cut_suggester/models.py`) so Swift and the
/// eval agree on the wire label.
enum ProductType: String, Codable, Equatable, Sendable, CaseIterable {
  case intro
  case spotlight

  /// User-facing label (zero-logic-in-views: the view binds this, never a literal).
  var displayLabel: String {
    switch self {
    case .intro: "Intro"
    case .spotlight: "Artist Spotlight"
    }
  }
}
