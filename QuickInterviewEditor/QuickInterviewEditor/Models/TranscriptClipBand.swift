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
  /// The solid state colour (opaque), for a legend dot or rail — never the translucent fill.
  var swatch: ClipStyleColor
  var strikethrough: Bool

  /// The clip palette (based on `transcript-clip-blocks.md` §2). Clip text is white for every
  /// live state; a rejected clip dims its words and strikes them through.
  ///
  /// `variant` cycles the tint WITHIN a state's hue family so adjacent clips of the same state
  /// are distinguishable (the renderer passes each clip's position). Approved cycles through
  /// cool green/teal tints, suggested through warm amber/gold tints, so the state (cool vs warm)
  /// still reads while neighbours differ. Selected and rejected are single colours (one current
  /// clip; rejected reads by its dim+strike), so they ignore `variant`. Variant 0 is the base
  /// colour of each state.
  static func style(for kind: TranscriptClipKind, variant: Int = 0) -> TranscriptClipStyle {
    switch kind {
    case .approved:
      return approvedVariants[cyclicIndex(variant, count: approvedVariants.count)]
    case .suggested:
      return suggestedVariants[cyclicIndex(variant, count: suggestedVariants.count)]
    case .selected:
      return solidClip(red255: 204, green255: 102, blue255: 102)
    case .rejected:
      return TranscriptClipStyle(
        fill: ClipStyleColor(red255: 90, green255: 90, blue255: 90, alpha: 0.10),
        ring: ClipStyleColor(red255: 90, green255: 90, blue255: 90, alpha: 0.45),
        text: ClipStyleColor(red255: 107, green255: 107, blue255: 107, alpha: 1),
        swatch: ClipStyleColor(red255: 74, green255: 74, blue255: 74, alpha: 1),
        strikethrough: true)
    }
  }

  /// Cool tints for approved clips — green, blue, cyan — spread far enough apart in hue that
  /// adjacent approved clips are obviously different (variant 0 is the base green `#5fb98f`).
  private static let approvedVariants = [
    solidClip(red255: 95, green255: 185, blue255: 143),
    solidClip(red255: 95, green255: 160, blue255: 222),
    solidClip(red255: 70, green255: 200, blue255: 190),
  ]

  /// Warm tints for suggested clips — amber, orange, yellow (variant 0 is the base amber
  /// `#d0a45f`). Orange stays clear of the selected red so the two never read the same.
  private static let suggestedVariants = [
    solidClip(red255: 208, green255: 164, blue255: 95),
    solidClip(red255: 228, green255: 134, blue255: 66),
    solidClip(red255: 220, green255: 205, blue255: 96),
  ]

  /// A live clip style from one base colour: translucent fill, 1px ring, white text, opaque
  /// swatch, no strikethrough. The fill/ring are opaque enough that the tint reads clearly on
  /// the dark transcript. The whole per-state palette is built from this.
  private static func solidClip(red255: Double, green255: Double, blue255: Double)
    -> TranscriptClipStyle
  {
    TranscriptClipStyle(
      fill: ClipStyleColor(red255: red255, green255: green255, blue255: blue255, alpha: 0.28),
      ring: ClipStyleColor(red255: red255, green255: green255, blue255: blue255, alpha: 0.60),
      text: ClipStyleColor(red255: 255, green255: 255, blue255: 255, alpha: 1),
      swatch: ClipStyleColor(red255: red255, green255: green255, blue255: blue255, alpha: 1),
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

/// One entry in the transcript header legend: a clip state and its human label. The view
/// renders a swatch (from `TranscriptClipStyle.style(for:).swatch`) plus the label.
struct ClipLegendItem: Identifiable, Equatable {
  let kind: TranscriptClipKind
  let label: String
  var id: TranscriptClipKind { kind }
}
