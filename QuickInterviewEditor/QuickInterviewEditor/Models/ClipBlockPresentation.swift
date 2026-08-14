import Foundation

/// One clip rendered as an inline block in the transcript flow. The renderer tints the clip's
/// word glyphs by `state` (red when `isCurrent`) and draws the ring + rounded ends over them.
/// This carries only what the block draw + hit-test needs — the card VM's body/header/label
/// fields don't apply to blocks. `wordIDs` are in transcript order; `.first`/`.last` are the
/// drag handles. Colors stay the view's job: the model hands it state + currentness only.
struct ClipBlockVM: Identifiable, Equatable, Sendable {
  var id: EditorClip.ID
  var state: ClipState
  var isCurrent: Bool
  var wordIDs: [Word.ID]
}

/// The transcript footer's current-clip summary: the state (for the dot color), a composed
/// `N · Title · duration · word count` line, and a live hint. Duration/word-count are live-draft
/// aware (they track a boundary edit in progress). Nil when no clip is current.
struct CurrentClipFooterVM: Equatable, Sendable {
  var number: Int
  var state: ClipState
  var title: String
  var durationLabel: String
  var wordCountLabel: String
  var hint: String

  /// `N · Title · duration · NN words` — the view styles it in the state color; the model
  /// composes it. Duration is dropped only for a degenerate clip with no valid range.
  var line: String {
    var parts = ["\(number)", title]
    if !durationLabel.isEmpty { parts.append(durationLabel) }
    parts.append(wordCountLabel)
    return parts.joined(separator: " · ")
  }
}
