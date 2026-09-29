import Foundation

// swiftlint:disable:next inclusive_language
enum MasteringExclusionReason: Equatable, Sendable { case notIntro, fullyRemoved }

// swiftlint:disable:next inclusive_language
struct MasteringExclusion: Equatable, Sendable {
  var sliceID: Slice.ID
  var name: String
  var reason: MasteringExclusionReason
}

// swiftlint:disable:next inclusive_language
struct MasteringEligibility: Equatable, Sendable {
  var intros: [Slice]
  var blankTitledIntroIDs: [Slice.ID]
  var excluded: [MasteringExclusion]
}

// swiftlint:disable:next inclusive_language
enum MasteringEligibilityRule {
  static func typeID(of slice: Slice, in document: EditorDocumentState) -> String? {
    if let explicit = slice.suggestionTypeID { return explicit }
    if let naming = slice.suggestionNaming { return naming.typeID }
    guard let suggestion = document.cutSuggestions[id: slice.id],
      suggestion.status == .accepted
    else { return nil }
    return suggestion.naming?.typeID ?? suggestion.productType.rawValue
  }

  static func evaluate(_ document: EditorDocumentState) -> MasteringEligibility {
    var result = MasteringEligibility(intros: [], blankTitledIntroIDs: [], excluded: [])
    for slice in document.slices {
      guard typeID(of: slice, in: document) == ProductType.intro.rawValue else {
        result.excluded.append(
          MasteringExclusion(
            sliceID: slice.id, name: slice.name, reason: .notIntro))
        continue
      }
      guard slice.startSample < slice.endSample,
        SliceRenderPlanBuilder.hasAudio(
          sliceRange: slice.startSample..<slice.endSample,
          removals: Array(document.timelineRemovals))
      else {
        result.excluded.append(
          MasteringExclusion(
            sliceID: slice.id, name: slice.name, reason: .fullyRemoved))
        continue
      }
      result.intros.append(slice)
      if slice.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        result.blankTitledIntroIDs.append(slice.id)
      }
    }
    return result
  }
}
