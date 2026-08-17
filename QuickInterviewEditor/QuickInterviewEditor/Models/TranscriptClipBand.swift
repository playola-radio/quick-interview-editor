import Foundation

/// One clip drawn as a tinted container in the transcript. A read model derived by
/// `EditorModel` from its slices + pending cut suggestions and handed down to the
/// transcript, which renders what it's given (it decides nothing about clip state).
///
/// `wordIDs` are the words the container runs through, in no required order — the
/// renderer resolves them to ranges by transcript position, so an unsorted or sparse
/// list still frames the right span.
struct TranscriptClipBand: Equatable, Identifiable {
  let id: UUID
  let wordIDs: [Word.ID]
  let kind: TranscriptClipKind
}

/// The four clip states the container palette covers. Only `approved` (real slices) and
/// `suggested` (pending cut suggestions) are data-driven today; `selected` and `rejected`
/// are defined and styled now so the later interaction PR can light them up without a
/// palette change.
enum TranscriptClipKind: String, Equatable, CaseIterable {
  case approved
  case suggested
  case selected
  case rejected
}

/// A single-channel colour in 0…1 components, kept platform-neutral so the palette stays
/// in the (portable) model layer and the AppKit renderer converts it to `NSColor`.
struct ClipStyleColor: Equatable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double

  init(red: Double, green: Double, blue: Double, alpha: Double) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// Convenience for the 0–255 tints the mockup specifies (e.g. `rgba(95,185,143,.17)`).
  init(red255: Double, green255: Double, blue255: Double, alpha: Double) {
    self.init(red: red255 / 255, green: green255 / 255, blue: blue255 / 255, alpha: alpha)
  }
}

/// The pure look of a clip container for a given state: translucent `fill`, 1px `ring`,
/// word-`text` colour, whether the words are struck through, and whether the ring is `dashed`.
/// No AppKit here — the renderer maps these tokens onto `NSColor`/attributes/dash pattern.
struct TranscriptClipStyle: Equatable {
  var fill: ClipStyleColor
  var ring: ClipStyleColor
  var text: ClipStyleColor
  var strikethrough: Bool
  /// A dashed ring marks a tentative container. Suggestions dash their outline so a proposal
  /// reads instantly differently from a committed slice's solid box; every other state is solid.
  var dashed = false

  /// The clip palette. Clip text is white for every live state; a rejected clip dims its words
  /// and strikes them through.
  ///
  /// A live clip takes its colour from `variant` (the renderer passes each clip's position) so
  /// adjacent clips are obviously different: the palette cycles through genuinely distinct HUES
  /// (green, amber, blue, rose, purple), not shades of one family — the only thing that reliably
  /// tells one clip from the next when several sit back-to-back. Colour therefore marks clip
  /// boundaries, not the approve-vs-suggest state.
  ///
  /// Approved slices are the committed picks, so they read boldest: a filled, ringed container.
  /// Suggestions are just proposals, so they read as a fainter OUTLINE of the same hue — nearly
  /// no fill and a softer ring — so they never compete with the slices the user has actually
  /// kept. Selected (the one current clip) is red and rejected reads by its dim+strike, so both
  /// ignore `variant`.
  static func style(for kind: TranscriptClipKind, variant: Int = 0) -> TranscriptClipStyle {
    switch kind {
    case .approved:
      return approvedPalette[cyclicIndex(variant, count: approvedPalette.count)]
    case .suggested:
      return suggestedPalette[cyclicIndex(variant, count: suggestedPalette.count)]
    case .selected:
      return solidClip(red255: 204, green255: 102, blue255: 102)
    case .rejected:
      return TranscriptClipStyle(
        fill: ClipStyleColor(red255: 90, green255: 90, blue255: 90, alpha: 0.10),
        ring: ClipStyleColor(red255: 90, green255: 90, blue255: 90, alpha: 0.45),
        text: ClipStyleColor(red255: 107, green255: 107, blue255: 107, alpha: 1),
        strikethrough: true)
    }
  }

