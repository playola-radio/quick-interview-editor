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

  private let entries: [Entry]
  private let ratio: Double
  var totalNativeFrames: Int

  init(plan: AudioEditRenderPlan, ratio: Double = 1) {
    let ratio = max(ratio, .ulpOfOne)
    self.ratio = ratio
    var entries: [Entry] = []
    var nodeFrameStart = 0
    for item in plan.items {
      let span = item.editedSpan
      let nativeFrameCount = Int((Double(span.count) * ratio).rounded())
      entries.append(
        Entry(
          nodeFrameStart: nodeFrameStart,
          nativeFrameCount: nativeFrameCount,
          editedStart: span.lowerBound,
          editedLength: span.count))
      nodeFrameStart += nativeFrameCount
    }
    self.entries = entries
    self.totalNativeFrames = nodeFrameStart
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
