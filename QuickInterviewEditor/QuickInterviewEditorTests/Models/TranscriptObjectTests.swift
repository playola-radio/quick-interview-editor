import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct TranscriptObjectTests {
  private func object(_ index: Int, words: Set<Word.ID> = [2, 3]) -> TranscriptObject {
    TranscriptObject(
      id: .clip(Fixtures.uuid(index)), name: "Clip \(index)", range: 100..<200,
      wordIDs: words, colorIndex: index)
  }

  @Test func identicalOverlapsKeepEveryCandidate() {
    let objects = [object(1), object(2), object(3)]
    expectNoDifference(objectsCovering(2, objects: objects, selected: nil), objects)
  }

  @Test func selectedObjectPromotesWithoutChangingOtherOrderOrColors() {
    let objects = [object(1), object(2), object(3)]
    expectNoDifference(
      foregroundObjects(objects, selected: objects[1].id), [objects[1], objects[0], objects[2]])
    expectNoDifference(
      objectsCovering(2, objects: objects, selected: objects[1].id),
      [objects[1], objects[0], objects[2]])
  }

  @Test func selectedObjectCannotHitOutsideItsMembership() {
    let objects = [object(1), object(2, words: [4])]
    expectNoDifference(objectsCovering(2, objects: objects, selected: objects[1].id), [objects[0]])
    expectNoDifference(objectsCovering(9, objects: objects, selected: objects[1].id), [])
  }

  @Test func typedIdentityDistinguishesAcceptedSuggestionUUID() {
    let id = Fixtures.uuid(1)
    expectNoDifference(Set<TranscriptObjectID>([.clip(id), .suggestion(id)]).count, 2)
    expectNoDifference(EditorSelection.object(.clip(id)).objectID, .clip(id))
    expectNoDifference(EditorSelection.object(.clip(id)).freeformRange, nil)
    expectNoDifference(EditorSelection.range(10..<20, anchor: 20).freeformRange, 10..<20)
  }
}
