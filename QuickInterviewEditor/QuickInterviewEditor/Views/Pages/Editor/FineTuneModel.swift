import CoreGraphics
import Foundation
import Observation

/// The fine-tune drag surface: two magnified boundary insets ("Cut in" = slice start,
/// "Cut out" = slice end). It owns a *draft* of one slice's cut points and all the geometry
/// to render + drag them, but it **never mutates `slices`** — `EditorModel` reads the draft
/// and commits it as a single undo entry. Every coordinate is a canonical PLAN sample.
///
/// Windows are fixed for the life of an edit session, centered on the boundary's *committed*
/// value: the magnified view must not slide out from under the cursor while dragging, so the
/// cut line moves within a stationary window. Samples-per-inset-pixel is likewise fixed (do
/// not rescale per boundary), and regions past the file edge render blank rather than zoomed.
@MainActor
@Observable
final class FineTuneModel: ViewModel {

  // MARK: - Target
  enum Target: Equatable {
    case pendingSelection
    case slice(Slice.ID)
  }

  // MARK: - Initialization
  let sampleRate: Int
  let durationSamples: Int
  let silences: [EditPlan.Silence]

  init(sampleRate: Int, durationSamples: Int, silences: [EditPlan.Silence]) {
    self.sampleRate = max(1, sampleRate)
    self.durationSamples = max(0, durationSamples)
    self.silences = silences
    super.init()
  }

  // MARK: - Constants
  /// Total span shown across one inset — a ±0.5 s window around the boundary.
  let insetSpanSeconds = 1.0
  /// Fixed pixel width of an inset; the silhouette is rendered at this width so
  /// samples-per-pixel is constant and never rescaled per boundary.
  let insetWidthPixels: CGFloat = 252
  let snapThresholdMs = 40.0
  let nudgeMs = 10.0
  let minSliceMs = 50.0

  // MARK: - Display Text
  let cutInLabel = "Cut in ▸"
  let cutOutLabel = "◂ Cut out"
  let helperText = "Fine-tune the cut points — drag the red line or nudge in 10 ms steps"
  let nudgeBackLabel = "−10 ms"
  let nudgeForwardLabel = "+10 ms"
  let previewEditLabel = "Preview edit"
  let previewStopLabel = "Stop preview"
  let commitLabel = "Save cut"
  let cancelLabel = "Cancel"

  // MARK: - Properties
  var target: Target?
  /// The range the current draft started from — the committed truth for this session and
  /// the anchor the inset windows are centered on.
  var committedRange: Range<Int>?
  /// The in-progress cut points. Drag and nudge mutate only this; commit/cancel live on
  /// `EditorModel`.
  var draftRange: Range<Int>?

  // MARK: - Derived sample constants
  var insetSpanSamples: Int { Int((insetSpanSeconds * Double(sampleRate)).rounded()) }
  private var halfSpanSamples: Int { insetSpanSamples / 2 }
  private var samplesPerInsetPixel: Double {
    Double(insetSpanSamples) / Double(insetWidthPixels)
  }
  private var snapThresholdSamples: Int { samples(forMs: snapThresholdMs) }
  private var minDurationSamples: Int { samples(forMs: minSliceMs) }

  // MARK: - View Helpers
  var isActive: Bool { target != nil && draftRange != nil }
  var isEditingExistingSlice: Bool {
    if case .slice = target { return true }
    return false
  }
  /// True once the draft diverges from the committed range — an unsaved change the user must
  /// commit or cancel. Drives export/undo gating on `EditorModel`.
  var hasUnsavedChange: Bool {
    guard let draftRange, let committedRange else { return false }
    return draftRange != committedRange
  }

  /// The inset window around each boundary, half-open in samples, always `insetSpanSamples`
  /// wide (may extend past the file edges, where the view renders blank). Nil when no session.
  var cutInWindow: Range<Int>? { window(around: committedRange?.lowerBound) }
  var cutOutWindow: Range<Int>? { window(around: committedRange?.upperBound) }

