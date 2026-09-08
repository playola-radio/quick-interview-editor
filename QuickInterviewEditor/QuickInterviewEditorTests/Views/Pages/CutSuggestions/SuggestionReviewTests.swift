import CustomDump
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct SuggestionReviewTests {
  @Test func cleanReviewFollowsUndoAndApplyMatchesVisibleFields() async throws {
    let editor = try fixture()
    let model = review(editor)
    let original = editor.documentState
    model.fieldChanged("artist-name", value: "Stevie Nicks")
    model.applyFieldsTapped()
    await editor.undoTapped()
    expectNoDifference(editor.documentState, original)
    expectNoDifference(model[field: "artist-name"], "Tom Petty")
    expectNoDifference(model.previewNames.first?.after, original.cutSuggestions[0].title)
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
    expectNoDifference(editor.documentCutSuggestions[0].title, "Dreams 1, Stevie Nicks")
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
    expectNoDifference(editor.documentCutSuggestions[0].title, "Dreams 1, Tom Petty")
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

  @Test func correctionIntoNewGroupDoesNotClaimCapturedTypeStartWasApplied() throws {
    let editor = try fixture()
    editor.suggestionBatch?.actualStarts.types["intro"] = .init(number: 7, isExplicit: true)
    let model = review(editor)
    model.fieldChanged("song-title", value: "Dreams")
    model.applyFieldsTapped()
    expectNoDifference(editor.documentCutSuggestions[0].naming?.reservation?.number, 1)
    let key = try #require(editor.documentCutSuggestions[0].naming?.reservation?.key)
    let group = SuggestionReviewModel(
      sequenceKey: key, currentDocument: { editor.documentState }, isLocked: { false },
      onApply: { try editor.applySuggestionReviewIntent($0) })
    expectNoDifference(
      group.thisSearchStart, "This group has no recorded starting number in this search.")
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
    let numbered = try numberSuggestions(
      candidates, snapshot: snapshot, starts: .init(), issued: [], retained: [])
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
    expectNoDifference(editor.documentCutSuggestions[0].title, "Wildflowers 1, Stevie Nicks")
    expectNoDifference(editor.documentCutSuggestions[1], before.cutSuggestions[1])
    expectNoDifference(
      editor.documentCutSuggestions[0].naming?.extractedValues["artist-name"], "Tom Petty")
    expectNoDifference(
      editor.documentCutSuggestions[0].naming?.correctedValues["artist-name"], "Stevie Nicks")
  }

  @Test func caseCorrectionPreservesNumberAndCanonicalUntilExplicitGroupEdit() throws {
    let editor = try fixture()
    let before = editor.documentState
    let model = review(editor)
    model.fieldChanged("artist-name", value: "TOM PETTY")
    model.applyFieldsTapped()
    expectNoDifference(editor.documentCutSuggestions[0].title, before.cutSuggestions[0].title)
    expectNoDifference(editor.documentCutSuggestions[0].naming?.reservation?.number, 1)
    let key = try #require(editor.documentCutSuggestions[0].naming?.reservation?.key)
    let group = SuggestionReviewModel(
      sequenceKey: key, currentDocument: { editor.documentState },
      isLocked: { false }, onApply: { try editor.applySuggestionReviewIntent($0) })
    group.canonicalValueChanged("artist-name", value: "TOM PETTY")
    expectNoDifference(editor.documentCutSuggestions[1].title, "Wildflowers 2, Tom Petty")
    group.applyGroupSpellingTapped()
    expectNoDifference(
      editor.documentCutSuggestions.map(\.title),
      ["Wildflowers 1, TOM PETTY", "Wildflowers 2, TOM PETTY"])
    group.applyFutureStartTapped()
    expectNoDifference(
      editor.suggestionStarts.groups.first?.display?.canonicalValues["artist-name"], "TOM PETTY")
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
    let oldKey = try #require(editor.documentCutSuggestions[0].naming?.reservation?.key)
    editor.suggestionStarts.groups = [.init(key: oldKey, start: .init(number: 8, isExplicit: true))]
    let model = review(editor)
    model.fieldChanged("song-title", value: "Dreams")
    model.fieldChanged("artist-name", value: "Stevie Nicks")
    model.applyFieldsTapped()
    expectNoDifference(editor.documentCutSuggestions[0].title, "Dreams 2, Stevie Nicks")
    expectNoDifference(editor.suggestionStarts.groups.first?.key, oldKey)
  }

  @Test func renumberSkipsRejectedAndIssuedAndIsSeparateUndoFromFutureStart() async throws {
    let editor = try fixture()
    let key = try #require(editor.documentCutSuggestions[0].naming?.reservation?.key)
    editor.documentCutSuggestions[1].reject()
    let original = editor.documentState
    let model = SuggestionReviewModel(
      sequenceKey: key, currentDocument: { editor.documentState },
      isLocked: { false }, onApply: { try editor.applySuggestionReviewIntent($0) })
    model.startChanged("2")
    model.applyFutureStartTapped()
    expectNoDifference(editor.documentCutSuggestions, original.cutSuggestions)
    model.renumberTapped()
    expectNoDifference(editor.documentCutSuggestions[0].naming?.reservation?.number, 3)
    expectNoDifference(editor.documentCutSuggestions[1], original.cutSuggestions[1])
    await editor.undoTapped()
    expectNoDifference(editor.documentCutSuggestions, original.cutSuggestions)
    expectNoDifference(editor.suggestionStarts.groups.first?.start.number, 2)
    await editor.undoTapped()
    expectNoDifference(editor.suggestionStarts, original.suggestionStarts)
  }

  @Test func invalidStartsAndExhaustionNeverPartiallyApply() throws {
    let editor = try fixture()
    let key = try #require(editor.documentCutSuggestions[0].naming?.reservation?.key)
    let before = editor.documentState
    let model = SuggestionReviewModel(
      sequenceKey: key, currentDocument: { editor.documentState },
      isLocked: { false }, onApply: { try editor.applySuggestionReviewIntent($0) })
    for text in ["1.2", "12abc", "+1", "0", "-2", "9999999999999999999999", String(Int.max)] {
      model.startChanged(text)
      model.renumberTapped()
      expectNoDifference(editor.documentState, before)
      #expect(model.errorMessage != nil)
    }
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
    expectNoDifference(
      model.thisSearchStart, "This group has no suggestions in the current search.")
  }

  @Test func explicitSpellingLeavesAcceptedRejectedSavedAndIssuedUntouchedAndUndoesOnce()
    async throws
  {
    let editor = try fixture(
      values: Array(repeating: ["song-title": "Wildflowers", "artist-name": "Tom Petty"], count: 3))
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(2))
    editor.cutSuggestions.rejectTapped(Fixtures.uuid(3))
    let before = editor.documentState
    let key = try #require(before.cutSuggestions[0].naming?.reservation?.key)
    let model = SuggestionReviewModel(
      sequenceKey: key, currentDocument: { editor.documentState }, isLocked: { false },
      onApply: { try editor.applySuggestionReviewIntent($0) })
    model.canonicalValueChanged("artist-name", value: "TOM PETTY")
    model.applyGroupSpellingTapped()
    expectNoDifference(editor.slices, before.slices)
    expectNoDifference(editor.documentState.issuedSuggestionNumbers, before.issuedSuggestionNumbers)
    expectNoDifference(
      Array(editor.documentCutSuggestions.dropFirst()), Array(before.cutSuggestions.dropFirst()))
    expectNoDifference(editor.documentCutSuggestions[0].title, "Wildflowers 1, TOM PETTY")
    await editor.undoTapped()
    expectNoDifference(editor.documentState, before)
  }

  @Test func correctionRetainsIssuedOldIdentityAndLaterOldGroupUsesSavedStart() throws {
    let editor = try fixture()
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(2))
    let issued = editor.documentState.issuedSuggestionNumbers
    let oldKey = try #require(editor.documentCutSuggestions[0].naming?.reservation?.key)
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

  @Test func pendingRenumberSkipsIssuedIdentityEvenAfterAcceptanceUndo() async throws {
    let editor = try fixture()
    editor.cutSuggestions.acceptTapped(Fixtures.uuid(1))
    await editor.undoTapped()
    let issued = editor.documentState.issuedSuggestionNumbers
    let key = try #require(editor.documentCutSuggestions[0].naming?.reservation?.key)
    let model = SuggestionReviewModel(
      sequenceKey: key, currentDocument: { editor.documentState }, isLocked: { false },
      onApply: { try editor.applySuggestionReviewIntent($0) })
    model.startChanged("1")
    model.renumberTapped()
    expectNoDifference(
      editor.documentCutSuggestions.compactMap { $0.naming?.reservation?.number }, [2, 3])
    expectNoDifference(editor.documentState.issuedSuggestionNumbers, issued)
  }
}
