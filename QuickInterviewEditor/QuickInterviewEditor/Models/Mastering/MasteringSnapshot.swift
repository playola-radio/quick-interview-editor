import Foundation

// swiftlint:disable:next inclusive_language
struct MasteringPieceInput: Equatable, Sendable {
  var sliceID: Slice.ID
  var title: String
  var render: AudioEditRenderPlan
  var editedDurationSamples: Int
  var sourceRange: Range<Int>
  var localRemovals: [TimelineRemoval]
  var wordStarts: [RenderMarker]
  var typeProvenance: String
}

// swiftlint:disable:next inclusive_language
struct MasteringSnapshot: Equatable, Sendable {
  var artist: String
  var canonicalAudioURL: URL
  var canonicalFingerprint: String
  var sourceSampleRate: Int
  var sourceDurationSamples: Int
  var pieces: [MasteringPieceInput]
  var inputsDigest: String
}

// swiftlint:disable:next inclusive_language
enum MasteringBlocker: Error, Equatable, Sendable {
  case notLoaded, unsaved, missingArtist, pendingEdit, invalidTimeline, noIntros
  case blankTitles([Slice.ID])
}

// swiftlint:disable:next inclusive_language
enum MasteringSnapshotBuilder {
  // swiftlint:disable:next function_body_length
  static func build(
    document: EditorDocumentState, plan: EditPlan, source: ProjectSource,
    canonicalAudioURL: URL
  ) -> Result<MasteringSnapshot, MasteringBlocker> {
    guard let artist = document.interviewArtist?.trimmingCharacters(in: .whitespacesAndNewlines),
      !artist.isEmpty
    else { return .failure(.missingArtist) }
    let eligibility = MasteringEligibilityRule.evaluate(document)
    guard !eligibility.intros.isEmpty else { return .failure(.noIntros) }
    guard eligibility.blankTitledIntroIDs.isEmpty else {
      return .failure(.blankTitles(eligibility.blankTitledIntroIDs))
    }
    guard source.sampleRate > 0, source.durationSamples >= 0,
      plan.source.sampleRate == source.sampleRate,
      plan.source.durationSamples == source.durationSamples
    else { return .failure(.invalidTimeline) }
    guard
      let rawMarkers = SliceRenderPlanBuilder.sourceMarkers(
        plan.words, sampleRate: source.sampleRate)
    else { return .failure(.invalidTimeline) }
    var pieces: [MasteringPieceInput] = []
    var typeIDs: [Slice.ID: String] = [:]
    for slice in eligibility.intros {
      guard slice.startSample >= 0, slice.endSample <= source.durationSamples else {
        return .failure(.invalidTimeline)
      }
      let range = slice.startSample..<slice.endSample
      let built = SliceRenderPlanBuilder.plan(
        sliceRange: range, removals: Array(document.timelineRemovals))
      guard built.localTimeline.isValid else { return .failure(.invalidTimeline) }
      guard built.localTimeline.removals.allSatisfy({ $0.crossfade.curveAmount.isFinite }) else {
        return .failure(.invalidTimeline)
      }
      let typeID = MasteringEligibilityRule.typeID(of: slice, in: document)!
      typeIDs[slice.id] = typeID
      let provenance =
        slice.suggestionTypeID != nil
        ? "explicit"
        : (slice.suggestionNaming != nil ? "naming" : "legacy")
      pieces.append(
        MasteringPieceInput(
          sliceID: slice.id, title: slice.name, render: built.plan,
          editedDurationSamples: built.editedDurationSamples, sourceRange: range,
          localRemovals: built.localTimeline.removals,
          wordStarts: SliceRenderPlanBuilder.markers(
            rawMarkers, sliceRange: range, localTimeline: built.localTimeline),
          typeProvenance: provenance))
    }
    let digest = MasteringInputsDigest.make(
      source: source, artist: artist, pieces: pieces, typeIDs: typeIDs)
    return .success(
      MasteringSnapshot(
        artist: artist, canonicalAudioURL: canonicalAudioURL,
        canonicalFingerprint: source.canonicalFingerprint,
        sourceSampleRate: source.sampleRate, sourceDurationSamples: source.durationSamples,
        pieces: pieces, inputsDigest: digest))
  }
}
