import Foundation

/// How `EditedTimeline.sourceToEdited` should resolve a source sample that falls
/// inside a removed range (where there is no 1:1 edited position).
enum MappingBias {
  case leftEdge
  case rightEdge
  case nearest
  case nilInsideRemoval
}

/// A contiguous span of SOURCE samples that survives all removals, plus where
/// it begins on the EDITED timeline.
struct KeptSegment: Equatable {
  var source: Range<Int>
  var editedStart: Int
}

/// A crossfaded cut point between two kept segments, expressed in both
/// SOURCE (`sourceCut`) and EDITED (`editedCrossfadeStart`) coordinates.
struct TimelineSeam: Equatable, Identifiable {
  var id: UUID
  var sourceCut: Int
  var crossfadeLength: Int
  /// EDITED-axis start of the crossfade overlap region — NOT its center, despite the
  /// name of the deprecated `editedCenter` this replaced.
  var editedCrossfadeStart: Int

  /// The visual/edit center of the crossfade region, used by fade editing (PR5).
  var editedCrossfadeCenter: Int { editedCrossfadeStart + crossfadeLength / 2 }

  /// Twice the exact (unrounded) crossfade center — `2·start + length`. Edge-drag length math derives
  /// the symmetric length from a dragged edge and this value (`length = 2·edited − doubledCenter` for
  /// a trailing edge), which avoids the half-sample truncation in `editedCrossfadeCenter` that would
  /// otherwise make every proposed length even, so an odd stored length could never be retained.
  var editedCrossfadeDoubledCenter: Int { 2 * editedCrossfadeStart + crossfadeLength }
}

/// Maps between SOURCE sample coordinates (the original recording) and EDITED
/// sample coordinates (the timeline after removals are collapsed and adjacent
/// kept segments are crossfaded across the cut).
///
/// Kept segments are laid out end to end on the edited timeline, but each seam
/// overlaps its neighbor by the seam's (clamped) crossfade length, so the
/// edited duration is shorter than "source minus removed" by the sum of all
/// crossfade lengths.
///
/// Cheap to construct; rebuild on every change rather than caching.
struct EditedTimeline: Equatable {
  let sourceDurationSamples: Int
  let removals: [TimelineRemoval]
  let keptSegments: [KeptSegment]
  let seams: [TimelineSeam]
  let isValid: Bool

  init(sourceDurationSamples: Int, removals: [TimelineRemoval]) {
    self.sourceDurationSamples = sourceDurationSamples

    // Defensive backstop (belt-and-suspenders with `EditorModel.validatedRemovals`): see
    // `Self.boundedToSource` — never changes behavior for already in-bounds removals.
    let boundedRemovals = Self.boundedToSource(
      removals, sourceDurationSamples: sourceDurationSamples)

    let normalizedOrNil = TimelineRemovals.normalize(boundedRemovals)
    self.isValid = normalizedOrNil != nil
    let normalized = normalizedOrNil ?? []

    guard !normalized.isEmpty else {
      self.removals = []
      self.keptSegments = [KeptSegment(source: 0..<sourceDurationSamples, editedStart: 0)]
      self.seams = []
      return
    }

    // Raw kept-segment source ranges: n+1 segments for n removals.
    var sourceRangesList: [Range<Int>] = []
    var previousUpper = 0
    for removal in normalized {
      sourceRangesList.append(previousUpper..<removal.removedRange.lowerBound)
      previousUpper = removal.removedRange.upperBound
    }
    sourceRangesList.append(previousUpper..<sourceDurationSamples)

    // Clamp each removal's crossfade to the handle available on both sides:
    // it can never eat more than the kept segment immediately to its left or
    // immediately to its right.
    //
    // Clamping is sequential (left to right): a seam's left handle is reduced
    // by whatever the PREVIOUS seam already claimed of that shared segment, so
    // adjacent claims on one kept island can never sum past its length. Two
    // seams over-claiming a short island would otherwise cover the same edited
    // span, making the rendered stream longer than `editedDurationSamples`
    // (duplicated audio, backward cursor jumps). The earlier seam wins the
    // island; the later one shrinks — collapsing to a hard cut when nothing is
    // left. (Revises spec §4.2's independent clamping, which PR2's audio
    // blending was slated to revisit.)
    var clampedLengths: [Int] = []
    clampedLengths.reserveCapacity(normalized.count)
    for index in normalized.indices {
      let claimedByPreviousSeam = index > 0 ? clampedLengths[index - 1] : 0
      let leftHandle = sourceRangesList[index].count - claimedByPreviousSeam
      let rightHandle = sourceRangesList[index + 1].count
      clampedLengths.append(
        max(0, min(normalized[index].crossfade.lengthSamples, leftHandle, rightHandle)))
    }

    self.removals = zip(normalized, clampedLengths).map { removal, length in
      var updated = removal
      updated.crossfade.lengthSamples = length
      return updated
    }

    var keptSegments: [KeptSegment] = []
    keptSegments.reserveCapacity(sourceRangesList.count)
    var editedStart = 0
    for (index, source) in sourceRangesList.enumerated() {
      keptSegments.append(KeptSegment(source: source, editedStart: editedStart))
      if index < clampedLengths.count {
        editedStart += source.count - clampedLengths[index]
      }
    }
    self.keptSegments = keptSegments

    self.seams = normalized.indices.map { index in
      TimelineSeam(
        id: normalized[index].id,
        sourceCut: normalized[index].removedRange.lowerBound,
        crossfadeLength: clampedLengths[index],
        editedCrossfadeStart: keptSegments[index + 1].editedStart)
    }
  }

