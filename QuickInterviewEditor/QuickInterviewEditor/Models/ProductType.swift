import Foundation

/// The two Playola radio deliverables a cut suggestion targets. Raw values mirror
/// the Python cut-suggester contract (`cut_suggester/models.py`) so Swift and the
/// eval agree on the wire label.
struct ProductType: RawRepresentable, Hashable, Codable, Sendable {
  let rawValue: String

  init?(rawValue: String) {
    guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    self.rawValue = rawValue
  }

  static let intro = ProductType(rawValue: "intro")!
  static let spotlight = ProductType(rawValue: "spotlight")!

  init(from decoder: any Decoder) throws {
    let rawValue = try decoder.singleValueContainer().decode(String.self)
    guard let value = Self(rawValue: rawValue) else {
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(), debugDescription: "Product type ID cannot be blank."
      )
    }
    self = value
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  /// User-facing label (zero-logic-in-views: the view binds this, never a literal).
  var displayLabel: String {
    switch self {
    case .intro: "Intro"
    case .spotlight: "Artist Spotlight"
    default: rawValue
    }
  }
}
