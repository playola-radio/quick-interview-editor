import CustomDump
import Testing

@testable import QuickInterviewEditor

struct TranscriptClipStyleTests {

  /// A live clip (approved or suggested) takes its colour from the shared cycling palette, so
  /// the two states share a style for a given position — colour marks the clip boundary, not
  /// the state.
  @Test func approvedAndSuggestedShareTheCyclingPalette() {
    for variant in 0..<6 {
      expectNoDifference(
        TranscriptClipStyle.style(for: .approved, variant: variant),
        TranscriptClipStyle.style(for: .suggested, variant: variant))
    }
  }

  /// Variant 0 is the palette base (green) and every live variant keeps white text, no strike.
  @Test func liveVariantsAreWhiteTextNoStrike() {
    expectNoDifference(
      TranscriptClipStyle.style(for: .approved, variant: 0).fill,
      ClipStyleColor(red255: 95, green255: 185, blue255: 143, alpha: 0.28))
    for variant in 0..<6 {
      let style = TranscriptClipStyle.style(for: .suggested, variant: variant)
      expectNoDifference(
        style.text, ClipStyleColor(red255: 255, green255: 255, blue255: 255, alpha: 1))
      expectNoDifference(style.strikethrough, false)
    }
  }

  /// The palette cycles through genuinely distinct hues: the five swatches are all different, so
  /// adjacent clips never share a colour.
  @Test func paletteHuesAreAllDistinct() {
    let fills = (0..<5).map { TranscriptClipStyle.style(for: .suggested, variant: $0).fill }
    let keys = fills.map { "\($0.red),\($0.green),\($0.blue),\($0.alpha)" }
    expectNoDifference(Set(keys).count, fills.count)
  }

  /// The variant wraps, so an out-of-range or negative position is safe.
  @Test func variantWraps() {
    let base = TranscriptClipStyle.style(for: .approved, variant: 0)
    expectNoDifference(TranscriptClipStyle.style(for: .approved, variant: 5), base)
    expectNoDifference(TranscriptClipStyle.style(for: .approved, variant: -5), base)
  }

  @Test func selectedIsPlayolaRed() {
    expectNoDifference(
      TranscriptClipStyle.style(for: .selected),
      TranscriptClipStyle(
        fill: ClipStyleColor(red255: 204, green255: 102, blue255: 102, alpha: 0.28),
        ring: ClipStyleColor(red255: 204, green255: 102, blue255: 102, alpha: 0.60),
        text: ClipStyleColor(red255: 255, green255: 255, blue255: 255, alpha: 1),
        strikethrough: false))
  }

  @Test func rejectedIsDimGrayStruckThrough() {
    expectNoDifference(
      TranscriptClipStyle.style(for: .rejected),
      TranscriptClipStyle(
        fill: ClipStyleColor(red255: 90, green255: 90, blue255: 90, alpha: 0.10),
        ring: ClipStyleColor(red255: 90, green255: 90, blue255: 90, alpha: 0.45),
        text: ClipStyleColor(red255: 107, green255: 107, blue255: 107, alpha: 1),
        strikethrough: true))
  }

  /// Selected and rejected are single colours — they ignore the variant.
  @Test func selectedAndRejectedIgnoreVariant() {
    expectNoDifference(
      TranscriptClipStyle.style(for: .selected, variant: 0),
      TranscriptClipStyle.style(for: .selected, variant: 2))
    expectNoDifference(
      TranscriptClipStyle.style(for: .rejected, variant: 0),
      TranscriptClipStyle.style(for: .rejected, variant: 2))
  }

  /// Only the rejected state dims + strikes.
  @Test func onlyRejectedStrikesThrough() {
    for kind in TranscriptClipKind.allCases {
      expectNoDifference(TranscriptClipStyle.style(for: kind).strikethrough, kind == .rejected)
    }
  }
}
