import CustomDump
import Testing

@testable import PlayolaInterviewEditor

// swiftlint:disable:next inclusive_language
struct MasteringPolicyTests {
  @Test func packsWholePiecesWithoutAnEmptyTrailingPart() {
    expectNoDifference(MasteringPartPacking.pack([5, 5, 11, 2], limit: 10), [0..<2, 2..<3, 3..<4])
    expectNoDifference(MasteringPartPacking.pack([20], limit: 10), [0..<1])
    expectNoDifference(MasteringPartPacking.pack([], limit: 10), [])
  }

  @Test func preservesRoundedWordOrderAndDoesNotWrapLongMinutes() {
    expectNoDifference(
      MasteringLRC.text(wordStarts: [(0, "Hello"), (1, "a\nb"), (26_901, "café")]),
      "[00:00.00]Hello\n[00:00.00]a b\n[00:00.61]café\n")
    expectNoDifference(
      MasteringLRC.text(wordStarts: [(264_600_000, "late")]), "[100:00.00]late\n")
  }
}
