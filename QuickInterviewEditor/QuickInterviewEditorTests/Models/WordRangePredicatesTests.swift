import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct WordRangePredicatesTests {
  private func word(_ id: Int, _ start: Int, _ end: Int) -> Word {
    Word(id: id, text: "w\(id)", start: 0, end: 0, startSample: start, endSample: end)
  }

  private let words: [Word] = [
    // id: [start, end)
    // 1:[0,100) 2:[100,200) 3:[200,300)
  ]

  @Test func fullyContainedRequiresBothEdgesInside() {
    let ws = [word(1, 0, 100), word(2, 100, 200), word(3, 200, 300)]
    // Removal [100,200) fully contains only word 2.
    expectNoDifference(wordIDs(fullyContainedIn: 100..<200, words: ws), [2])
  }

  @Test func fullyContainedIsInclusiveOnBothBounds() {
    let ws = [word(2, 100, 200)]
    // Touching exactly: start == lower, end == upper → contained.
    expectNoDifference(wordIDs(fullyContainedIn: 100..<200, words: ws), [2])
    // One sample short on either side → not contained.
    expectNoDifference(wordIDs(fullyContainedIn: 101..<200, words: ws), [])
    expectNoDifference(wordIDs(fullyContainedIn: 100..<199, words: ws), [])
  }

  @Test func overlapIsAnyIntersection() {
    let ws = [word(1, 0, 100), word(2, 100, 200), word(3, 200, 300)]
    // [150,250) overlaps words 2 and 3, not 1.
    expectNoDifference(wordIDs(anyOverlap: 150..<250, words: ws), [2, 3])
  }

  @Test func overlapIsHalfOpenAtEdges() {
    let ws = [word(1, 0, 100), word(2, 100, 200)]
    // A range that ends exactly at word 2's start does NOT overlap it (half-open).
    expectNoDifference(wordIDs(anyOverlap: 0..<100, words: ws), [1])
    // A range starting one sample before word 2's end overlaps it.
    expectNoDifference(wordIDs(anyOverlap: 199..<400, words: ws), [2])
  }

  @Test func skipsWordsMissingOrDegenerateBounds() {
    let ws = [
      Word(id: 9, text: "x", start: 0, end: 0, startSample: nil, endSample: nil),
      word(5, 100, 100),  // zero-span
      word(6, 100, 200),
    ]
    expectNoDifference(wordIDs(anyOverlap: 0..<1000, words: ws), [6])
    expectNoDifference(wordIDs(fullyContainedIn: 0..<1000, words: ws), [6])
  }
}
