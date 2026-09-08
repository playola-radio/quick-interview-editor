import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct ExportNamingTests {
  @Test func oversizedSingleGraphemeDoesNotCreateHiddenEmptyFilename() {
    var taken: Set<String> = []
    let name = exportFileName(
      sourceStem: "Tape", sliceName: "a" + String(repeating: "\u{301}", count: 200), index: 1,
      taken: &taken, policy: .exactClipName)
    expectNoDifference(name, "Slice 001.aiff")
  }
  private func clip(_ number: Int, name: String, generated: Bool = true) -> Slice {
    var slice = Slice(
      id: Fixtures.uuid(number), name: name, startSample: 0, endSample: 100,
      wordIDs: [], snippet: "")
    slice.suggestionTypeID = "intro"
    if generated {
      slice.suggestionNaming = .init(
        runID: Fixtures.uuid(90), typeID: number == 1 ? "intro" : "spotlight",
        typeName: "Type", typeGroup: .songIntros, discoveryLabel: "Original", extractedValues: [:],
        missingFieldIDs: [], correctedValues: [:], reservation: nil)
    }
    return slice
  }

  @Test func generatedCollisionMappingsUseCurrentNameAndFlagBothSides() {
    let slices = [clip(1, name: "ID 1"), clip(2, name: "ID 1")]
    let mappings = preflightExportNames(slices: slices, sourceStem: "Tape", existing: [])
    expectNoDifference(
      mappings,
      [
        .init(
          id: slices[0].id, requestedName: "ID 1.aiff", proposedName: "ID 1.aiff",
          requiresConfirmation: true),
        .init(
          id: slices[1].id, requestedName: "ID 1.aiff", proposedName: "ID 1 2.aiff",
          requiresConfirmation: true),
      ])
    expectNoDifference(
      preflightExportNames(slices: [clip(1, name: "Renamed")], sourceStem: "Tape", existing: [])
        .first?.requestedName, "Renamed.aiff")
  }

  @Test func existingCaseSanitizedAndTruncatedNamesCollide() {
    let existing = preflightExportNames(
      slices: [clip(1, name: "ID 1")], sourceStem: "Tape", existing: ["id 1.aiff"])
    expectNoDifference(existing.first?.proposedName, "ID 1 2.aiff")
    #expect(existing.first?.requiresConfirmation == true)
    for names in [
      ["A/B", "A:B"], ["Name", "NAME"],
      [String(repeating: "😀", count: 100) + "a", String(repeating: "😀", count: 100) + "b"],
    ] {
      let mapped = preflightExportNames(
        slices: [clip(1, name: names[0]), clip(2, name: names[1])], sourceStem: "Tape", existing: []
      )
      #expect(mapped.allSatisfy { $0.requiresConfirmation })
      #expect(mapped.allSatisfy { $0.proposedName.utf8.count <= 255 })
      expectNoDifference(Set(mapped.map(\.proposedName)).count, 2)
    }
  }

  @Test func legacyOnlyCollisionsAreSilentButLegacyAfterGeneratedRequiresReview() {
    let manual = [clip(1, name: "A", generated: false), clip(2, name: "A", generated: false)]
    let legacy = preflightExportNames(slices: manual, sourceStem: "Tape", existing: [])
    expectNoDifference(legacy.map(\.proposedName), ["Tape - A.aiff", "Tape - A 2.aiff"])
    #expect(legacy.allSatisfy { !$0.requiresConfirmation })
    let mixed = preflightExportNames(
      slices: [clip(1, name: "Tape - A"), manual[1]], sourceStem: "Tape", existing: [])
    #expect(mixed.allSatisfy { $0.requiresConfirmation })
  }

  @Test func suffixesBeyond999BudgetActualBytesAndCannotIntegerOverflow() {
    var taken: Set<String> = []
    var last = ""
    for _ in 1...1001 {
      last = exportFileName(
        sourceStem: "Tape", sliceName: String(repeating: "😀", count: 100), index: 1, taken: &taken,
        policy: .exactClipName)
      #expect(last.utf8.count <= 255)
    }
    #expect(last.hasSuffix(" 1001.aiff"))
    expectNoDifference(taken.count, 1001)
    expectNoDifference(nextExportCollisionSuffix(String(Int.max)), "9223372036854775808")
  }
  @Test func generatedNamesDoNotIncludeSourceStem() {
    var taken: Set<String> = []
    expectNoDifference(
      exportFileName(
        sourceStem: "Tape Two", sliceName: "ID 7", index: 1, taken: &taken, policy: .exactClipName),
      "ID 7.aiff")
  }
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

  @Test func filenameIsCappedAt255UTF8Bytes() {
    var taken: Set<String> = []
    let name = exportFileName(
      sourceStem: String(repeating: "s", count: 300),
      sliceName: String(repeating: "n", count: 300), index: 1, taken: &taken)
    #expect(name.utf8.count <= 255)
    #expect(name.hasSuffix(".aiff"))
  }

  @Test func longMultibyteNameStaysValidAndUnderTheByteCap() {
    var taken: Set<String> = []
    // Each emoji is 4 UTF-8 bytes; truncation must not split one.
    let name = exportFileName(
      sourceStem: "interview", sliceName: String(repeating: "😀", count: 200), index: 1,
      taken: &taken)
    #expect(name.utf8.count <= 255)
    #expect(name.hasSuffix(".aiff"))
    #expect(!name.isEmpty)
  }

  @Test func collidesWithExistingFolderContents() {
    var taken: Set<String> = ["interview - slice 001.aiff"]
    let name = exportFileName(sourceStem: "interview", sliceName: "", index: 1, taken: &taken)
    expectNoDifference(name, "interview - Slice 001 2.aiff")
  }
}
