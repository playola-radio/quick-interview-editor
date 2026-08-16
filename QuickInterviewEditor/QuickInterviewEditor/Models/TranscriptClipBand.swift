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
/// word-`text` colour, and whether the words are struck through. No AppKit here — the
/// renderer maps these tokens onto `NSColor`/attributes.
struct TranscriptClipStyle: Equatable {
  var fill: ClipStyleColor
  var ring: ClipStyleColor
  var text: ClipStyleColor
  var strikethrough: Bool

  /// The clip palette. Clip text is white for every live state; a rejected clip dims its words
  /// and strikes them through.
  ///
  /// A live clip (approved or suggested — most real clips are all one state) takes its colour
  /// from `variant` (the renderer passes each clip's position) so adjacent clips are obviously
  /// different: the palette cycles through genuinely distinct HUES (green, amber, blue, rose,
  /// purple), not shades of one family — the only thing that reliably tells one clip from the
  /// next when several sit back-to-back. Colour therefore marks clip boundaries, not the
  /// approve-vs-suggest state. Selected (the one current clip) is red and rejected reads by its
  /// dim+strike, so both ignore `variant`.
  static func style(for kind: TranscriptClipKind, variant: Int = 0) -> TranscriptClipStyle {
    switch kind {
    case .approved, .suggested:
      return cyclingPalette[cyclicIndex(variant, count: cyclingPalette.count)]
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

  /// Distinct-hue tints a live clip cycles through by position, ordered so no two neighbours in
  /// the cycle are close in hue. Green, amber, blue, rose, purple all read clearly on the dark
  /// transcript and are obviously different from one another.
  private static let cyclingPalette = [
    solidClip(red255: 95, green255: 185, blue255: 143),  // green
    solidClip(red255: 208, green255: 164, blue255: 95),  // amber
    solidClip(red255: 111, green255: 155, blue255: 230),  // blue
    solidClip(red255: 212, green255: 120, blue255: 140),  // rose
    solidClip(red255: 170, green255: 140, blue255: 215),  // purple
  ]

  /// A live clip style from one base colour: translucent fill, 1px ring, white text, no
  /// strikethrough. The fill/ring are opaque enough that the tint reads clearly on the dark
  /// transcript. The whole palette is built from this.
  private static func solidClip(red255: Double, green255: Double, blue255: Double)
    -> TranscriptClipStyle
  {
    TranscriptClipStyle(
      fill: ClipStyleColor(red255: red255, green255: green255, blue255: blue255, alpha: 0.28),
      ring: ClipStyleColor(red255: red255, green255: green255, blue255: blue255, alpha: 0.60),
      text: ClipStyleColor(red255: 255, green255: 255, blue255: 255, alpha: 1),
      strikethrough: false)
  }

  /// A non-negative index into a variant array for any (even negative) `variant`.
  private static func cyclicIndex(_ variant: Int, count: Int) -> Int {
    ((variant % count) + count) % count
  }
}

/// A drawable clip run: one contiguous UTF-16 range (words plus their interior separators)
/// and the state that colours it. The transcript model derives these from the bands +
/// document; the renderer strokes one rounded container per run.
struct TranscriptClipContainer: Equatable {
  let range: NSRange
  let kind: TranscriptClipKind
}
