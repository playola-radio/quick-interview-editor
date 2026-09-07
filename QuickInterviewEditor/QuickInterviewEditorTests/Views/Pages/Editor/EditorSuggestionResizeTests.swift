import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

/// Resizing a cut suggestion (Shift-extend / marquee-extend / fine-tune grip) and then accepting
/// it must produce a clip matching the on-screen extent — including words the resize added or
/// dropped — while every other accept still uses the suggestion's own words.
@MainActor
struct EditorSuggestionResizeTests {

  // "This is an audiotape" (words 1–4), then "Bob" (word 5) after a gap, so a resize can add it.
  private func plan() -> EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: .init(path: "", sampleRate: 1000, channels: 1, durationSamples: 1_000_000),
      words: [
        Word(id: 1, text: "This", start: 100, end: 150, startSample: 100_000, endSample: 150_000),
        Word(id: 2, text: "is", start: 150, end: 200, startSample: 150_000, endSample: 200_000),
        Word(id: 3, text: "an", start: 200, end: 250, startSample: 200_000, endSample: 250_000),
        Word(
          id: 4, text: "audiotape", start: 250, end: 300, startSample: 250_000,
          endSample: 300_000),
        Word(id: 5, text: "Bob", start: 400, end: 450, startSample: 400_000, endSample: 450_000),
      ], silences: [], segments: [])
  }

  // Same tape, but with a predecessor word "hello" (id 10) whose alignment end-overlap bleeds one
  // sample past word 1's start (105_000 > 100_000). Any-overlap over the suggestion's covering span
  // would wrongly grab it; the midpoint (word-derived) rule does not — so it distinguishes the two
  // accept paths for an *unresized* selection.
  private func planWithOverlappingPredecessor() -> EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: .init(path: "", sampleRate: 1000, channels: 1, durationSamples: 1_000_000),
      words: [
        Word(id: 10, text: "hello", start: 50, end: 105, startSample: 50_000, endSample: 105_000),
        Word(id: 1, text: "This", start: 100, end: 150, startSample: 100_000, endSample: 150_000),
        Word(id: 2, text: "is", start: 150, end: 200, startSample: 150_000, endSample: 200_000),
        Word(id: 3, text: "an", start: 200, end: 250, startSample: 200_000, endSample: 250_000),
        Word(
          id: 4, text: "audiotape", start: 250, end: 300, startSample: 250_000,
          endSample: 300_000),
      ], silences: [], segments: [])
  }

  private func editor(_ plan: EditPlan) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan, sourceFingerprint: "fp")
  }

  /// Installs identity source + edited geometry so waveform hit-testing works: with `spp: 1000`,
  /// view-x maps to source samples as `sample = x * 1000`, covering the full 1_000_000-sample tape.
  private func geometry(_ model: EditorModel, samplesPerPixel: Double = 1000) {
    let duration = model.editPlan.source.durationSamples
    model.waveform.totalSamples = duration
    model.waveform.waveform = Waveform.pyramid(
      baseMins: [0], baseMaxs: [0], sampleRate: model.editPlan.source.sampleRate,
      totalSamples: duration, baseBucketSize: 4)
    model.waveform.viewportWidth = 1000
    model.waveform.samplesPerPixel = samplesPerPixel
    model.waveform.visibleStartSample = 0
    model.editedWaveform.viewportWidth = 1000
    model.editedWaveform.samplesPerPixel = samplesPerPixel
    model.editedWaveform.visibleStartSample = 0
  }

  /// A suggestion whose provenance matches the editor built above (fingerprint "fp", the plan's
  /// own transcript hash), so it survives the accept path's staleness gates.
  private func suggestion(_ plan: EditPlan, id: UUID, wordIDs: [Word.ID]) -> CutSuggestion {
    var sug = Fixtures.cutSuggestion(id: id, wordIDs: wordIDs)
    sug.provenance.sourceFingerprint = "fp"
    sug.provenance.transcriptHash = plan.transcriptHash
    return sug
  }

  // MARK: - Editing-link lifecycle (Stage 2)

  @Test func revealingASuggestionEstablishesTheEditingLink() {
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])

    model.cutSuggestionSelected(sug)

    expectNoDifference(model.selectedCutSuggestionID, sug.id)
  }

  @Test func revealingAStaleSuggestionLeavesNoLink() {
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(9), wordIDs: [900, 901])

    model.cutSuggestionSelected(sug)

    #expect(model.selectedCutSuggestionID == nil)
  }

  @Test func shiftExtendRetainsTheLinkAndGrowsTheAdjustedRange() {
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.cutSuggestionSelected(sug)

    // Drag the transcript selection's end past "Bob".
    model.selectWord(5, extending: true)

    expectNoDifference(model.selectedCutSuggestionID, sug.id)
    expectNoDifference(model.adjustedRangeForSuggestion(sug.id), 100_000..<450_000)
  }

  @Test func adjustedRangeIsNilForADifferentSuggestion() {
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.cutSuggestionSelected(sug)
    model.selectWord(5, extending: true)

    #expect(model.adjustedRangeForSuggestion(Fixtures.uuid(2)) == nil)
  }

  @Test func aFreshSelectionDropsTheLink() {
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.cutSuggestionSelected(sug)

    // A brand-new (non-extending) selection replaces the suggestion's, so its accept goes back
    // to the word-derived range.
    model.selectWord(5, extending: false)

    #expect(model.selectedCutSuggestionID == nil)
    #expect(model.adjustedRangeForSuggestion(sug.id) == nil)
  }

  @Test func clearingTheSelectionDropsTheLink() {
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.cutSuggestionSelected(sug)

    model.clearSelection()

    #expect(model.selectedCutSuggestionID == nil)
  }

  @Test func retainingSuggestionWriteKeepsTheLink() {
    // The shared mechanism both extend paths (Shift-extend, marquee-extend) rely on: a funnel
    // write flagged `retainingSuggestion` keeps the link; an unflagged one drops it.
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.cutSuggestionSelected(sug)

    model.selectSourceRange(100_000..<450_000, snapPlayhead: false, retainingSuggestion: true)
    expectNoDifference(model.selectedCutSuggestionID, sug.id)

    model.selectSourceRange(100_000..<200_000, snapPlayhead: false, retainingSuggestion: false)
    #expect(model.selectedCutSuggestionID == nil)
  }

  @Test func adjustedRangeIsNilWithNoActiveSuggestion() {
    let plan = plan()
    let model = editor(plan)
    #expect(model.adjustedRangeForSuggestion(Fixtures.uuid(1)) == nil)
  }

  // MARK: - Accept honors the resize (Stage 3, end-to-end through the panel)

  @Test func acceptingAResizedSuggestionIncludesTheAddedWord() {
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.documentCutSuggestions = [sug]

    model.cutSuggestionSelected(sug)
    model.selectWord(5, extending: true)  // extend to cover "Bob"
    model.cutSuggestions.acceptTapped(sug.id)

    let slice = model.slices[id: sug.id]
    #expect(slice != nil)
    #expect(slice?.wordIDs.contains(5) == true)
    expectNoDifference(slice?.wordIDs, [1, 2, 3, 4, 5])
    expectNoDifference(model.documentCutSuggestions[id: sug.id]?.status, .accepted)
    #expect(model.cutSuggestions.actionMessage == nil)
  }

  @Test func acceptingAResizedSuggestionIsUndoableInOneStep() async {
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.documentCutSuggestions = [sug]

    model.cutSuggestionSelected(sug)
    model.selectWord(5, extending: true)
    model.cutSuggestions.acceptTapped(sug.id)

    #expect(model.canUndo)
    await model.undoTapped()
    expectNoDifference(model.slices.count, 0)
    expectNoDifference(model.documentCutSuggestions[id: sug.id]?.status, .pending)
  }

  @Test func acceptingADifferentRowUsesItsOwnWordsNotTheResizedRange() {
    let plan = plan()
    let model = editor(plan)
    let edited = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    let other = suggestion(plan, id: Fixtures.uuid(2), wordIDs: [5])
    model.documentCutSuggestions = [edited, other]

    // The user is resizing suggestion A, but accepts row B.
    model.cutSuggestionSelected(edited)
    model.selectWord(5, extending: true)
    model.cutSuggestions.acceptTapped(other.id)

    expectNoDifference(model.slices[id: other.id]?.wordIDs, [5])
    #expect(model.slices[id: edited.id] == nil)
  }

  @Test func acceptingWithoutAnyResizeUsesTheWordDerivedRange() {
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.documentCutSuggestions = [sug]

    // Selected but not resized: accept lands the suggestion's own four words.
    model.cutSuggestionSelected(sug)
    model.cutSuggestions.acceptTapped(sug.id)

    expectNoDifference(model.slices[id: sug.id]?.wordIDs, [1, 2, 3, 4])
  }

  @Test func selectingAnUnresizedSuggestionDoesNotGrabAnOverlappingNeighbor() {
    // Merely selecting a suggestion must NOT switch Accept to the any-overlap path — that path would
    // pull in the overlapping predecessor "hello" (id 10). A non-resized accept keeps the
    // word-derived membership.
    let plan = planWithOverlappingPredecessor()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.documentCutSuggestions = [sug]

    model.cutSuggestionSelected(sug)  // select, no resize
    model.cutSuggestions.acceptTapped(sug.id)

    #expect(model.slices[id: sug.id]?.wordIDs.contains(10) == false)
    expectNoDifference(model.slices[id: sug.id]?.wordIDs, [1, 2, 3, 4])
  }

  @Test func anUnresizedSelectedSuggestionExposesNoAdjustedRange() {
    // The baseline guard: right after reveal, the live extent equals the baseline, so accept falls
    // back to the word-derived path (nil adjusted range).
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])

    model.cutSuggestionSelected(sug)

    expectNoDifference(model.selectedCutSuggestionID, sug.id)
    #expect(model.adjustedRangeForSuggestion(sug.id) == nil)
  }

  @Test func aStalePendingFineTuneDraftDoesNotPoisonTheSuggestionBaseline() {
    // Baseline capture must read the revealed selection, not `activeEditingRange`. A pending
    // fine-tune draft from a prior selection lingers until the view's next `syncEditSession`; if the
    // baseline captured that stale draft, the post-sync suggestion range would read as a phantom
    // resize and reopen the any-overlap accept bug for an unresized suggestion.
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.documentCutSuggestions = [sug]

    model.selectWord(5, extending: false)  // prior selection on "Bob" (400_000..<450_000)
    model.syncEditSession()  // opens a pending fine-tune draft there

    model.cutSuggestionSelected(sug)  // reveal — baseline must be the suggestion's own selection
    model.syncEditSession()  // view-driven retarget to the new selection

    #expect(model.adjustedRangeForSuggestion(sug.id) == nil)  // unresized → word-derived path
  }

  @Test func aHeldExistingSliceDraftDoesNotLeakIntoASuggestionAccept() {
    // A dirty existing-slice fine-tune edit (held open by `syncEditSession` until Save/Cancel) is
    // unrelated to a suggestion. Its `draftRange` must NOT be read as the suggestion's adjusted
    // extent — only a grip drag on the pending selection counts as resizing the suggestion.
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.documentCutSuggestions = [sug]

    // Hold a dirty slice edit open on an unrelated range, then select the suggestion.
    model.fineTune.begin(target: .slice(Fixtures.uuid(2)), range: 700_000..<800_000)
    model.fineTune.draftRange = 700_000..<820_000  // grip moved → dirty
    model.cutSuggestionSelected(sug)

    // Live extent falls back to the suggestion's own selection (== baseline) → word-derived path,
    // never the slice's 700_000..<820_000 draft.
    #expect(model.adjustedRangeForSuggestion(sug.id) == nil)
  }

  @Test func aStalePendingDraftFromAPriorSelectionIsNotTreatedAsAResize() {
    // A pending-selection draft from a *previous* selection can still be open at accept time (its
    // retarget is the view's onChange `syncEditSession`). It must not read as a resize of the
    // just-selected suggestion — its committed baseline doesn't match the suggestion's selection.
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.documentCutSuggestions = [sug]

    model.fineTune.begin(target: .pendingSelection, range: 400_000..<450_000)  // prior selection
    model.fineTune.draftRange = 400_000..<460_000  // dirty
    model.cutSuggestionSelected(sug)  // reveal; committed still the old 400k range

    #expect(model.adjustedRangeForSuggestion(sug.id) == nil)
  }

  @Test func aStalePendingDraftWhoseCommittedRangeMatchesTheSuggestionIsNotAResize() {
    // Adversarial variant of the test above: the prior pending session's committed baseline
    // *coincidentally equals* the suggestion's own selection (100_000..<300_000). The
    // `committedRange == selectedSourceRange` gate alone would wave the stale draft through as a
    // phantom resize, and `syncEditSession`'s `committedRange != range` re-anchor shortcut would miss
    // it too. Revealing the suggestion must re-anchor the abandoned draft so an unresized accept
    // stays on the word-derived path.
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.documentCutSuggestions = [sug]

    // Committed baseline == the suggestion's own span; draft dragged out to cover "Bob", never accepted.
    model.fineTune.begin(target: .pendingSelection, range: 100_000..<300_000)
    model.fineTune.draftRange = 100_000..<450_000
    model.cutSuggestionSelected(sug)  // reveal must discard the stale drag

    #expect(model.adjustedRangeForSuggestion(sug.id) == nil)
  }

  @Test func aFineTuneGripResizeOfTheSelectedSuggestionIsHonored() {
    // The positive case the gate must still allow: the pane is tuning THIS selection (committed ==
    // selection) and a grip drag moved the draft — that is a real resize and must be accepted.
    let plan = plan()
    let model = editor(plan)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.cutSuggestionSelected(sug)

    // Anchored to the selection, then the grip is dragged out to cover "Bob".
    model.fineTune.begin(target: .pendingSelection, range: 100_000..<300_000)
    model.fineTune.draftRange = 100_000..<450_000

    expectNoDifference(model.adjustedRangeForSuggestion(sug.id), 100_000..<450_000)
  }

  @Test func waveformShiftClickExtendRetainsTheLink() {
    // A waveform Shift-click is a resize gesture like transcript Shift-extend; it must retain the
    // edited suggestion so Accept honors the on-screen extent. Before the fix this write dropped the
    // link (no `retainingSuggestion`), so the adjusted range came back nil and Accept silently used
    // the suggestion's original words.
    let plan = plan()
    let model = editor(plan)
    geometry(model)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.cutSuggestionSelected(sug)
    let baseline = model.adjustedRangeForSuggestion(sug.id)  // nil at reveal (extent == baseline)

    // Shift-click somewhere other than the reveal's end edge — the exact landed sample depends on
    // waveform geometry, but it moves the selection so the extent now differs from the baseline.
    model.waveformClicked(atX: 450, extending: true)

    expectNoDifference(model.selectedCutSuggestionID, sug.id)
    #expect(baseline == nil)
    #expect(model.adjustedRangeForSuggestion(sug.id) != nil)
  }

  @Test func aFreshNonExtendingMarqueeDropsTheLinkAtDragStart() {
    // A live marquee writes `audioSelection` directly, so the link must drop at drag *start*, not
    // wait for mouse-up — otherwise a mid-drag Accept would pair the old suggestion with the new
    // range.
    let plan = plan()
    let model = editor(plan)
    geometry(model)
    let sug = suggestion(plan, id: Fixtures.uuid(1), wordIDs: [1, 2, 3, 4])
    model.cutSuggestionSelected(sug)

    model.waveformAreaSelectBegan(atX: 500, extending: false)

    #expect(model.selectedCutSuggestionID == nil)
    #expect(model.adjustedRangeForSuggestion(sug.id) == nil)
  }
}