  var cutInLineX: CGFloat? { lineX(forSample: draftRange?.lowerBound, in: cutInWindow) }
  var cutOutLineX: CGFloat? { lineX(forSample: draftRange?.upperBound, in: cutOutWindow) }

  /// Boundary time readouts (red in the UI), rendered from the live draft.
  var cutInTimeLabel: String {
    draftRange.map { sampleTimecodeLabel($0.lowerBound, sampleRate: sampleRate) } ?? ""
  }
  var cutOutTimeLabel: String {
    draftRange.map { sampleTimecodeLabel($0.upperBound, sampleRate: sampleRate) } ?? ""
  }

  /// Live cut-safety of the draft, recomputed each frame. `tightStart` reddens the Cut-in
  /// inset, `tightEnd` the Cut-out inset — distinct from snap, which only decides magnetism.
  var draftWarnings: [SliceWarning] {
    guard let draftRange else { return [] }
    return sliceWarnings(
      startSample: draftRange.lowerBound, endSample: draftRange.upperBound,
      durationSamples: durationSamples, silences: silences)
  }
  var isCutInTight: Bool { draftWarnings.contains(.tightStart) }
  var isCutOutTight: Bool { draftWarnings.contains(.tightEnd) }

  /// The kept portion of each inset (Cut-in keeps everything to the right of the line;
  /// Cut-out keeps everything to the left), for the red silhouette fill.
  var cutInKeptSpan: WaveformSpan? {
    cutInLineX.map { WaveformSpan(positionX: $0, width: max(0, insetWidthPixels - $0)) }
  }
  var cutOutKeptSpan: WaveformSpan? {
    cutOutLineX.map { WaveformSpan(positionX: 0, width: max(0, $0)) }
  }
  /// The discarded (dimmed) portion of each inset — the complement of the kept span.
  var cutInDiscardedSpan: WaveformSpan? {
    cutInLineX.map { WaveformSpan(positionX: 0, width: max(0, $0)) }
  }
  var cutOutDiscardedSpan: WaveformSpan? {
    cutOutLineX.map { WaveformSpan(positionX: $0, width: max(0, insetWidthPixels - $0)) }
  }

  /// Silence regions inside each inset window, as inset-x spans, so the view can shade the
  /// "you can cut cleanly here" zones. Silence ends are inclusive (matching `sliceWarnings`).
  var cutInSafeZones: [WaveformSpan] { safeZones(in: cutInWindow) }
  var cutOutSafeZones: [WaveformSpan] { safeZones(in: cutOutWindow) }

  // MARK: - Coordinate transforms
  /// Inset-x for a plan sample within a given window (may be off-inset; the view clips).
  func insetX(forSample sample: Int, in window: Range<Int>) -> CGFloat {
    CGFloat(Double(sample - window.lowerBound) / samplesPerInsetPixel)
  }
  /// Plan sample at the left edge of inset-pixel `x` (floor semantics, mirroring the main
  /// waveform), clamped into the window.
  func sample(forInsetX positionX: CGFloat, in window: Range<Int>) -> Int {
    let raw = window.lowerBound + Int((Double(positionX) * samplesPerInsetPixel).rounded(.down))
    return min(max(raw, window.lowerBound), window.upperBound)
  }

  // MARK: - User Actions (never touch slices)
  func begin(target: Target, range: Range<Int>) {
    self.target = target
    committedRange = range
    draftRange = range
  }

  /// Called by `EditorModel` after it commits the draft into `slices`: the draft becomes the
  /// new committed truth (session stays open on the same slice).
  func markCommitted(_ range: Range<Int>) {
    committedRange = range
    draftRange = range
  }

  /// Cancel: drop the unsaved change, keeping the pane open on the committed range.
  func resetDraft() { draftRange = committedRange }

