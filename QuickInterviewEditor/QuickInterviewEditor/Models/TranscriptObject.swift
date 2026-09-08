import Foundation

struct TranscriptObject: Equatable, Identifiable, Sendable {
  let id: TranscriptObjectID
  let name: String
  let range: Range<Int>
  let wordIDs: Set<Word.ID>
  let colorIndex: Int
}

func foregroundObjects(
  _ objects: [TranscriptObject], selected: TranscriptObjectID?
) -> [TranscriptObject] {
  guard let selected, let index = objects.firstIndex(where: { $0.id == selected }) else {
    return objects
  }
  var result = objects
  result.insert(result.remove(at: index), at: 0)
  return result
}

func objectsCovering(
  _ wordID: Word.ID, objects: [TranscriptObject], selected: TranscriptObjectID?
) -> [TranscriptObject] {
  foregroundObjects(objects, selected: selected).filter { $0.wordIDs.contains(wordID) }
}
