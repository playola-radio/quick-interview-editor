import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct ExportNamingTests {
  @Test func defaultNameCombinesStemAndSliceName() {
    var taken: Set<String> = []
    expectNoDifference(
      exportFileName(sourceStem: "interview", sliceName: "Intro", index: 1, taken: &taken),
      "interview - Intro.aiff")
  }

  @Test func emptyNameFallsBackToZeroPaddedSlice() {
    var taken: Set<String> = []
    expectNoDifference(
      exportFileName(sourceStem: "interview", sliceName: "   ", index: 7, taken: &taken),
      "interview - Slice 007.aiff")
  }

  @Test func illegalCharactersAreStripped() {
    var taken: Set<String> = []
    let name = exportFileName(
      sourceStem: "interview", sliceName: "a/b:c\\d", index: 1, taken: &taken)
    #expect(!name.dropLast(".aiff".count).contains("/"))
    #expect(!name.contains(":"))
    #expect(!name.contains("\\"))
    expectNoDifference(name, "interview - a-b-c-d.aiff")
  }

  @Test func leadingDotsAreStrippedSoNoDotfiles() {
    var taken: Set<String> = []
    let name = exportFileName(
      sourceStem: "interview", sliceName: "..secret", index: 1, taken: &taken)
    expectNoDifference(name, "interview - secret.aiff")
  }

  @Test func collidingNamesGetNumericSuffixes() {
    var taken: Set<String> = []
    let first = exportFileName(sourceStem: "interview", sliceName: "Intro", index: 1, taken: &taken)
    let second = exportFileName(
      sourceStem: "interview", sliceName: "Intro", index: 2, taken: &taken)
    let third = exportFileName(sourceStem: "interview", sliceName: "Intro", index: 3, taken: &taken)
    expectNoDifference(
      [first, second, third],
      [
        "interview - Intro.aiff", "interview - Intro 2.aiff", "interview - Intro 3.aiff",
      ])
  }

  @Test func collisionCheckIsCaseInsensitive() {
    var taken: Set<String> = ["interview - intro.aiff"]
    let name = exportFileName(sourceStem: "interview", sliceName: "Intro", index: 1, taken: &taken)
    expectNoDifference(name, "interview - Intro 2.aiff")
  }

  @Test func collidesWithExistingFolderContents() {
    var taken: Set<String> = ["interview - slice 001.aiff"]
    let name = exportFileName(sourceStem: "interview", sliceName: "", index: 1, taken: &taken)
    expectNoDifference(name, "interview - Slice 001 2.aiff")
  }
}
