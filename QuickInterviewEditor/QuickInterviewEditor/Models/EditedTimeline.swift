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
/// SOURCE (`sourceCut`) and EDITED (`editedCenter`) coordinates.
struct TimelineSeam: Equatable, Identifiable {
  var id: UUID
  var sourceCut: Int
  var crossfadeLength: Int
  var editedCenter: Int
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

    let normalizedOrNil = TimelineRemovals.normalize(removals)
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
    let clampedLengths: [Int] = normalized.indices.map { index in
      let leftHandle = sourceRangesList[index].count
      let rightHandle = sourceRangesList[index + 1].count
      return max(0, min(normalized[index].crossfade.lengthSamples, leftHandle, rightHandle))
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
        editedCenter: keptSegments[index + 1].editedStart)
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

  func seam(containingEdited editedSample: Int) -> TimelineSeam? {
    seams.first {
      editedSample >= $0.editedCenter && editedSample < $0.editedCenter + $0.crossfadeLength
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
