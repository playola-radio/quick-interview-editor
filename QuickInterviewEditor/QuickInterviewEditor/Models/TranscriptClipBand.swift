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

  /// The mockup's clip palette (`transcript-clip-blocks.md` §2). Clip text is white for
  /// every live state; a rejected clip dims its words and strikes them through.
  static func style(for kind: TranscriptClipKind) -> TranscriptClipStyle {
    switch kind {
    case .approved:
      return TranscriptClipStyle(
        fill: ClipStyleColor(red255: 95, green255: 185, blue255: 143, alpha: 0.17),
        ring: ClipStyleColor(red255: 95, green255: 185, blue255: 143, alpha: 0.45),
        text: ClipStyleColor(red255: 255, green255: 255, blue255: 255, alpha: 1),
        swatch: ClipStyleColor(red255: 95, green255: 185, blue255: 143, alpha: 1),
        strikethrough: false)
    case .suggested:
      return TranscriptClipStyle(
        fill: ClipStyleColor(red255: 208, green255: 164, blue255: 95, alpha: 0.17),
        ring: ClipStyleColor(red255: 208, green255: 164, blue255: 95, alpha: 0.45),
        text: ClipStyleColor(red255: 255, green255: 255, blue255: 255, alpha: 1),
        swatch: ClipStyleColor(red255: 208, green255: 164, blue255: 95, alpha: 1),
        strikethrough: false)
    case .selected:
      return TranscriptClipStyle(
        fill: ClipStyleColor(red255: 204, green255: 102, blue255: 102, alpha: 0.17),
        ring: ClipStyleColor(red255: 204, green255: 102, blue255: 102, alpha: 0.45),
        text: ClipStyleColor(red255: 255, green255: 255, blue255: 255, alpha: 1),
        swatch: ClipStyleColor(red255: 204, green255: 102, blue255: 102, alpha: 1),
        strikethrough: false)
    case .rejected:
      return TranscriptClipStyle(
        fill: ClipStyleColor(red255: 90, green255: 90, blue255: 90, alpha: 0.10),
        ring: ClipStyleColor(red255: 90, green255: 90, blue255: 90, alpha: 0.45),
        text: ClipStyleColor(red255: 107, green255: 107, blue255: 107, alpha: 1),
        swatch: ClipStyleColor(red255: 74, green255: 74, blue255: 74, alpha: 1),
        strikethrough: true)
    }
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