  /// Clamps every removal's range to `0 ..< sourceDurationSamples`, dropping any that clamp to
  /// empty (entirely outside the source). Guards against a stale/foreign removal — e.g. one
  /// persisted against a longer recording — leaving `previousUpper > sourceDurationSamples` in
  /// the init below, which would build a reversed kept-segment `Range` and trap. In-bounds
  /// removals pass through unchanged, so this never changes behavior for valid input.
  private static func boundedToSource(
    _ removals: [TimelineRemoval], sourceDurationSamples: Int
  ) -> [TimelineRemoval] {
    let sourceBounds = 0..<sourceDurationSamples
    return removals.compactMap { removal in
      let clampedRange = removal.removedRange.clamped(to: sourceBounds)
      guard !clampedRange.isEmpty else { return nil }
      guard clampedRange != removal.removedRange else { return removal }
      var clamped = removal
      clamped.removedRange = clampedRange
      return clamped
    }
  }

  var editedDurationSamples: Int {
    guard let last = keptSegments.last else { return 0 }
    return last.editedStart + last.source.count
  }

  func sourceToEdited(_ sourceSample: Int, bias: MappingBias = .nilInsideRemoval) -> Int? {
    if let removalIndex = removals.firstIndex(where: { $0.removedRange.contains(sourceSample) }) {
      switch bias {
      case .nilInsideRemoval:
        return nil
      case .leftEdge:
        return editedPositionOfCutStart(atRemoval: removalIndex)
      case .rightEdge:
        return editedPositionOfCutEnd(atRemoval: removalIndex)
      case .nearest:
        let removedRange = removals[removalIndex].removedRange
        let distanceToStart = sourceSample - removedRange.lowerBound
        let distanceToEnd = removedRange.upperBound - sourceSample
        // Tie (equidistant from both edges) prefers the left edge.
        return distanceToStart <= distanceToEnd
          ? editedPositionOfCutStart(atRemoval: removalIndex)
          : editedPositionOfCutEnd(atRemoval: removalIndex)
      }
    }

    var matched: Int?
    for segment in keptSegments
    where sourceSample >= segment.source.lowerBound && sourceSample <= segment.source.upperBound {
      matched = segment.editedStart + (sourceSample - segment.source.lowerBound)
    }
    return matched
  }

  func editedToSource(_ editedSample: Int) -> Int {
    let clamped = min(max(editedSample, 0), editedDurationSamples)
    var matched: Int?
    for segment in keptSegments {
      let editedUpper = segment.editedStart + segment.source.count
      guard clamped >= segment.editedStart && clamped <= editedUpper else { continue }
      matched = segment.source.lowerBound + (clamped - segment.editedStart)
    }
    return matched ?? clamped
  }

