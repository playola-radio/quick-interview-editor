import Foundation

// swiftlint:disable:next inclusive_language
struct MasteringArtifactRef: Codable, Hashable, Sendable {
  var fileName: String
  var byteCount: Int

  var isWellFormed: Bool {
    guard byteCount > 0 else { return false }
    let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[1] == "wav" || parts[1] == "m4a",
      let id = UUID(uuidString: String(parts[0]))
    else { return false }
    return id.uuidString.lowercased() == String(parts[0])
  }
}

// swiftlint:disable:next inclusive_language
struct MasteringPiece: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var sliceID: UUID
  var title: String
  var startFrame: Int
  var frameCount: Int
  var lrc: String
  var finished: MasteringArtifactRef?
}

// swiftlint:disable:next inclusive_language
struct MasteringPart: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var frameCount: Int
  var prepared: MasteringArtifactRef?
  var pieces: [MasteringPiece]

  var isReturned: Bool { !pieces.isEmpty && pieces.allSatisfy { $0.finished != nil } }
}

// swiftlint:disable:next inclusive_language
struct MasteringRun: Codable, Equatable, Sendable {
  var id: UUID
  var artist: String
  var inputsDigest: String
  var parts: [MasteringPart]

  var referencedArtifacts: Set<MasteringArtifactRef> {
    Set(
      parts.flatMap { part in
        [part.prepared].compactMap { $0 } + part.pieces.compactMap(\.finished)
      })
  }

  var isStructurallyValid: Bool {
    var seenParts = Set<UUID>()
    var seenPieces = Set<UUID>()
    return parts.allSatisfy {
      Self.validGeometry($0, seenParts: &seenParts, seenPieces: &seenPieces)
    }
  }

  func healed(available: [String: Int]) -> MasteringRun {
    var result = self
    var seen = Set<String>()
    var seenParts = Set<UUID>()
    var seenPieces = Set<UUID>()
    for partIndex in result.parts.indices {
      var part = result.parts[partIndex]
      let validGeometry = Self.validGeometry(
        part, seenParts: &seenParts, seenPieces: &seenPieces)
      part.prepared =
        validGeometry
        ? retained(
          part.prepared, extension: "wav", available: available,
          seen: &seen) : nil
      for pieceIndex in part.pieces.indices {
        part.pieces[pieceIndex].finished =
          validGeometry
          ? retained(
            part.pieces[pieceIndex].finished, extension: "m4a", available: available,
            seen: &seen) : nil
      }
      result.parts[partIndex] = part
    }
    return result
  }

  private static func validGeometry(
    _ part: MasteringPart, seenParts: inout Set<UUID>, seenPieces: inout Set<UUID>
  ) -> Bool {
    guard seenParts.insert(part.id).inserted, part.frameCount > 0, !part.pieces.isEmpty else {
      return false
    }
    var end = 0
    for piece in part.pieces {
      guard seenPieces.insert(piece.id).inserted,
        piece.frameCount > 0, piece.startFrame == end,
        piece.frameCount <= part.frameCount - end
      else { return false }
      end += piece.frameCount
    }
    return end == part.frameCount
  }

  private func retained(
    _ ref: MasteringArtifactRef?, extension ext: String,
    available: [String: Int], seen: inout Set<String>
  ) -> MasteringArtifactRef? {
    guard let ref, ref.isWellFormed, ref.fileName.hasSuffix(".\(ext)"),
      available[ref.fileName] == ref.byteCount, seen.insert(ref.fileName).inserted
    else { return nil }
    return ref
  }
}
