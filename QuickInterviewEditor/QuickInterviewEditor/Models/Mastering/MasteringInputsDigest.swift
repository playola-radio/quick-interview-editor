import CryptoKit
import Foundation

// swiftlint:disable:next inclusive_language
enum MasteringInputsDigest {
  private struct Descriptor: Encodable {
    var canonicalFingerprint: String
    var artist: String
    var pieces: [Piece]
  }

  private struct Piece: Encodable {
    var sliceID: UUID
    var lower: Int
    var upper: Int
    var title: String
    var typeID: String
    var typeProvenance: String
    var removals: [Removal]
    var words: [Word]
  }

  private struct Removal: Encodable {
    var lower: Int
    var upper: Int
    var crossfade: Crossfade
  }

  private struct Word: Encodable {
    var position: Int
    var text: String
  }

  static func make(
    source: ProjectSource, artist: String, pieces: [MasteringPieceInput],
    typeIDs: [Slice.ID: String]
  ) -> String {
    let descriptor = Descriptor(
      canonicalFingerprint: source.canonicalFingerprint, artist: artist,
      pieces: pieces.map { piece in
        Piece(
          sliceID: piece.sliceID, lower: piece.sourceRange.lowerBound,
          upper: piece.sourceRange.upperBound, title: piece.title,
          typeID: typeIDs[piece.sliceID] ?? "", typeProvenance: piece.typeProvenance,
          removals: piece.localRemovals.map {
            Removal(
              lower: $0.removedRange.lowerBound, upper: $0.removedRange.upperBound,
              crossfade: $0.crossfade)
          },
          words: piece.wordStarts.map { Word(position: $0.position, text: $0.name) })
      })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    // The descriptor contains only primitive values with defined JSON encodings.
    guard let data = try? encoder.encode(descriptor) else {
      preconditionFailure("Mastering digest descriptor could not be serialized")
    }
    return "v1:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
