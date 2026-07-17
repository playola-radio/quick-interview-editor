import Foundation

/// Which cut a fine-tune gesture is moving: the slice's start (Cut in) or end (Cut out).
enum SliceEdge: Equatable {
  case start
  case end
}

/// The session-constant limits a boundary drag must respect: the magnified inset `window`
/// it can't leave, the file length, and the minimum slice duration. Grouped so the boundary
/// helpers stay readable and the caller passes one value everywhere.
struct BoundaryConstraints: Equatable {
  var window: ClosedRange<Int>
  var durationSamples: Int
  var minDurationSamples: Int
}

/// The legal sample interval a single boundary may move within, combining three limits:
/// the file bounds `0...durationSamples`, the fixed opposite boundary (so the slice keeps
/// at least `minDurationSamples`), and the inset `window` (the boundary can't leave the
/// magnified view it's dragged in). Returned as a closed range so a snap target sitting
/// exactly on a limit is still reachable. Degenerate inputs collapse to a single point at
/// the lower bound rather than inverting.
func legalBoundaryRange(
  moving edge: SliceEdge, opposite: Int, constraints: BoundaryConstraints
) -> ClosedRange<Int> {
  let window = constraints.window
  let lower: Int
  let upper: Int
  switch edge {
  case .start:
    lower = max(0, window.lowerBound)
    upper = min(
      window.upperBound, opposite - constraints.minDurationSamples, constraints.durationSamples)
  case .end:
    lower = max(0, window.lowerBound, opposite + constraints.minDurationSamples)
    upper = min(window.upperBound, constraints.durationSamples)
  }
  // Clamp both ends into the file before ordering: near EOF the min-duration lower can exceed
  // `durationSamples` (an unsatisfiably short slice), and it must never let a draft run past
  // the file — the engine rejects an out-of-range cut. The anchor stays `lower` so a window /
  // min-duration contradiction still collapses to the window edge rather than inverting.
  let boundedLower = min(max(lower, 0), constraints.durationSamples)
  let boundedUpper = min(max(upper, 0), constraints.durationSamples)
  return boundedLower...max(boundedLower, boundedUpper)
}

/// Clamps a proposed boundary sample into its legal interval. Side-aware on purpose: a
/// whole-range clamp with no notion of which edge moved would invent intent (which side
/// should yield?). The caller says which edge is moving and where the fixed one is.
func clampedBoundary(
  _ proposed: Int, moving edge: SliceEdge, opposite: Int, constraints: BoundaryConstraints
) -> Int {
  let legal = legalBoundaryRange(moving: edge, opposite: opposite, constraints: constraints)
  return min(max(proposed, legal.lowerBound), legal.upperBound)
}

/// Nearest detected silence edge (a `startSample` or `endSample`) to `sample`, but only
/// among edges that lie inside `legalRange` and within `thresholdSamples` — comparing in
/// SAMPLES, never ms. Filtering by the legal interval first is deliberate: snapping to an
/// out-of-range edge and clamping afterwards would land the cut on a non-silence point, so
/// the magnet would lie. `nil` when nothing qualifies. Ties resolve to the smaller sample
/// for determinism. A `thresholdSamples` of 0 still matches an exact hit.
func nearestSilenceEdge(
  sample: Int, thresholdSamples: Int, silences: [EditPlan.Silence], legalRange: ClosedRange<Int>
) -> Int? {
  var best: Int?
  var bestDistance = Int.max
  for silence in silences {
    for edge in [silence.startSample, silence.endSample] where legalRange.contains(edge) {
      let distance = abs(edge - sample)
      guard distance <= thresholdSamples else { continue }
      if distance < bestDistance || (distance == bestDistance && edge < (best ?? Int.max)) {
        best = edge
        bestDistance = distance
      }
    }
  }
  return best
}

/// The word IDs whose audio MIDPOINT falls in `[range.lowerBound, range.upperBound)`, in
/// transcript order. Midpoint membership (not pure overlap or full containment) is the
/// least-surprising rule once cuts are sample-native and no longer tied to word edges — a
/// word "belongs" to the slice that contains most of it. Words missing sample bounds, or
/// with a non-positive span, are skipped. Midpoint is computed overflow-safe.
func wordIDs(overlapping range: Range<Int>, words: [Word]) -> [Word.ID] {
  words.compactMap { word in
    guard let start = word.startSample, let end = word.endSample, start < end else { return nil }
    let midpoint = start + (end - start) / 2
    return (midpoint >= range.lowerBound && midpoint < range.upperBound) ? word.id : nil
  }
}

/// Re-derives the plain (unquoted, untruncated) transcript snippet for a set of word IDs,
/// in transcript order. `EditorModel` wraps the result in quotes and middle-truncates it
/// for display, exactly as it does for a selection.
func sliceSnippet(for ids: [Word.ID], words: [Word]) -> String {
  let byID = Dictionary(words.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
  return ids.compactMap { byID[$0] }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
}
