import Foundation

// swiftlint:disable:next inclusive_language
enum MasteringPartPacking {
  static func pack(_ frameCounts: [Int], limit: Int = MasteringFormat.partLimitFrames)
    -> [Range<Int>]
  {
    precondition(limit > 0 && frameCounts.allSatisfy { $0 > 0 })
    guard !frameCounts.isEmpty else { return [] }
    var result: [Range<Int>] = []
    var start = 0
    var frames = 0
    for (index, count) in frameCounts.enumerated() {
      if frames > 0 && (count > limit || frames > limit - count) {
        result.append(start..<index)
        start = index
        frames = 0
      }
      frames += count
    }
    result.append(start..<frameCounts.count)
    return result
  }
}

// swiftlint:disable:next inclusive_language
enum MasteringFrames {
  static func conformed(_ frames: Int, fromRate rate: Int) -> Int {
    precondition(frames >= 0 && rate > 0)
    let (product, overflow) = Int64(frames).multipliedReportingOverflow(by: 44_100)
    precondition(!overflow)
    return Int((product + Int64(rate / 2)) / Int64(rate))
  }
}

// swiftlint:disable:next inclusive_language
enum MasteringLRC {
  static func text(wordStarts: [(frame: Int, text: String)]) -> String {
    wordStarts.compactMap { word -> String? in
      guard word.frame >= 0 else { return nil }
      let normalized = word.text.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\u{2028}", with: " ")
        .replacingOccurrences(of: "\u{2029}", with: " ")
        .components(separatedBy: .newlines).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty else { return nil }
      let centiseconds =
        (word.frame / 44_100) * 100
        + ((word.frame % 44_100) * 100 + 22_050) / 44_100
      return String(
        format: "[%02ld:%02ld.%02ld]", centiseconds / 6_000,
        (centiseconds / 100) % 60, centiseconds % 100) + normalized + "\n"
    }.joined()
  }
}
