import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct CutSuggestionAcceptTests {

  // MARK: - Helpers

  /// A word span for the hand-built plans below. Positional init keeps the call sites terse.
  private struct WordSpec {
    var id: Int
    var text: String
    var startSample: Int?
    var endSample: Int?
    init(_ id: Int, _ text: String, _ startSample: Int?, _ endSample: Int?) {
      self.id = id
      self.text = text
      self.startSample = startSample
      self.endSample = endSample
    }
  }

  /// A minimal, hand-built plan for edge cases the bundled fixture can't express
  /// (words at sample 0, missing sample bounds, overlapping spans). Sample bounds and
  /// `id` are the only things the accept path reads from a word; `start`/`end` seconds
  /// are irrelevant here.
  private func plan(
    words: [WordSpec],
    durationSamples: Int,
    silences: [(Int, Int)] = []
  ) -> EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: EditPlan.Source(
        path: "test.aiff", sampleRate: 44100, channels: 1, durationSamples: durationSamples),
      words: words.map {
        EditPlan.Word(
          id: $0.id, text: $0.text, start: 0, end: nil,
          startSample: $0.startSample, endSample: $0.endSample)
      },
      silences: silences.map { EditPlan.Silence(startSample: $0.0, endSample: $0.1) },
      segments: [])
  }

  private func suggestion(
    id: UUID = Fixtures.uuid(1),
    title: String = "A story",
    productType: ProductType = .spotlight,
    wordIDs: [Word.ID],
    status: CutSuggestion.Status = .pending,
    sourceFingerprint: String = "fp"
  ) -> CutSuggestion {
    var made = Fixtures.cutSuggestion(
      id: id, productType: productType, title: title, wordIDs: wordIDs, status: status)
    made.provenance.sourceFingerprint = sourceFingerprint
    // Deliberately-wrong sample fields prove the accept path ignores them and derives
    // bounds from the words instead.
    made.startSample = 999_999_999
    made.endSample = 999_999_999
    return made
  }

  // MARK: - Conversion correctness

  @Test func acceptDerivesSliceFromWordsMatchingTheSharedBuilder() {
    let plan = Fixtures.editPlan()
    let wordIDs: [Word.ID] = [10, 11, 12, 13, 14, 15, 16]
    let sug = suggestion(
      id: Fixtures.uuid(1), title: "The night the tour bus broke down",
      wordIDs: wordIDs, sourceFingerprint: "fp")
    let state = ProjectState(cutSuggestions: [sug])

    let result = acceptCutSuggestion(sug.id, in: state, plan: plan, sourceFingerprint: "fp")

    let words = wordIDs.map { id in plan.words.first { $0.id == id }! }
    let start = words.compactMap(\.startSample).min()!
    let end = words.compactMap(\.endSample).max()!
    let expected = buildSlice(
      id: sug.id, name: "The night the tour bus broke down", range: start..<end, plan: plan)

    guard case .accepted(let slice, _) = result else {
      Issue.record("expected .accepted, got \(result)")
      return
    }
    // Snippet + warnings + wordIDs are exactly what the editor's builder produces for
    // the same range — one canonical construction, no divergent copy.
    expectNoDifference(slice, expected)
  }

  @Test func acceptDerivesSamplesFromWordsNotStaleSuggestionFields() {
    let plan = Fixtures.editPlan()
    let wordIDs: [Word.ID] = [10, 11, 12, 13, 14, 15, 16]
    let sug = suggestion(id: Fixtures.uuid(1), wordIDs: wordIDs)
    let state = ProjectState(cutSuggestions: [sug])

    let result = acceptCutSuggestion(sug.id, in: state, plan: plan, sourceFingerprint: "fp")

    let words = wordIDs.map { id in plan.words.first { $0.id == id }! }
    guard case .accepted(let slice, _) = result else {
      Issue.record("expected .accepted, got \(result)")
      return
    }
    expectNoDifference(slice.startSample, words.compactMap(\.startSample).min()!)
    expectNoDifference(slice.endSample, words.compactMap(\.endSample).max()!)
    #expect(slice.startSample != sug.startSample)
    #expect(slice.endSample != sug.endSample)
    expectNoDifference(slice.wordIDs, wordIDs)
  }

  @Test func acceptUsesSuggestionIDAsSliceID() {
    let plan = Fixtures.editPlan()
    let sug = suggestion(id: Fixtures.uuid(7), wordIDs: [1, 2, 3, 4])
    let state = ProjectState(cutSuggestions: [sug])

    guard
      case .accepted(let slice, _) = acceptCutSuggestion(
        sug.id, in: state, plan: plan, sourceFingerprint: "fp")
    else {
      Issue.record("expected .accepted")
      return
    }
    expectNoDifference(slice.id, sug.id)
  }

  @Test func acceptNamesSliceFromSuggestionTitle() {
    let plan = Fixtures.editPlan()
    let sug = suggestion(title: "Intro to Wildwood", wordIDs: [1, 2, 3, 4])
    let state = ProjectState(cutSuggestions: [sug])

    guard
      case .accepted(let slice, _) = acceptCutSuggestion(
        sug.id, in: state, plan: plan, sourceFingerprint: "fp")
    else {
      Issue.record("expected .accepted")
      return
    }
    expectNoDifference(slice.name, "Intro to Wildwood")
  }

  @Test func acceptFallsBackToProductLabelWhenTitleBlank() {
    let plan = Fixtures.editPlan()
    let sug = suggestion(title: "   ", productType: .spotlight, wordIDs: [1, 2, 3, 4])
    let state = ProjectState(cutSuggestions: [sug])

    guard
      case .accepted(let slice, _) = acceptCutSuggestion(
        sug.id, in: state, plan: plan, sourceFingerprint: "fp")
    else {
      Issue.record("expected .accepted")
      return
    }
    expectNoDifference(slice.name, ProductType.spotlight.displayLabel)
  }

  // MARK: - Lifecycle coupling (transactional)

  @Test func acceptFlipsOnlyThatSuggestionAndReturnsUpdatedState() {
    let plan = Fixtures.editPlan()
    let target = suggestion(id: Fixtures.uuid(1), wordIDs: [10, 11, 12, 13, 14, 15, 16])
    let other = suggestion(id: Fixtures.uuid(2), wordIDs: [1, 2, 3, 4])
    let state = ProjectState(cutSuggestions: [target, other])

    guard
      case .accepted(_, let newState) = acceptCutSuggestion(
        target.id, in: state, plan: plan, sourceFingerprint: "fp")
    else {
      Issue.record("expected .accepted")
      return
    }
    expectNoDifference(newState.cutSuggestions[id: target.id]?.status, .accepted)
    expectNoDifference(newState.cutSuggestions[id: other.id]?.status, .pending)
    // Pure: the passed-in state is untouched.
    expectNoDifference(state.cutSuggestions[id: target.id]?.status, .pending)
  }

  @Test func acceptOnRejectedSuggestionReopensIt() {
    let plan = Fixtures.editPlan()
    let sug = suggestion(wordIDs: [1, 2, 3, 4], status: .rejected)
    let state = ProjectState(cutSuggestions: [sug])

    guard
      case .accepted(_, let newState) = acceptCutSuggestion(
        sug.id, in: state, plan: plan, sourceFingerprint: "fp")
    else {
      Issue.record("expected .accepted")
      return
    }
    expectNoDifference(newState.cutSuggestions[id: sug.id]?.status, .accepted)
  }

  @Test func acceptOnAlreadyAcceptedIsIdempotent() {
    let plan = Fixtures.editPlan()
    let sug = suggestion(wordIDs: [1, 2, 3, 4], status: .accepted)
    let state = ProjectState(cutSuggestions: [sug])

    let result = acceptCutSuggestion(sug.id, in: state, plan: plan, sourceFingerprint: "fp")
    guard case .accepted(let slice, let newState) = result else {
      Issue.record("expected .accepted")
      return
    }
    expectNoDifference(newState.cutSuggestions[id: sug.id]?.status, .accepted)
    expectNoDifference(slice.id, sug.id)
  }

  // MARK: - Stale (regenerate) rejection

  @Test func staleWhenSourceFingerprintChanged() {
    let plan = Fixtures.editPlan()
    let sug = suggestion(wordIDs: [1, 2, 3, 4], sourceFingerprint: "old-fingerprint")
    let state = ProjectState(cutSuggestions: [sug])

    let result = acceptCutSuggestion(
      sug.id, in: state, plan: plan, sourceFingerprint: "new-fingerprint")
    expectNoDifference(result, .stale(.sourceFingerprintChanged))
  }

  @Test func staleWhenWordsMissingAfterReRun() {
    // An engine re-run dropped words 15 and 16 from the transcript.
    let plan = Fixtures.editPlan()
    let presentIDs = Set(plan.words.map(\.id))
    #expect(!presentIDs.contains(9999))
    let sug = suggestion(wordIDs: [13, 14, 9999], sourceFingerprint: "fp")
    let state = ProjectState(cutSuggestions: [sug])

    let result = acceptCutSuggestion(sug.id, in: state, plan: plan, sourceFingerprint: "fp")
    expectNoDifference(result, .stale(.missingWords([9999])))
  }

  // MARK: - Invalid rejection (never a bad slice or crash)

  @Test func invalidWhenSuggestionUnknown() {
    let plan = Fixtures.editPlan()
    let state = ProjectState(cutSuggestions: [suggestion(id: Fixtures.uuid(1), wordIDs: [1, 2])])
    let result = acceptCutSuggestion(
      Fixtures.uuid(99), in: state, plan: plan, sourceFingerprint: "fp")
    expectNoDifference(result, .invalid(.unknownSuggestion))
  }

  @Test func invalidWhenNoWords() {
    let plan = Fixtures.editPlan()
    let sug = suggestion(wordIDs: [])
    let state = ProjectState(cutSuggestions: [sug])
    let result = acceptCutSuggestion(sug.id, in: state, plan: plan, sourceFingerprint: "fp")
    expectNoDifference(result, .invalid(.noWords))
  }

  @Test func invalidWhenWordsNotContiguous() {
    // Words 1 and 3 exist with word 2 between them — a slice can't skip the middle.
    let plan = Fixtures.editPlan()
    let sug = suggestion(wordIDs: [1, 3])
    let state = ProjectState(cutSuggestions: [sug])
    let result = acceptCutSuggestion(sug.id, in: state, plan: plan, sourceFingerprint: "fp")
    expectNoDifference(result, .invalid(.wordsNotContiguous))
  }

  @Test func invalidWhenDuplicateWords() {
    let plan = Fixtures.editPlan()
    let sug = suggestion(wordIDs: [1, 1, 2])
    let state = ProjectState(cutSuggestions: [sug])
    let result = acceptCutSuggestion(sug.id, in: state, plan: plan, sourceFingerprint: "fp")
    expectNoDifference(result, .invalid(.duplicateWords([1])))
  }

  @Test func invalidWhenPlanHasDuplicateWordID() {
    // A corrupt/externally-decoded plan repeats word ID 1 at two positions with different
    // audio — which occurrence the cut means is ambiguous, so refuse rather than guess.
    let editPlan = plan(
      words: [
        WordSpec(1, "a", 0, 100),
        WordSpec(2, "b", 100, 200),
        WordSpec(1, "a-again", 900, 1000),
      ],
      durationSamples: 2000)
    let sug = suggestion(wordIDs: [1, 2])
    let state = ProjectState(cutSuggestions: [sug])
    let result = acceptCutSuggestion(sug.id, in: state, plan: editPlan, sourceFingerprint: "fp")
    expectNoDifference(result, .invalid(.ambiguousPlanWords([1])))
  }

  @Test func invalidWhenWordMissingSampleBounds() {
    // Word 2 exists but has no sample bounds, so a real range can't be derived.
    let editPlan = plan(
      words: [
        WordSpec(1, "a", 0, 100),
        WordSpec(2, "b", nil, nil),
        WordSpec(3, "c", 200, 300),
      ],
      durationSamples: 300)
    let sug = suggestion(wordIDs: [1, 2, 3])
    let state = ProjectState(cutSuggestions: [sug])
    let result = acceptCutSuggestion(sug.id, in: state, plan: editPlan, sourceFingerprint: "fp")
    expectNoDifference(result, .invalid(.wordsMissingSampleBounds([2])))
  }

  @Test func invalidWhenWordHasNonPositiveSpan() {
    let editPlan = plan(
      words: [
        WordSpec(1, "a", 0, 100),
        WordSpec(2, "b", 150, 150),  // zero-length span
      ],
      durationSamples: 300)
    let sug = suggestion(wordIDs: [1, 2])
    let state = ProjectState(cutSuggestions: [sug])
    let result = acceptCutSuggestion(sug.id, in: state, plan: editPlan, sourceFingerprint: "fp")
    expectNoDifference(result, .invalid(.wordsMissingSampleBounds([2])))
  }

  @Test func invalidWhenWordsOutOfAudioOrder() {
    // Words are contiguous in transcript index but their audio runs backwards, so a
    // tight range can't be derived — min/max would span unrelated audio into one slice.
    let editPlan = plan(
      words: [
        WordSpec(1, "a", 1000, 1100),
        WordSpec(2, "b", 100, 200),
      ],
      durationSamples: 2000)
    let sug = suggestion(wordIDs: [1, 2])
    let state = ProjectState(cutSuggestions: [sug])
    let result = acceptCutSuggestion(sug.id, in: state, plan: editPlan, sourceFingerprint: "fp")
    expectNoDifference(result, .invalid(.wordsOutOfOrder))
  }

  @Test func invalidWhenSamplesExceedFileBounds() {
    // A word reaches past the file duration — the derived cut would be out of range.
    let editPlan = plan(
      words: [
        WordSpec(1, "a", 0, 100),
        WordSpec(2, "b", 100, 600),
      ],
      durationSamples: 500)
    let sug = suggestion(wordIDs: [1, 2])
    let state = ProjectState(cutSuggestions: [sug])
    let result = acceptCutSuggestion(sug.id, in: state, plan: editPlan, sourceFingerprint: "fp")
    expectNoDifference(result, .invalid(.samplesOutOfBounds))
  }

  @Test func invalidWhenMidpointRecomputeAddsAWord() {
    // Word 3 overlaps the [word1, word2] range: its midpoint (195) lands inside
    // [0, 200), so the shared builder would pull it in — a silently wider cut. The
    // accept path must refuse rather than accept a slice that differs from the
    // suggestion's words.
    let editPlan = plan(
      words: [
        WordSpec(1, "a", 0, 100),
        WordSpec(2, "b", 100, 200),
        WordSpec(3, "c", 150, 240),  // midpoint 195 ∈ [0, 200)
      ],
      durationSamples: 500)
    let sug = suggestion(wordIDs: [1, 2])
    let state = ProjectState(cutSuggestions: [sug])
    let result = acceptCutSuggestion(sug.id, in: state, plan: editPlan, sourceFingerprint: "fp")
    expectNoDifference(result, .invalid(.wordMembershipMismatch))
  }

  // MARK: - Edge cases

  @Test func oneWordSpanConverts() {
    let plan = Fixtures.editPlan()
    let word5 = plan.words.first { $0.id == 5 }!
    let sug = suggestion(wordIDs: [5])
    let state = ProjectState(cutSuggestions: [sug])

    guard
      case .accepted(let slice, _) = acceptCutSuggestion(
        sug.id, in: state, plan: plan, sourceFingerprint: "fp")
    else {
      Issue.record("expected .accepted")
      return
    }
    expectNoDifference(slice.wordIDs, [5])
    expectNoDifference(slice.startSample, word5.startSample!)
    expectNoDifference(slice.endSample, word5.endSample!)
  }

  @Test func spanAtFileBoundsHasNoTightWarnings() {
    // Span covers the whole file: start at sample 0, end at the file duration, so
    // neither cut has a neighbour to tight-join.
    let editPlan = plan(
      words: [
        WordSpec(1, "a", 0, 100),
        WordSpec(2, "b", 100, 200),
      ],
      durationSamples: 200)
    let sug = suggestion(wordIDs: [1, 2])
    let state = ProjectState(cutSuggestions: [sug])

    guard
      case .accepted(let slice, _) = acceptCutSuggestion(
        sug.id, in: state, plan: editPlan, sourceFingerprint: "fp")
    else {
      Issue.record("expected .accepted")
      return
    }
    expectNoDifference(slice.startSample, 0)
    expectNoDifference(slice.endSample, 200)
    expectNoDifference(slice.warnings, [])
  }

  @Test func midFileSpanWithoutSilenceIsTight() {
    // A cut out at sample 200 sits mid-file with no silence touching it → tightEnd.
    let editPlan = plan(
      words: [
        WordSpec(1, "a", 0, 100),
        WordSpec(2, "b", 100, 200),
      ],
      durationSamples: 500)
    let sug = suggestion(wordIDs: [1, 2])
    let state = ProjectState(cutSuggestions: [sug])

    guard
      case .accepted(let slice, _) = acceptCutSuggestion(
        sug.id, in: state, plan: editPlan, sourceFingerprint: "fp")
    else {
      Issue.record("expected .accepted")
      return
    }
    expectNoDifference(slice.warnings, [.tightEnd])
  }
}
