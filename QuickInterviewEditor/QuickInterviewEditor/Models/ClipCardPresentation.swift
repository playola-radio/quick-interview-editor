import Foundation

/// The transcript's clip-state filter. `all` shows every card; the others show only cards in
/// that state. Layout-local (lives on `TranscriptPageModel`), never persisted.
enum ClipFilter: String, CaseIterable, Identifiable, Sendable {
  case all, approved, suggested, rejected
  var id: String { rawValue }

  /// The segmented-control label for this filter.
  var label: String {
    switch self {
    case .all: return "All"
    case .approved: return "Approved"
    case .suggested: return "Suggested"
    case .rejected: return "Rejected"
    }
  }

  /// Whether a clip in `state` is shown under this filter.
  func matches(_ state: ClipState) -> Bool {
    switch self {
    case .all: return true
    case .approved: return state == .approved
    case .suggested: return state == .suggested
    case .rejected: return state == .rejected
    }
  }
}

/// Which boundary of a clip point-and-add is arming: `start` (＋ Add to beginning) or `end`
/// (Add to end ＋). While armed, the transcript on that side becomes word-addressable.
enum ArmedAddSide: Equatable { case start, end }

/// One clip card rendered in the transcript flow. Every string and flag is precomputed so the
/// view stays pixel-only (CLAUDE.md's "zero logic in views"). Colors are the view's job: the
/// model hands it clip STATE plus currentness, and the view maps those to the spec's hex
/// values, so the model carries meaning (state), not pixels.
struct ClipCardVM: Identifiable, Equatable, Sendable {
  var id: EditorClip.ID
  /// 1-based position in the full clip list — the `N` in the header, stable under filtering.
  var number: Int
  /// The clip's own state, which drives the state dot, left border, and header color. Never
  /// overridden by `isCurrent` (the current clip reads red while its dot keeps its own color).
  var state: ClipState
  /// The clip under the keyboard/selection focus — the card gets the red "editing now" treatment.
  var isCurrent: Bool
  var title: String
  /// Always `NN.Ns` (e.g. `12.3s`); empty only for a degenerate clip with no valid range.
  var durationLabel: String
  /// The state word for the header (`Approved` / `Suggested` / `Rejected`); the view uppercases.
  var stateLabel: String
  /// The clip's spoken words joined in transcript order — the bright, larger card body text.
  /// Untruncated (unlike the slice-row snippet), so the card reads as the clip itself.
  var body: String
  var wordIDs: [Word.ID]
  var range: Range<Int>?
  /// The start side is armed for point-and-add on THIS card (the footer button reads "Pick first
  /// word…" and the transcript's earlier side becomes word-addressable).
  var isArmedStart: Bool = false
  /// The end side is armed for point-and-add on THIS card.
  var isArmedEnd: Bool = false

  /// The footer button label for the start side, reflecting the armed state.
  var addStartLabel: String { isArmedStart ? "Pick first word… (esc)" : "＋ Add to beginning" }
  /// The footer button label for the end side, reflecting the armed state.
  var addEndLabel: String { isArmedEnd ? "Pick last word… (esc)" : "Add to end ＋" }
  /// The footer hint, green while armed.
  var footerHint: String {
    if isArmedStart { return "click the first word you want in the clip" }
    if isArmedEnd { return "click the last word you want in the clip" }
    return "⌥←/→ start · ⇧⌥←/→ end · drag a grip"
  }
  /// The header line: `N · Title · duration · STATE`. The view styles it in the state color.
  var headerLine: String {
    var parts = ["\(number)", title]
    if !durationLabel.isEmpty { parts.append(durationLabel) }
    parts.append(stateLabel.uppercased())
    return parts.joined(separator: " · ")
  }
}

/// One segment of the clip-map rail: a clickable band, positioned by the clip's audio range as
/// a fraction of the whole recording, coloured by state (current gets the red ring in the view).
struct ClipMapSegment: Identifiable, Equatable, Sendable {
  var id: EditorClip.ID
  /// Left edge as a 0...1 fraction of the recording.
  var startFraction: Double
  /// Width as a 0...1 fraction of the recording (clamped so a degenerate range still shows).
  var widthFraction: Double
  var state: ClipState
  var isCurrent: Bool
}

/// The header word for a clip state, shared by the card header and any other status text.
func clipStateLabel(_ state: ClipState) -> String {
  switch state {
  case .approved: return "Approved"
  case .suggested: return "Suggested"
  case .rejected: return "Rejected"
  }
}

/// Builds the ordered clip cards for the transcript. `number` is 1-based over the full list, so
/// it stays stable when the view filters; `body` is re-derived from the plan words (not the
/// stored snippet) so accepted-slice cards and suggestion cards read identically.
func makeClipCards(
  from clips: [EditorClip], currentClipID: EditorClip.ID?, words: [Word], sampleRate: Int
) -> [ClipCardVM] {
  clips.map { clip in
    ClipCardVM(
      id: clip.id,
      number: clip.order + 1,
      state: clip.state,
      isCurrent: clip.id == currentClipID,
      title: clip.title,
      durationLabel: clip.range.map { sampleDurationLabel($0.count, sampleRate: sampleRate) } ?? "",
      stateLabel: clipStateLabel(clip.state),
      body: sliceSnippet(for: clip.wordIDs, words: words),
      wordIDs: clip.wordIDs,
      range: clip.range)
  }
}

/// Builds the clip-map rail segments from each clip's audio range. A clip without a valid range
/// is skipped (nothing to place on the rail). Fractions are clamped to `0...1`; a zero-width
/// range still renders a hairline so the rail never hides a clip entirely.
func makeClipMapSegments(
  from clips: [EditorClip], currentClipID: EditorClip.ID?, durationSamples: Int
) -> [ClipMapSegment] {
  guard durationSamples > 0 else { return [] }
  let total = Double(durationSamples)
  return clips.compactMap { clip in
    guard let range = clip.range else { return nil }
    let start = min(max(0, Double(range.lowerBound) / total), 1)
    let rawWidth = Double(range.count) / total
    let width = min(max(0.004, rawWidth), 1 - start)
    return ClipMapSegment(
      id: clip.id, startFraction: start, widthFraction: width,
      state: clip.state, isCurrent: clip.id == currentClipID)
  }
}

/// The `N approved · N suggested · N rejected` summary beside the rail. Always names all three
/// states (a zero count still shows) so the layout never reflows as clips change state.
func makeClipCountsSummary(_ clips: [EditorClip]) -> String {
  let approved = clips.filter { $0.state == .approved }.count
  let suggested = clips.filter { $0.state == .suggested }.count
  let rejected = clips.filter { $0.state == .rejected }.count
  return "\(approved) approved · \(suggested) suggested · \(rejected) rejected"
}
