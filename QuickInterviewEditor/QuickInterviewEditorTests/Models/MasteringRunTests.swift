import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

// swiftlint:disable:next inclusive_language
struct MasteringRunTests {
  @Test func duplicatePieceIdentityCannotRemainFinished() {
    let name = Fixtures.uuid(30).uuidString.lowercased() + ".m4a"
    let ref = MasteringArtifactRef(fileName: name, byteCount: 4)
    let second = MasteringArtifactRef(
      fileName: Fixtures.uuid(36).uuidString.lowercased() + ".m4a",
      byteCount: 4)
    let piece = MasteringPiece(
      id: Fixtures.uuid(31), sliceID: Fixtures.uuid(32), title: "Intro",
      startFrame: 0, frameCount: 10, lrc: "", finished: ref)
    let run = MasteringRun(
      id: Fixtures.uuid(33), artist: "Artist", inputsDigest: "v1:x",
      parts: [
        MasteringPart(id: Fixtures.uuid(34), frameCount: 10, prepared: nil, pieces: [piece]),
        MasteringPart(
          id: Fixtures.uuid(35), frameCount: 10, prepared: nil,
          pieces: [
            MasteringPiece(
              id: piece.id, sliceID: Fixtures.uuid(37), title: "Another", startFrame: 0,
              frameCount: 10, lrc: "", finished: second)
          ]),
      ])
    let healed = run.healed(available: [name: 4, second.fileName: 4])
    expectNoDifference(healed.parts[0].pieces[0].finished, ref)
    expectNoDifference(healed.parts[1].pieces[0].finished, nil)
  }
  @Test func healedClearsOnlyMissingReferences() {
    let prepared = MasteringArtifactRef(
      fileName: Fixtures.uuid(1).uuidString.lowercased() + ".wav", byteCount: 5)
    let finished = MasteringArtifactRef(
      fileName: Fixtures.uuid(2).uuidString.lowercased() + ".m4a", byteCount: 4)
    let missing = MasteringArtifactRef(
      fileName: Fixtures.uuid(3).uuidString.lowercased() + ".m4a", byteCount: 4)
    let run = MasteringRun(
      id: Fixtures.uuid(4), artist: "Artist", inputsDigest: "v1:x",
      parts: [
        MasteringPart(
          id: Fixtures.uuid(5), frameCount: 20, prepared: prepared,
          pieces: [
            MasteringPiece(
              id: Fixtures.uuid(6), sliceID: Fixtures.uuid(7), title: "One", startFrame: 0,
              frameCount: 10, lrc: "", finished: finished),
            MasteringPiece(
              id: Fixtures.uuid(8), sliceID: Fixtures.uuid(9), title: "Two", startFrame: 10,
              frameCount: 10, lrc: "", finished: missing),
          ])
      ])
    let healed = run.healed(available: [prepared.fileName: 5, finished.fileName: 4])
    expectNoDifference(healed.parts[0].prepared, prepared)
    expectNoDifference(healed.parts[0].pieces[0].finished, finished)
    expectNoDifference(healed.parts[0].pieces[1].finished, nil)
    expectNoDifference(healed.parts[0].isReturned, false)
  }

  @Test func rejectsUnownedArtifactNames() {
    let name = Fixtures.uuid(1).uuidString.lowercased()
    expectNoDifference(
      MasteringArtifactRef(fileName: name + ".wav", byteCount: 1).isWellFormed, true)
    expectNoDifference(
      MasteringArtifactRef(fileName: "../" + name + ".wav", byteCount: 1).isWellFormed, false)
    expectNoDifference(
      MasteringArtifactRef(fileName: name + ".aiff", byteCount: 1).isWellFormed, false)
    expectNoDifference(
      MasteringArtifactRef(fileName: name + ".wav", byteCount: 0).isWellFormed, false)
  }
}
