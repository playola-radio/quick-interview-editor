import Foundation

/// A radio deliverable and its duration windows. Mirrors `ProductSpec` in the
/// Python contract (`cut_suggester/models.py`).
///
/// `target*` is the shipped shape (used for compliance metrics); `hard*` is the
/// generous acceptance range enforcement keeps, so a merged multi-paragraph story
/// is not discarded. Shipped products are EDITED, so durations are flexible.
struct ProductSpec: Codable, Equatable, Sendable {
  var productType: ProductType
  var targetMinSec: Double
  var targetMaxSec: Double
  var hardMinSec: Double
  var hardMaxSec: Double
  var description: String
}

extension ProductSpec {
  /// Pinned alongside the Python `PRODUCT_SPEC_VERSION` so a suggestion records the
  /// spec it was generated under (`CutSuggestion.Provenance.productSpecVersion`).
  static let version = "v1"

  /// ~40–120s target; accept 15–240s so merged stories survive.
  static let spotlight = ProductSpec(
    productType: .spotlight,
    targetMinSec: 40, targetMaxSec: 120,
    hardMinSec: 15, hardMaxSec: 240,
    description: "one self-contained story or anecdote (~40-120s)"
  )

  /// ~15–45s target; accept 12–75s.
  static let intro = ProductSpec(
    productType: .intro,
    targetMinSec: 15, targetMaxSec: 45,
    hardMinSec: 12, hardMaxSec: 75,
    description: "sets up ONE named song and ends on the handoff (~15-45s)"
  )

  /// The shipped defaults, one per product type.
  static let defaults: [ProductSpec] = [.spotlight, .intro]
}
