import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

struct EditorDocumentStateTests {
  @Test func decodesLegacyShapeWithNewFieldDefaults() throws {
    let json = Data(#"{"slices":[],"timelineRemovals":[]}"#.utf8)
    let state = try JSONDecoder().decode(EditorDocumentState.self, from: json)
    expectNoDifference(state, EditorDocumentState())
    expectNoDifference(state.cutSuggestions, [])
    expectNoDifference(state.speakerCountOverride, nil)
    expectNoDifference(state.speakerDisplayNames, [:])
  }

  @Test func legacyAcceptedAssociationUsesOnlyKnownTypeAndCandidateID() throws {
    var known = Fixtures.cutSuggestion(id: Fixtures.uuid(1))
    known.accept()
    var unknown = Fixtures.cutSuggestion(id: Fixtures.uuid(2))
    unknown.accept()
    unknown.productType = ProductType(rawValue: "deleted-custom")!
    let state = EditorDocumentState(
      slices: [
        Fixtures.slice(id: known.id), Fixtures.slice(id: unknown.id),
        Fixtures.slice(id: Fixtures.uuid(3)),
      ],
      cutSuggestions: [known, unknown])
    let decoded = try JSONDecoder().decode(
      EditorDocumentState.self, from: JSONEncoder().encode(state))
    expectNoDifference(decoded.slices[id: known.id]?.suggestionTypeID, known.productType.rawValue)
    expectNoDifference(decoded.slices[id: unknown.id]?.suggestionTypeID, nil)
    expectNoDifference(decoded.slices[id: Fixtures.uuid(3)]?.suggestionTypeID, nil)
    expectNoDifference(decoded.slices[id: known.id]?.suggestionNaming, nil)
    expectNoDifference(decoded.issuedSuggestionNumbers, [])
  }

  @Test func rekeyingClearsBatchAndUnfinishedWorkButKeepsPermanentAndFutureState() throws {
    let plan = Fixtures.editPlan()
    let snapshot = SuggestionRunSnapshot(
      runID: Fixtures.uuid(1), configuration: SuggestionDefaults.configuration,
      configurationHash: "fixture",
      model: "fixture", discoveryPromptVersion: "configured-v1",
      extractionPromptVersion: "fields-v1",
      productSpecVersion: "configured-v1", transcriptHash: plan.transcriptHash,
      sourceFingerprint: "fixture", sampleRate: plan.source.sampleRate)
    let batch = SuggestionBatch(
      snapshot: snapshot, actualStarts: SuggestionStarts(), canonicalGroups: [])
    let checkpoint = SuggestionRunCheckpoint(
      pythonRevision: 4, controlRevision: 3, originalBatchFingerprint: "old", snapshot: snapshot,
      phase: .needsRetry, candidates: [], completedRequestKeys: ["done"],
      failedRequestKeys: ["failed"],
      proposedStarts: SuggestionStarts(), failureMessage: "Retry field extraction")
    let issued = SequenceReservation(
      candidateID: Fixtures.uuid(2),
      key: .init(typeID: "historical", fields: [], provisionalCandidateID: nil), number: 4,
      canonicalValues: [:])
    let state = EditorDocumentState(
      suggestionStarts: SuggestionStarts(types: ["historical": .init(number: 8, isExplicit: true)]),
      suggestionBatch: batch, issuedSuggestionNumbers: [issued],
      unfinishedSuggestionRun: checkpoint,
      lastAppliedSuggestionRunID: Fixtures.uuid(3), suggestionRecoveryOwnerID: Fixtures.uuid(4))
    var expected = state
    expected.suggestionBatch = nil
    expected.unfinishedSuggestionRun = nil
    expectNoDifference(state.rekeyed(to: plan), expected)
  }

  @Test func roundTripsAllFields() throws {
    let state = Fixtures.editorDocumentState()
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(EditorDocumentState.self, from: data)
    expectNoDifference(decoded, state)
  }

  @Test func rekeyingToAReplacementPlanRederivesClipWordsAndDropsSuggestions() throws {
    let plan = Fixtures.editPlan()
    let replacement: EditPlan = {
      var replacement = plan
      replacement.words = plan.words.map { word in
        var word = word
        word.text = word.text.uppercased()
        return word
      }
      return replacement
    }()
    let range = try #require(plan.words[0].startSample)..<(try #require(plan.words[1].endSample))
    let stale = Slice(
      id: UUID(), name: "Slice 1", startSample: range.lowerBound, endSample: range.upperBound,
      wordIDs: [99], snippet: "stale")
    var state = Fixtures.editorDocumentState()
    state.slices = [stale]
    state.cutSuggestions = [Fixtures.cutSuggestion(id: UUID())]

    let rekeyed = state.rekeyed(to: replacement)

    let expectedIDs = wordIDs(anyOverlap: range, words: replacement.words)
    expectNoDifference(rekeyed.slices[0].wordIDs, expectedIDs)
    expectNoDifference(
      rekeyed.slices[0].snippet,
      displaySliceSnippet(sliceSnippet(for: expectedIDs, words: replacement.words)))
    expectNoDifference(rekeyed.slices[0].startSample..<rekeyed.slices[0].endSample, range)
    expectNoDifference(rekeyed.cutSuggestions, [])
    expectNoDifference(rekeyed.timelineRemovals, state.timelineRemovals)
    expectNoDifference(rekeyed.speakerCountOverride, state.speakerCountOverride)
    expectNoDifference(rekeyed.speakerDisplayNames, state.speakerDisplayNames)
  }
}