  /// End the session entirely (pane closes).
  func clear() {
    target = nil
    committedRange = nil
    draftRange = nil
  }

  func dragCutIn(toInsetX positionX: CGFloat) {
    guard let window = cutInWindow else { return }
    moveStart(to: sample(forInsetX: positionX, in: window), snap: true)
  }
  func dragCutOut(toInsetX positionX: CGFloat) {
    guard let window = cutOutWindow else { return }
    moveEnd(to: sample(forInsetX: positionX, in: window), snap: true)
  }

  /// Nudges are the manual override, so they never snap — but still obey the file, min-slice,
  /// and window clamps.
  func nudgeCutIn(byMs deltaMs: Double) {
    guard let draftRange else { return }
    moveStart(to: draftRange.lowerBound + samples(forMs: deltaMs), snap: false)
  }
  func nudgeCutOut(byMs deltaMs: Double) {
    guard let draftRange else { return }
    moveEnd(to: draftRange.upperBound + samples(forMs: deltaMs), snap: false)
  }

  // MARK: - Private Helpers
  private func samples(forMs ms: Double) -> Int {
    Int((ms / 1000 * Double(sampleRate)).rounded())
  }

  private func window(around center: Int?) -> Range<Int>? {
    guard let center else { return nil }
    let start = center - halfSpanSamples
    return start..<(start + insetSpanSamples)
  }

  private func lineX(forSample sample: Int?, in window: Range<Int>?) -> CGFloat? {
    guard let sample, let window else { return nil }
    return insetX(forSample: sample, in: window)
  }

  private func constraints(for window: Range<Int>) -> BoundaryConstraints {
    BoundaryConstraints(
      window: window.lowerBound...window.upperBound, durationSamples: durationSamples,
      minDurationSamples: minDurationSamples)
  }

  private func moveStart(to proposed: Int, snap: Bool) {
    guard let window = cutInWindow, let draftRange else { return }
    let limits = constraints(for: window)
    let clamped = clampedBoundary(
      proposed, moving: .start, opposite: draftRange.upperBound, constraints: limits)
    let resolved =
      snap
      ? snappedOrClamped(clamped, moving: .start, opposite: draftRange.upperBound, limits: limits)
      : clamped
    self.draftRange = resolved..<draftRange.upperBound
  }

  private func moveEnd(to proposed: Int, snap: Bool) {
    guard let window = cutOutWindow, let draftRange else { return }
    let limits = constraints(for: window)
    let clamped = clampedBoundary(
      proposed, moving: .end, opposite: draftRange.lowerBound, constraints: limits)
    let resolved =
      snap
      ? snappedOrClamped(clamped, moving: .end, opposite: draftRange.lowerBound, limits: limits)
      : clamped
    self.draftRange = draftRange.lowerBound..<resolved
  }

  private func snappedOrClamped(
    _ clamped: Int, moving edge: SliceEdge, opposite: Int, limits: BoundaryConstraints
  ) -> Int {
    let legal = legalBoundaryRange(moving: edge, opposite: opposite, constraints: limits)
    return nearestSilenceEdge(
      sample: clamped, thresholdSamples: snapThresholdSamples, silences: silences,
      legalRange: legal) ?? clamped
  }

  private func safeZones(in window: Range<Int>?) -> [WaveformSpan] {
    guard let window else { return [] }
    return silences.compactMap { silence in
      guard silence.endSample > window.lowerBound, silence.startSample < window.upperBound
      else { return nil }
      let lo = insetX(forSample: max(silence.startSample, window.lowerBound), in: window)
      let hi = insetX(forSample: min(silence.endSample, window.upperBound), in: window)
      let left = min(max(lo, 0), insetWidthPixels)
      let right = min(max(hi, 0), insetWidthPixels)
      guard right > left else { return nil }
      return WaveformSpan(positionX: left, width: right - left)
    }
  }
}
