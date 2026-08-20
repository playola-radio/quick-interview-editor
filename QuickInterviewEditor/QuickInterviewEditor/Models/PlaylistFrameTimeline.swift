import Foundation

/// Maps the player node's played-frame count back to an edited-timeline sample
/// while an `AudioEditRenderPlan` plays.
///
/// The node counts INPUT frames (`playerTime.sampleTime`), unaffected by the
/// TimePitch rate, so the cursor stays correct at any speed. Because the plan's
/// items lie end to end and cover the edited axis once, the mapping is a single
/// running offset — but the per-item table keeps it exact even when the source's
/// native rate differs from the plan rate (`ratio`) and per-item frame counts
/// round independently. Cursor is read from this, never trusted from completion
/// callbacks (locked decision 3).
struct PlaylistFrameTimeline: Equatable {
  /// One scheduled item's footprint: where it starts in node frames, how many
  /// native frames it occupies, and the edited span it reproduces.
  private struct Entry: Equatable {
    var nodeFrameStart: Int
    var nativeFrameCount: Int
    var editedStart: Int
    var editedLength: Int
  }

  /// One scheduled item as it ACTUALLY reached the node: the edited span it
  /// reproduces and the native frames genuinely scheduled for it — which can be
  /// fewer than the span implies when the source file is shorter than the plan
  /// assumed, or zero when the item was dropped entirely.
  struct ScheduledSpan: Equatable {
    var editedSpan: Range<Int>
    var nativeFrameCount: Int
  }

  private let entries: [Entry]
  private let ratio: Double
  var totalNativeFrames: Int

  /// Builds the mapping from the spans that were actually scheduled, so the
  /// cursor can never drift ahead of the audio when an item was clamped or
  /// dropped against the real file (the scheduler and this table must share
  /// one source of truth for frame counts — never two roundings of the plan).
  init(scheduled: [ScheduledSpan], ratio: Double = 1) {
    let ratio = max(ratio, .ulpOfOne)
    self.ratio = ratio
    var entries: [Entry] = []
    var nodeFrameStart = 0
    for span in scheduled where span.nativeFrameCount > 0 {
      entries.append(
        Entry(
          nodeFrameStart: nodeFrameStart,
          nativeFrameCount: span.nativeFrameCount,
          editedStart: span.editedSpan.lowerBound,
          editedLength: span.editedSpan.count))
      nodeFrameStart += span.nativeFrameCount
    }
    self.entries = entries
    self.totalNativeFrames = nodeFrameStart
  }

  /// Convenience for pure/idealized use (tests, previews): assumes every item
  /// schedules its full span at `ratio`. Live playback must use
  /// `init(scheduled:ratio:)` with the counts that really reached the node.
  init(plan: AudioEditRenderPlan, ratio: Double = 1) {
    let clamped = max(ratio, .ulpOfOne)
    self.init(
      scheduled: plan.items.map { item in
        ScheduledSpan(
          editedSpan: item.editedSpan,
          nativeFrameCount: Int((Double(item.editedSpan.count) * clamped).rounded()))
      },
      ratio: clamped)
  }

  /// The edited sample the cursor sits on after `framesPlayed` native input
  /// frames, clamped to the plan's edited bounds.
  func editedSample(forFramesPlayed framesPlayed: Int) -> Int {
    guard let last = entries.last else { return 0 }
    let frames = max(0, framesPlayed)
    if frames >= totalNativeFrames { return last.editedStart + last.editedLength }
    for entry in entries {
      let localFrames = frames - entry.nodeFrameStart
      guard localFrames >= 0, localFrames < entry.nativeFrameCount else { continue }
      let editedOffset = Int((Double(localFrames) / ratio).rounded())
      // While native frames of this item remain, the cursor is INSIDE it — rounding
      // at a non-1 ratio must never report the item's (half-open) upper bound early.
      return entry.editedStart + min(editedOffset, max(0, entry.editedLength - 1))
    }
    return last.editedStart + last.editedLength
  }
}
