import Foundation
import Observation
import Sharing

/// Drives the "Editing" settings tab: the global start/end offsets that nudge where a NEW
/// clip's cut points land (Mark as Clip, fine-tune commit, accepted cut suggestion). Manual
/// boundary re-edits never consult these — see `EditorModel.appendNewClip`.
@MainActor
@Observable
final class ClipBoundarySettingsModel: ViewModel {

  // MARK: - Shared State
  @ObservationIgnored @Shared(.clipStartOffsetMs) var startOffsetMs: Double
  @ObservationIgnored @Shared(.clipEndOffsetMs) var endOffsetMs: Double

  // MARK: - Initialization
  override init() {
    super.init()
    // Defensive: normalize any out-of-range value already in storage (e.g. from a future
    // version or a manually-edited defaults plist) so the slider and readout never diverge
    // from what `offsetClipRange` actually applies.
    if startOffsetMs != clamped(startOffsetMs) { $startOffsetMs.withLock { $0 = clamped($0) } }
    if endOffsetMs != clamped(endOffsetMs) { $endOffsetMs.withLock { $0 = clamped($0) } }
  }

  // MARK: - Properties
  let minMs = -50.0
  let maxMs = 50.0

  // MARK: - Display Text
  let title = "Clip Boundaries"
  let sectionHeader = "New Clip Offsets"
  let helpText =
    "Nudge where a NEW clip's start and end cut points land, up to 50 ms earlier or later. "
    + "Manual boundary edits you make later are never affected."
  let startSliderLabel = "Start"
  let endSliderLabel = "End"
  let resetLabel = "Reset"

  // MARK: - View Helpers
  var startOffsetLabel: String { Self.readoutLabel(for: startOffsetMs) }
  var endOffsetLabel: String { Self.readoutLabel(for: endOffsetMs) }
  var canReset: Bool { startOffsetMs != 0 || endOffsetMs != 0 }

  // MARK: - User Actions
  func startOffsetChanged(_ ms: Double) {
    $startOffsetMs.withLock { $0 = clamped(ms) }
  }

  func endOffsetChanged(_ ms: Double) {
    $endOffsetMs.withLock { $0 = clamped(ms) }
  }

  func resetTapped() {
    $startOffsetMs.withLock { $0 = 0 }
    $endOffsetMs.withLock { $0 = 0 }
  }

  // MARK: - Private Helpers
  private func clamped(_ ms: Double) -> Double {
    // Round to whole ms so the integer readout never diverges from the offset
    // `offsetClipRange` actually applies (e.g. a stored 0.5 would read "+1 ms" but cut at 0.5 ms).
    min(max(ms, minMs), maxMs).rounded()
  }

  private static func readoutLabel(for ms: Double) -> String {
    let rounded = Int(ms.rounded())
    if rounded == 0 { return "0 ms" }
    if rounded > 0 { return "+\(rounded) ms" }
    return "\u{2212}\(abs(rounded)) ms"
  }
}
