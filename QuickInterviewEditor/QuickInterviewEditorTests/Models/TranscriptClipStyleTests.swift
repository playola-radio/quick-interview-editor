import CustomDump
import Testing

@testable import QuickInterviewEditor

struct TranscriptClipStyleTests {

  @Test func approvedIsGreenWhiteTextNoStrike() {
    expectNoDifference(
      TranscriptClipStyle.style(for: .approved),
      TranscriptClipStyle(
        fill: ClipStyleColor(red255: 95, green255: 185, blue255: 143, alpha: 0.17),
        ring: ClipStyleColor(red255: 95, green255: 185, blue255: 143, alpha: 0.45),
        text: ClipStyleColor(red255: 255, green255: 255, blue255: 255, alpha: 1),
        swatch: ClipStyleColor(red255: 95, green255: 185, blue255: 143, alpha: 1),
        strikethrough: false))
  }

  @Test func suggestedIsAmberWhiteTextNoStrike() {
    expectNoDifference(
      TranscriptClipStyle.style(for: .suggested),
      TranscriptClipStyle(
        fill: ClipStyleColor(red255: 208, green255: 164, blue255: 95, alpha: 0.17),
        ring: ClipStyleColor(red255: 208, green255: 164, blue255: 95, alpha: 0.45),
        text: ClipStyleColor(red255: 255, green255: 255, blue255: 255, alpha: 1),
        swatch: ClipStyleColor(red255: 208, green255: 164, blue255: 95, alpha: 1),
        strikethrough: false))
  }

  @Test func selectedIsPlayolaRedWhiteTextNoStrike() {
    expectNoDifference(
      TranscriptClipStyle.style(for: .selected),
      TranscriptClipStyle(
        fill: ClipStyleColor(red255: 204, green255: 102, blue255: 102, alpha: 0.17),
        ring: ClipStyleColor(red255: 204, green255: 102, blue255: 102, alpha: 0.45),
        text: ClipStyleColor(red255: 255, green255: 255, blue255: 255, alpha: 1),
        swatch: ClipStyleColor(red255: 204, green255: 102, blue255: 102, alpha: 1),
        strikethrough: false))
  }

  @Test func rejectedIsDimGrayStruckThrough() {
    expectNoDifference(
      TranscriptClipStyle.style(for: .rejected),
      TranscriptClipStyle(
        fill: ClipStyleColor(red255: 90, green255: 90, blue255: 90, alpha: 0.10),
        ring: ClipStyleColor(red255: 90, green255: 90, blue255: 90, alpha: 0.45),
        text: ClipStyleColor(red255: 107, green255: 107, blue255: 107, alpha: 1),
        swatch: ClipStyleColor(red255: 74, green255: 74, blue255: 74, alpha: 1),
        strikethrough: true))
  }

  /// Only the rejected state dims + strikes; every live clip keeps white text so it reads
  /// against the container fill.
  @Test func onlyRejectedStrikesThrough() {
    for kind in TranscriptClipKind.allCases {
      expectNoDifference(TranscriptClipStyle.style(for: kind).strikethrough, kind == .rejected)
    }
  }

  /// Adjacent clips of the same state cycle to a different tint so they read as distinct runs.
  @Test func variantCyclesTheTintWithinAState() {
    #expect(
      TranscriptClipStyle.style(for: .approved, variant: 0)
        != TranscriptClipStyle.style(for: .approved, variant: 1))
    #expect(
      TranscriptClipStyle.style(for: .suggested, variant: 0)
        != TranscriptClipStyle.style(for: .suggested, variant: 1))
    // Every approved variant stays white-text, no-strike (still reads as a live clip).
    for variant in 0..<5 {
      let style = TranscriptClipStyle.style(for: .approved, variant: variant)
      expectNoDifference(
        style.text, ClipStyleColor(red255: 255, green255: 255, blue255: 255, alpha: 1))
      expectNoDifference(style.strikethrough, false)
    }
  }

  /// The variant wraps (so an out-of-range or negative position is safe) and variant 0 is the
  /// documented base colour.
  @Test func variantWrapsAndZeroIsTheBaseColour() {
    let base = TranscriptClipStyle.style(for: .approved, variant: 0)
    expectNoDifference(
      base.swatch, ClipStyleColor(red255: 95, green255: 185, blue255: 143, alpha: 1))
    expectNoDifference(TranscriptClipStyle.style(for: .approved, variant: 3), base)
    expectNoDifference(TranscriptClipStyle.style(for: .approved, variant: -3), base)
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
}
