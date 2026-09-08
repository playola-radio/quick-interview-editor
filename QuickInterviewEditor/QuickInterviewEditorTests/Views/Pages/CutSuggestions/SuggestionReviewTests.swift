import CustomDump
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct SuggestionReviewTests {
  @Test func groupReviewStartsWithIssuedSpellingAndDoesNotProposeAnUneditedChange() throws {
    let editor = try fixture(values: [["song-title": "Wildflowers", "artist-name": "TOM PETTY"]])
    editor.issuedSuggestionNumbers = [
      .init(
        candidateID: Fixtures.uuid(99), key: try key(editor), number: 7,
        canonicalValues: ["song-title": "Wildflowers", "artist-name": "Tom Petty"])
    ]
    let model = SuggestionReviewModel(
      sequenceKey: try key(editor),
      currentDocument: { editor.documentState }, isLocked: { false },
      onApply: { try editor.applySuggestionReviewIntent($0) })
    expectNoDifference(model[canonical: "artist-name"], "Tom Petty")
    #expect(!model.canApplyGroupSpelling)
    expectNoDifference(model.spellingPreviewNames.count, 0)
    let before = editor.documentState
    model.applyGroupSpellingTapped()
    expectNoDifference(editor.documentState, before)
    model.canonicalValueChanged("artist-name", value: "TOM PETTY")
    #expect(model.canApplyGroupSpelling)
    expectNoDifference(model.spellingPreviewNames.first?.before, "Wildflowers 8, Tom Petty")
    expectNoDifference(model.spellingPreviewNames.first?.after, "Wildflowers 8, TOM PETTY")
    model.applyGroupSpellingTapped()
    #expect(!model.canApplyGroupSpelling)
  }

  @Test func cleanGroupSpellingFollowsUndoWhileDirtySpellingSurvivesOtherEdits() async throws {
    let editor = try fixture()
    let model = SuggestionReviewModel(
      sequenceKey: try key(editor),
      currentDocument: { editor.documentState }, isLocked: { false },
      onApply: { try editor.applySuggestionReviewIntent($0) })
    model.canonicalValueChanged("artist-name", value: "TOM PETTY")
    model.applyGroupSpellingTapped()
    await editor.undoTapped()
    expectNoDifference(model[canonical: "artist-name"], "Tom Petty")
    #expect(!model.canApplyGroupSpelling)
    expectNoDifference(model.spellingPreviewNames.count, 0)
    model.canonicalValueChanged("artist-name", value: "TOM PETTY")
    try editor.applySuggestionReviewIntent(
      .spelling(
        key: try key(editor),
        runID: try #require(editor.suggestionBatch?.snapshot.runID),
        values: ["song-title": "WILDFLOWERS", "artist-name": "Tom Petty"]))
    expectNoDifference(model[canonical: "artist-name"], "TOM PETTY")
    expectNoDifference(model[canonical: "song-title"], "WILDFLOWERS")
    #expect(model.canApplyGroupSpelling)
    model.applyGroupSpellingTapped()
    expectNoDifference(
      editor.suggestionBatch?.canonicalGroups.first?.values,
      ["song-title": "WILDFLOWERS", "artist-name": "TOM PETTY"])
  }

  @Test func groupSpellingIgnoresNonGroupingTemplateFields() throws {
    let editor = try fixture()
    editor.suggestionBatch?.snapshot.configuration.types[0].template.append(
      .init(kind: .field, value: "descriptive-title"))
    editor.documentCutSuggestions[0].naming?.extractedValues["descriptive-title"] =
      "An acoustic take"
    let model = SuggestionReviewModel(
      sequenceKey: try key(editor), currentDocument: { editor.documentState }, isLocked: { false },
      onApply: { try editor.applySuggestionReviewIntent($0) })
    model.canonicalValueChanged("artist-name", value: "TOM PETTY")
    #expect(model.canApplyGroupSpelling)
    model.applyGroupSpellingTapped()
    expectNoDifference(
      editor.suggestionBatch?.canonicalGroups.first?.values,
      ["song-title": "Wildflowers", "artist-name": "TOM PETTY"])
    expectNoDifference(
      editor.documentCutSuggestions[0].naming?.extractedValues["descriptive-title"],
      "An acoustic take")
  }

  @Test func cleanReviewFollowsUndoAndApplyMatchesVisibleFields() async throws {
    let editor = try fixture()
    let model = review(editor)
    let original = editor.documentState
    model.fieldChanged("artist-name", value: "Stevie Nicks")
    model.applyFieldsTapped()
    await editor.undoTapped()
    expectNoDifference(editor.documentState, original)
    expectNoDifference(model[field: "artist-name"], "Tom Petty")
    expectNoDifference(model.previewNames.first?.after, "Wildflowers 1, Tom Petty")
    model.applyFieldsTapped()
    expectNoDifference(editor.documentState, original)
    expectNoDifference(model[field: "artist-name"], "Tom Petty")
  }

  @Test func dirtyFieldSurvivesExternalEditWhileUntouchedFieldsFollowDocument() throws {
    let editor = try fixture()
    let model = review(editor)
    model.fieldChanged("artist-name", value: "Stevie Nicks")
    let otherReview = review(editor)
    otherReview.fieldChanged("song-title", value: "Dreams")
    otherReview.applyFieldsTapped()
    expectNoDifference(model[field: "artist-name"], "Stevie Nicks")
    expectNoDifference(model[field: "song-title"], "Dreams")
    expectNoDifference(model.previewNames.first?.after, "Dreams 1, Stevie Nicks")
    model.applyFieldsTapped()
    expectNoDifference(editor.documentCutSuggestions[0].title, "A song introduction")
  }

  @Test func repeatedFieldApplyCanReturnToOriginalAndPreservesUnrelatedCurrentEdits() throws {
    let editor = try fixture()
    let model = review(editor)
    model.fieldChanged("artist-name", value: "Stevie Nicks")
    model.applyFieldsTapped()
    expectNoDifference(
      editor.documentCutSuggestions[0].naming?.correctedValues["artist-name"], "Stevie Nicks")
    let otherReview = review(editor)
    otherReview.fieldChanged("song-title", value: "Dreams")
    otherReview.applyFieldsTapped()
    model.fieldChanged("artist-name", value: "Tom Petty")
    model.applyFieldsTapped()
    expectNoDifference(editor.documentCutSuggestions[0].title, "A song introduction")
    expectNoDifference(model[field: "song-title"], "Dreams")
    expectNoDifference(model[field: "artist-name"], "Tom Petty")
    model.fieldChanged("artist-name", value: "Stevie Nicks")
    model.applyFieldsTapped()
    expectNoDifference(
      editor.documentCutSuggestions[0].naming?.correctedValues["artist-name"], "Stevie Nicks")
  }

  @Test func failedFieldApplyRetainsDraftAndComparisonBaselineForRetry() throws {
    let editor = try fixture()
    var fail = true
    let model = SuggestionReviewModel(
      candidateID: Fixtures.uuid(1), currentDocument: { editor.documentState }, isLocked: { false },
      onApply: { intent in
        if fail { throw SuggestionReviewError.locked }
        try editor.applySuggestionReviewIntent(intent)
      })
    let before = editor.documentState
    model.fieldChanged("artist-name", value: "Stevie Nicks")
    model.applyFieldsTapped()
    expectNoDifference(editor.documentState, before)
    expectNoDifference(model[field: "artist-name"], "Stevie Nicks")
    fail = false
    model.applyFieldsTapped()
    expectNoDifference(
      editor.documentCutSuggestions[0].naming?.correctedValues["artist-name"], "Stevie Nicks")
  }

  @Test func correctionIntoNewGroupUsesCurrentFloorOnlyInAcceptancePreview() throws {
    let editor = try fixture()
    editor.suggestionStarts.types["intro"] = .init(number: 7, isExplicit: true)
    let model = review(editor)
    model.fieldChanged("song-title", value: "Dreams")
    expectNoDifference(model.previewNames.first?.after, "Dreams 7, Tom Petty")
    model.applyFieldsTapped()
    expectNoDifference(editor.documentCutSuggestions[0].naming?.reservation, nil)
    expectNoDifference(editor.documentCutSuggestions[0].title, "A song introduction")
    expectNoDifference(editor.issuedSuggestionNumbers, [])
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(1))
    expectNoDifference(editor.slices.first?.name, "Dreams 7, Tom Petty")
  }

  func fixture(
    values: [[String: String]] = [
      ["song-title": "Wildflowers", "artist-name": "Tom Petty"],
      ["song-title": "Wildflowers", "artist-name": "tom petty"],
    ]
  ) throws -> EditorModel {
    let plan = Fixtures.editPlan()
    let snapshot = SuggestionRunSnapshot(
      runID: Fixtures.uuid(90), configuration: SuggestionDefaults.configuration,
      configurationHash: "fixture", model: "fixture", discoveryPromptVersion: "v1",
      extractionPromptVersion: "v1", productSpecVersion: "v1", transcriptHash: plan.transcriptHash,
      sourceFingerprint: "review", sampleRate: plan.source.sampleRate)
    let candidates = values.enumerated().map { index, fields in
      var candidate = Fixtures.cutSuggestion(id: Fixtures.uuid(index + 1), wordIDs: [10, 11, 12])
      candidate.productType = .intro
      candidate.startSample += index
      candidate.provenance.transcriptHash = plan.transcriptHash
      candidate.provenance.sourceFingerprint = "review"
      candidate.naming = .init(
        runID: snapshot.runID, typeID: "intro", typeName: "Song Intro", typeGroup: .songIntros,
        discoveryLabel: "A song introduction", extractedValues: fields,
        missingFieldIDs: fields["artist-name"] == nil ? ["artist-name"] : [],
        correctedValues: [:], reservation: nil)
      return candidate
    }
    let numbered = try preparePendingSuggestions(
      candidates, snapshot: snapshot, starts: .init(), issued: [])
    return EditorModel(
      sourceURL: URL(fileURLWithPath: "/review.m4a"), canonicalAudioURL: Fixtures.canonicalAudioURL,
      editPlan: plan, sourceFingerprint: "review",
      initialDocument: .init(
        cutSuggestions: IdentifiedArray(uniqueElements: numbered.candidates),
        suggestionBatch: numbered.batch))
  }

  func review(_ editor: EditorModel, candidateID: UUID = Fixtures.uuid(1)) -> SuggestionReviewModel
  {
    SuggestionReviewModel(
      candidateID: candidateID, currentDocument: { editor.documentState },
      isLocked: { editor.cutSuggestions.candidateActionsDisabled },
      onApply: { try editor.applySuggestionReviewIntent($0) })
  }

  @Test func fieldDraftUsesOwningTemplateAndOnlyApplyMutates() throws {
    @Shared(.suggestionConfiguration) var saved = SuggestionDefaults.configuration
    let editor = try fixture()
    saved?.types[0].template = [.init(kind: .literal, value: "Changed global template")]
    let before = editor.documentState
    let model = review(editor)
    model.fieldChanged("artist-name", value: "Stevie Nicks")
    expectNoDifference(editor.documentState, before)
    expectNoDifference(model.previewNames.first?.after, "Wildflowers 1, Stevie Nicks")
    model.applyFieldsTapped()
    expectNoDifference(editor.documentCutSuggestions[0].title, "A song introduction")
    expectNoDifference(editor.documentCutSuggestions[1], before.cutSuggestions[1])
    expectNoDifference(
      editor.documentCutSuggestions[0].naming?.extractedValues["artist-name"], "Tom Petty")
    expectNoDifference(
      editor.documentCutSuggestions[0].naming?.correctedValues["artist-name"], "Stevie Nicks")
  }

  @Test func explicitCanonicalSpellingControlsLaterAcceptancesWithoutReservingPreviews() throws {
    let editor = try fixture()
    let model = review(editor)
    model.fieldChanged("artist-name", value: "TOM PETTY")
    model.applyFieldsTapped()
    let group = SuggestionReviewModel(
      sequenceKey: try key(editor), currentDocument: { editor.documentState },
      isLocked: { false }, onApply: { try editor.applySuggestionReviewIntent($0) })
    group.canonicalValueChanged("artist-name", value: "Tom Petty")
    expectNoDifference(
      group.spellingPreviewNames.map(\.after),
      ["Wildflowers 1, Tom Petty", "Wildflowers 1, Tom Petty"])
    group.applyGroupSpellingTapped()
    expectNoDifference(
      editor.documentCutSuggestions.map(\.title),
      ["A song introduction", "A song introduction"])
    expectNoDifference(editor.issuedSuggestionNumbers, [])
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(2))
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(1))
    expectNoDifference(
      editor.slices.map(\.name), ["Wildflowers 1, Tom Petty", "Wildflowers 2, Tom Petty"])
    group.applyFutureStartTapped()
    expectNoDifference(
      editor.suggestionStarts.groups.first?.display?.canonicalValues["artist-name"], "Tom Petty")
    group.canonicalValueChanged("artist-name", value: "Different Artist")
    #expect(!group.canApplyGroupSpelling)
  }

  @Test func missingFieldFallbackCanStillBeAccepted() throws {
    let editor = try fixture(values: [["song-title": "Wildflowers"]])
    let model = review(editor)
    #expect(model.missingFieldsMessage != nil)
    expectNoDifference(editor.documentCutSuggestions[0].title, "A song introduction")
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(1))
    expectNoDifference(editor.slices.first?.name, "A song introduction")
  }

  @Test func correctionUsesDestinationOccupancyAndKeepsOldOverride() throws {
    let editor = try fixture(values: [
      ["song-title": "Wildflowers", "artist-name": "Tom Petty"],
      ["song-title": "Dreams", "artist-name": "Stevie Nicks"],
    ])
    let oldKey = try key(editor)
    editor.suggestionStarts.groups = [.init(key: oldKey, start: .init(number: 8, isExplicit: true))]
    let model = review(editor)
    model.fieldChanged("song-title", value: "Dreams")
    model.fieldChanged("artist-name", value: "Stevie Nicks")
    model.applyFieldsTapped()
    expectNoDifference(editor.documentCutSuggestions[0].title, "A song introduction")
    expectNoDifference(editor.suggestionStarts.groups.first?.key, oldKey)
  }

  @Test func groupFloorChangesOnlyFutureAcceptanceAndIsUndoable() async throws {
    let editor = try fixture()
    editor.documentCutSuggestions[1].reject()
    let original = editor.documentState
    let model = SuggestionReviewModel(
      sequenceKey: try key(editor), currentDocument: { editor.documentState },
      isLocked: { false }, onApply: { try editor.applySuggestionReviewIntent($0) })
    model.startChanged("7")
    model.applyFutureStartTapped()
    expectNoDifference(editor.documentCutSuggestions, original.cutSuggestions)
    expectNoDifference(editor.issuedSuggestionNumbers, [])
    await editor.undoTapped()
    expectNoDifference(editor.documentState, original)
    model.applyFutureStartTapped()
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(1))
    expectNoDifference(editor.slices.first?.name, "Wildflowers 7, Tom Petty")
    expectNoDifference(editor.documentCutSuggestions[1], original.cutSuggestions[1])
  }

  @Test func invalidGroupStartsNeverMutateAndMaximumIssuesOnlyOnAcceptance() throws {
    let editor = try fixture()
    let before = editor.documentState
    let model = SuggestionReviewModel(
      sequenceKey: try key(editor), currentDocument: { editor.documentState },
      isLocked: { false }, onApply: { try editor.applySuggestionReviewIntent($0) })
    for text in ["1.2", "12abc", "+1", "0", "-2", "9999999999999999999999"] {
      model.startChanged(text)
      model.applyFutureStartTapped()
      expectNoDifference(editor.documentState, before)
      #expect(model.errorMessage != nil)
    }
    model.startChanged(String(Int.max))
    model.applyFutureStartTapped()
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(1))
    expectNoDifference(editor.slices.first?.suggestionNaming?.reservation?.number, Int.max)
    let maximumIssued = editor.documentState
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(2))
    expectNoDifference(editor.documentState, maximumIssued)
    #expect(editor.cutSuggestions.actionMessage != nil)
  }

  @Test func staleOrLockedOpenReviewCannotApply() throws {
    let editor = try fixture()
    let model = review(editor)
    model.fieldChanged("artist-name", value: "Changed")
    editor.cutSuggestions.recoveryBlocksSuggestions = true
    let before = editor.documentState
    model.applyFieldsTapped()
    expectNoDifference(editor.documentState, before)
    #expect(model.errorMessage != nil)
    editor.cutSuggestions.recoveryBlocksSuggestions = false
    editor.documentCutSuggestions[0].reject()
    let rejected = editor.documentState
    model.applyFieldsTapped()
    expectNoDifference(editor.documentState, rejected)
  }

  @Test func orphanGroupStartEditPreservesItsDisplayMetadata() throws {
    let editor = try fixture()
    let key = SuggestionSequenceKey(
      typeID: "removed", fields: [.init(fieldID: "song", value: "dreams")],
      provisionalCandidateID: nil)
    let display = SuggestionStarts.GroupDisplay(
      typeName: "Station Song", fieldNames: ["song": "Recording"],
      canonicalValues: ["song": "Dreams"])
    editor.suggestionStarts.groups = [
      .init(key: key, start: .init(number: 8, isExplicit: true), display: display)
    ]
    let model = SuggestionReviewModel(
      sequenceKey: key, currentDocument: { editor.documentState }, isLocked: { false },
      onApply: { try editor.applySuggestionReviewIntent($0) })
    model.startChanged("10")
    model.applyFutureStartTapped()
    expectNoDifference(editor.suggestionStarts.groups.first?.display, display)
    expectNoDifference(model.startLabel, "Start numbering at")
  }

  @Test func explicitSpellingLeavesAcceptedRejectedSavedAndIssuedUntouchedAndUndoesOnce()
    async throws
  {
    let editor = try fixture(
      values: Array(repeating: ["song-title": "Wildflowers", "artist-name": "Tom Petty"], count: 3))
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(2))
    editor.cutSuggestions.rejectTapped(Fixtures.uuid(3))
    let before = editor.documentState
    let key = try key(editor)
    let model = SuggestionReviewModel(
      sequenceKey: key, currentDocument: { editor.documentState }, isLocked: { false },
      onApply: { try editor.applySuggestionReviewIntent($0) })
    model.canonicalValueChanged("artist-name", value: "TOM PETTY")
    model.applyGroupSpellingTapped()
    expectNoDifference(editor.slices, before.slices)
    expectNoDifference(editor.documentState.issuedSuggestionNumbers, before.issuedSuggestionNumbers)
    expectNoDifference(
      Array(editor.documentCutSuggestions.dropFirst()), Array(before.cutSuggestions.dropFirst()))
    expectNoDifference(editor.documentCutSuggestions[0].title, "A song introduction")
    await editor.undoTapped()
    expectNoDifference(editor.documentState, before)
  }

  @Test func correctionRetainsIssuedOldIdentityAndLaterOldGroupUsesSavedStart() throws {
    let editor = try fixture()
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(2))
    let issued = editor.documentState.issuedSuggestionNumbers
    let oldKey = try key(editor)
    editor.suggestionStarts.groups = [.init(key: oldKey, start: .init(number: 9, isExplicit: true))]
    let model = review(editor)
    model.fieldChanged("song-title", value: "Dreams")
    model.applyFieldsTapped()
    expectNoDifference(editor.documentState.issuedSuggestionNumbers, issued)
    expectNoDifference(editor.suggestionStarts.groups.first?.key, oldKey)
    var candidate = editor.documentCutSuggestions[0]
    candidate.id = Fixtures.uuid(10)
    candidate.naming?.correctedValues = [:]
    candidate.naming?.reservation = nil
    let batch = try #require(editor.suggestionBatch)
    let next = try numberSuggestions(
      [candidate], snapshot: batch.snapshot, starts: editor.suggestionStarts, issued: issued,
      retained: [])
    expectNoDifference(next.candidates[0].naming?.reservation?.number, 9)
  }

  @Test func acceptancePreviewReusesOwnerIdentityAfterUndo() async throws {
    let editor = try fixture()
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(1))
    let original = try #require(editor.slices.first)
    await editor.undoTapped()
    editor.suggestionStarts.types["intro"] = .init(number: 20, isExplicit: true)
    let issued = editor.issuedSuggestionNumbers
    expectNoDifference(review(editor).previewNames.first?.after, original.name)
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(1))
    expectNoDifference(editor.slices.first, original)
    expectNoDifference(editor.issuedSuggestionNumbers, issued)
  }

  private func key(_ editor: EditorModel) throws -> SuggestionSequenceKey {
    let batch = try #require(editor.suggestionBatch)
    return try #require(reviewSequenceKey(editor.documentCutSuggestions[0], batch: batch))
  }

}
