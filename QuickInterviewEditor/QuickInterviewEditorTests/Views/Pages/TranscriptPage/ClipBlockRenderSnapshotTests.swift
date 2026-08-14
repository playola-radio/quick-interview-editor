import AppKit
import Testing

@testable import QuickInterviewEditor

/// Not an assertion suite — a manual visual harness. It rasterizes the clip-block renderer over a
/// fixture paragraph so the band geometry can be eyeballed against the design reference. Writes a
/// PNG to /tmp; disabled by default so CI doesn't render.
@MainActor
struct ClipBlockRenderSnapshotTests {

  // Enable locally to iterate on band geometry: comment out `.disabled`, run the full test suite,
  // then open /tmp/qie-band-snapshot.png and compare to the design reference.
  @Test(.disabled("manual visual check — writes /tmp/qie-band-snapshot.png"))
  func renderBandSnapshot() throws {
    let pre = "The earliest ones were... "
    let body =
      "A big one for me when I was young was Jimmy Buffett. I grew up in the suburbs and he "
      + "was singing about this romantic life of sailing and going to Paris and being "
      + "debaucherous and having fun and just fully living in a way that seemed really cool to me"
    let post = " and where I was coming from. I remember I wrote Jimmy a letter."
    let text = pre + body + post

    let container = NSTextContainer(
      size: NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    let layoutManager = ClipBlockLayoutManager()
    layoutManager.addTextContainer(container)
    let storage = NSTextStorage(string: text)
    storage.addLayoutManager(layoutManager)
    let full = NSRange(location: 0, length: storage.length)
    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 16.5), range: full)
    storage.addAttribute(.foregroundColor, value: NSColor(white: 0.56, alpha: 1), range: full)
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = 2.15
    storage.addAttribute(.paragraphStyle, value: style, range: full)

    // The clip = the `body` run. White text over it, plus per-word ranges for the band.
    let bodyRange = (text as NSString).range(of: body)
    storage.addAttribute(.foregroundColor, value: NSColor(white: 0.96, alpha: 1), range: bodyRange)
    let green = NSColor(calibratedRed: 0.373, green: 0.725, blue: 0.561, alpha: 1)
    layoutManager.blocks = [
      ClipBlockDraw(
        charRange: bodyRange, wordRanges: wordRanges(in: bodyRange, of: text),
        fillColor: green.withAlphaComponent(0.17), ringColor: green.withAlphaComponent(0.45),
        hoverCharRange: nil, hoverColor: green.withAlphaComponent(0.30))
    ]

    let textView = NSTextView(
      frame: NSRect(x: 0, y: 0, width: 800, height: 500), textContainer: container)
    textView.backgroundColor = NSColor(white: 0.05, alpha: 1)
    textView.textContainerInset = NSSize(width: 18, height: 18)
    layoutManager.ensureLayout(for: container)
    let used = layoutManager.usedRect(for: container)
    textView.frame = NSRect(x: 0, y: 0, width: 800, height: used.height + 60)

    let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
    textView.cacheDisplay(in: textView.bounds, to: rep)
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/qie-band-snapshot.png"))
  }

  /// Splits a character range into its whitespace-separated word ranges (UTF-16), for the band.
  private func wordRanges(in range: NSRange, of text: String) -> [NSRange] {
    let ns = text as NSString
    var ranges: [NSRange] = []
    var index = range.location
    let end = range.location + range.length
    while index < end {
      // skip spaces
      while index < end, ns.substring(with: NSRange(location: index, length: 1)) == " " {
        index += 1
      }
      guard index < end else { break }
      let wordStart = index
      while index < end, ns.substring(with: NSRange(location: index, length: 1)) != " " {
        index += 1
      }
      ranges.append(NSRange(location: wordStart, length: index - wordStart))
    }
    return ranges
  }
}
