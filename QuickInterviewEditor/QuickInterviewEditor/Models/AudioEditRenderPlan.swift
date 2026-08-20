import Foundation

/// An ordered, sample-accurate recipe for auditioning or exporting an edited
/// timeline as one continuous stream. Concatenating every item's audio, in
/// order, reproduces the edited timeline exactly: kept-segment interiors are
/// scheduled straight from the source file, and each `seam` is the pre-rendered
/// crossfade overlap between the outgoing (`leftTail`) and incoming (`rightHead`)
/// audio around a cut.
///
/// Because the items lie end to end and every edited sample is covered once, the
/// total scheduled length equals `timeline.editedDurationSamples`, so a playback
/// cursor is `startEditedSample + framesPlayed` (at the plan rate) — no per-item
/// offset table required for correctness, only for native/plan rounding safety.
///
/// Pure and deterministic; it feeds both live audition and export so the two can
/// never diverge (locked decision 1).
struct AudioEditRenderPlan: Equatable, Sendable {
  enum Item: Equatable, Sendable {
    /// A contiguous run of source samples scheduled directly from the file,
    /// beginning at `editedStart` on the edited axis.
    case segment(source: Range<Int>, editedStart: Int)
    /// A crossfade overlap: `leftTail` (outgoing) blended with `rightHead`
    /// (incoming) over `length` samples, beginning at `editedStart`. When a
    /// seek lands inside the crossfade, `fadeOffset` records how many samples
    /// of the original fade were skipped, so rendering continues the fade's
    /// gains from the seek point (full fade length = `fadeOffset + length`).
    case seam(
      id: UUID, leftTail: Range<Int>, rightHead: Range<Int>, length: Int, editedStart: Int,
      fadeOffset: Int)
  }

  var items: [Item]

  /// Builds the plan for `timeline`, optionally starting partway through the
  /// edited axis (`startEditedSample`) so a seek re-enters mid-segment or
  /// mid-crossfade without rescheduling from the top.
  init(timeline: EditedTimeline, startEditedSample: Int = 0) {
    let segments = timeline.keptSegments
    let seams = timeline.seams  // seams[i] sits between segments[i] and segments[i + 1]

    var full: [Item] = []
    for index in segments.indices {
      let segment = segments[index]
      // Samples this segment loses to the crossfades on either side: its head to
      // the preceding seam's incoming audio, its tail to the next seam's outgoing.
      let lengthBefore = index > 0 ? seams[index - 1].crossfadeLength : 0
      let lengthAfter = index < seams.count ? seams[index].crossfadeLength : 0

      let interiorLower = segment.source.lowerBound + lengthBefore
      let interiorUpper = segment.source.upperBound - lengthAfter
      // A fully-consumed island (two seams over-claiming a short kept segment)
      // yields no interior; skip it rather than emit a reversed range.
      if interiorLower < interiorUpper {
        full.append(
          .segment(
            source: interiorLower..<interiorUpper, editedStart: segment.editedStart + lengthBefore))
      }

      guard index < seams.count else { continue }
      let seam = seams[index]
      let length = seam.crossfadeLength
      guard length > 0 else { continue }  // hard cut — abutting segments, no blend
      let rightSegment = segments[index + 1]
      full.append(
        .seam(
          id: seam.id,
          leftTail: (segment.source.upperBound - length)..<segment.source.upperBound,
          rightHead: rightSegment.source.lowerBound..<(rightSegment.source.lowerBound + length),
          length: length,
          editedStart: seam.editedCrossfadeStart,
          fadeOffset: 0))
    }

    self.items = Self.trimmed(full, toStartEdited: max(0, startEditedSample))
  }

  /// Drops items that end before `start` and front-trims the one straddling it,
  /// so a seek into a segment resumes mid-file and a seek into a crossfade
  /// renders a partial seam from the offset (never the whole buffer).
  private static func trimmed(_ items: [Item], toStartEdited start: Int) -> [Item] {
    guard start > 0 else { return items }
    var result: [Item] = []
    for item in items {
      let span = item.editedSpan
      if span.upperBound <= start { continue }
      guard span.lowerBound < start else {
        result.append(item)
        continue
      }
      let offset = start - span.lowerBound
      switch item {
      case .segment(let source, _):
        result.append(
          .segment(source: (source.lowerBound + offset)..<source.upperBound, editedStart: start))
      case .seam(let id, let leftTail, let rightHead, let length, _, let fadeOffset):
        result.append(
          .seam(
            id: id,
            leftTail: (leftTail.lowerBound + offset)..<leftTail.upperBound,
            rightHead: (rightHead.lowerBound + offset)..<rightHead.upperBound,
            length: length - offset,
            editedStart: start,
            fadeOffset: fadeOffset + offset))
      }
    }
    return result
  }
}

extension AudioEditRenderPlan.Item {
  /// The half-open range this item covers on the edited axis.
  var editedSpan: Range<Int> {
    switch self {
    case .segment(let source, let editedStart):
      return editedStart..<(editedStart + source.count)
    case .seam(_, _, _, let length, let editedStart, _):
      return editedStart..<(editedStart + length)
    }
  }
}