  func sourceRanges(forEdited edited: Range<Int>) -> [Range<Int>] {
    guard !edited.isEmpty else { return [] }
    var ranges: [Range<Int>] = []
    for segment in keptSegments {
      let editedSpan = segment.editedStart..<(segment.editedStart + segment.source.count)
      let lower = max(edited.lowerBound, editedSpan.lowerBound)
      let upper = min(edited.upperBound, editedSpan.upperBound)
      guard lower < upper else { continue }
      let sourceLower = segment.source.lowerBound + (lower - segment.editedStart)
      let sourceUpper = segment.source.lowerBound + (upper - segment.editedStart)
      ranges.append(sourceLower..<sourceUpper)
    }
    return ranges
  }

  /// The EDITED-axis footprint of a SOURCE range: the union of the edited positions of every kept
  /// sample that falls within `source`. Segments overlap by their crossfade length on the edited
  /// axis, so this spans from the earliest kept sample's edited position to the latest, covering the
  /// crossfade tails that belong to the range. Returns nil when no kept audio survives inside
  /// `source` (e.g. it lies entirely within removed spans) — callers pin an empty lane rather than
  /// falling back to the whole timeline. Unlike bracketing the two endpoints with `sourceToEdited`
  /// biases, this is correct when an endpoint lands inside a removal or the range spans several
  /// removals.
  func editedFootprint(ofSource source: Range<Int>) -> Range<Int>? {
    guard !source.isEmpty else { return nil }
    var lower: Int?
    var upper: Int?
    for segment in keptSegments {
      let lo = max(source.lowerBound, segment.source.lowerBound)
      let hi = min(source.upperBound, segment.source.upperBound)
      guard lo < hi else { continue }
      let editedLo = segment.editedStart + (lo - segment.source.lowerBound)
      let editedHi = segment.editedStart + (hi - segment.source.lowerBound)
      lower = Swift.min(lower ?? editedLo, editedLo)
      upper = Swift.max(upper ?? editedHi, editedHi)
    }
    guard let lower, let upper, lower < upper else { return nil }
    return lower..<upper
  }

  /// Maps a SOURCE sample to its EDITED position, for marker mapping (PR6 export). Returns nil
  /// when the sample falls inside a removed range (the plan's `.nilInsideRemoval` policy) or is
  /// outside every kept segment (e.g. past the end of the source). Segments and removals are
  /// half-open, so a sample exactly at a kept segment's `source.upperBound` belongs to whatever
  /// region follows, never the segment that ends there.
  func editedSample(forSource sourceSample: Int) -> Int? {
    if removals.contains(where: { $0.removedRange.contains(sourceSample) }) {
      return nil
    }
    guard let segment = keptSegments.first(where: { $0.source.contains(sourceSample) }) else {
      return nil
    }
    return segment.editedStart + (sourceSample - segment.source.lowerBound)
  }

  /// The largest crossfade length a seam can take given its neighbors, mirroring the sequential
  /// clamp in `init`: bounded by the full kept segment on its right and by the kept segment on its
  /// left minus whatever the previous seam already claimed of that shared island. This is the live
  /// bound a stretch drag clamps to, so a manual stretch never over-runs into neighbor audio.
  /// Returns nil for an unknown id (including an invalid timeline, whose `seams` are empty).
  func maxCrossfadeLength(forSeamID id: TimelineRemoval.ID) -> Int? {
    guard let index = seams.firstIndex(where: { $0.id == id }) else { return nil }
    let leftHandle =
      keptSegments[index].source.count
      - (index > 0 ? seams[index - 1].crossfadeLength : 0)
    let rightHandle = keptSegments[index + 1].source.count
    return max(0, min(rightHandle, leftHandle))
  }

  func seam(containingEdited editedSample: Int) -> TimelineSeam? {
    seams.first {
      editedSample >= $0.editedCrossfadeStart
        && editedSample < $0.editedCrossfadeStart + $0.crossfadeLength
    }
  }

  /// Edited position of the removal's source cut start `a`, resolved from the
  /// left (pre-cut) kept segment's end.
  private func editedPositionOfCutStart(atRemoval removalIndex: Int) -> Int {
    let leftSegment = keptSegments[removalIndex]
    return leftSegment.editedStart + leftSegment.source.count
  }

  /// Edited position of the removal's source cut end `b`, resolved from the
  /// right (post-cut) kept segment's start.
  private func editedPositionOfCutEnd(atRemoval removalIndex: Int) -> Int {
    keptSegments[removalIndex + 1].editedStart
  }
}