  /// One base tint (0–255) a live clip can take. Distinct hues a clip cycles through by position,
  /// ordered so no two neighbours in the cycle are close in hue.
  private struct ClipHue {
    let red: Double
    let green: Double
    let blue: Double
  }

  /// Green, amber, blue, rose, purple all read clearly on the dark transcript and are obviously
  /// different from one another. Both the approved and suggested palettes derive from these same
  /// hues, so a clip keeps its identity colour whichever state it's in — only the prominence
  /// (filled vs outline) changes.
  private static let clipHues = [
    ClipHue(red: 95, green: 185, blue: 143),  // green
    ClipHue(red: 208, green: 164, blue: 95),  // amber
    ClipHue(red: 111, green: 155, blue: 230),  // blue
    ClipHue(red: 212, green: 120, blue: 140),  // rose
    ClipHue(red: 170, green: 140, blue: 215),  // purple
  ]

  /// Approved slices: a filled, ringed container — the boldest live state.
  private static let approvedPalette = clipHues.map {
    solidClip(red255: $0.red, green255: $0.green, blue255: $0.blue)
  }

  /// Suggestions: the same hues rendered as a fainter outline (barely-there fill, softer ring)
  /// so a proposal never reads as prominently as a kept slice.
  private static let suggestedPalette = clipHues.map {
    outlineClip(red255: $0.red, green255: $0.green, blue255: $0.blue)
  }

  /// A live clip style from one base colour: translucent fill, 1px ring, white text, no
  /// strikethrough. The fill/ring are opaque enough that the tint reads clearly on the dark
  /// transcript. The approved palette is built from this.
  private static func solidClip(red255: Double, green255: Double, blue255: Double)
    -> TranscriptClipStyle
  {
    TranscriptClipStyle(
      fill: ClipStyleColor(red255: red255, green255: green255, blue255: blue255, alpha: 0.28),
      ring: ClipStyleColor(red255: red255, green255: green255, blue255: blue255, alpha: 0.60),
      text: ClipStyleColor(red255: 255, green255: 255, blue255: 255, alpha: 1),
      strikethrough: false)
  }

  /// An outline clip style from one base colour: barely-there fill and a softer, DASHED ring so a
  /// suggestion reads as a light, tentative frame — clearly different from an approved slice's
  /// solid box, not just a fainter one. Its words are a translucent white so they read like a
  /// faint cloud that recedes below the body text, blending toward the dark background rather than
  /// standing out (a suggestion under the playhead/selection still brightens to full white — that
  /// path is handled by the renderer's selection colour). The suggested palette is built from this.
  private static func outlineClip(red255: Double, green255: Double, blue255: Double)
    -> TranscriptClipStyle
  {
    TranscriptClipStyle(
      fill: ClipStyleColor(red255: red255, green255: green255, blue255: blue255, alpha: 0.06),
      ring: ClipStyleColor(red255: red255, green255: green255, blue255: blue255, alpha: 0.45),
      text: ClipStyleColor(red255: 255, green255: 255, blue255: 255, alpha: 0.5),
      strikethrough: false,
      dashed: true)
  }

  /// A non-negative index into a variant array for any (even negative) `variant`.
  private static func cyclicIndex(_ variant: Int, count: Int) -> Int {
    ((variant % count) + count) % count
  }
}

/// A drawable clip run: one contiguous UTF-16 range (words plus their interior separators),
/// the state that colours it, and the `colorIndex` of the CLIP it belongs to. The transcript
/// model derives these from the bands + document; the renderer strokes one rounded container
/// per run. `colorIndex` is per clip (not per run), so every run of the same clip — even one
/// split across a paragraph break — draws the same colour, while adjacent clips differ.
struct TranscriptClipContainer: Equatable {
  let range: NSRange
  let kind: TranscriptClipKind
  let colorIndex: Int
}
