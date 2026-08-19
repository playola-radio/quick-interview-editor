import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorRevealTests {

  // A plan whose word bounds are large enough that a padded zoom-to-selection lands strictly
  // between the min-samples-per-pixel floor (8) and the fit-whole-file ceiling (1000).
  private func plan() -> EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: .init(path: "", sampleRate: 1000, channels: 1, durationSamples: 1_000_000),
      words: [
        Word(id: 1, text: "one", start: 100, end: 150, startSample: 100_000, endSample: 150_000),
        Word(id: 2, text: "two", start: 150, end: 200, startSample: 150_000, endSample: 200_000),
        Word(id: 3, text: "three", start: 200, end: 250, startSample: 200_000, endSample: 250_000),
      ], silences: [], segments: [])
  }

  private func editor() -> EditorModel {
    let model = EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan())
    // Stand in for a loaded waveform so zoom-to-selection has geometry to work with. Reveal now
    // drives the EDITED adapter (identity timeline here — plan durationSamples 1_000_000 — so the
    // math is 1:1 with the old source axis), so give it the same viewport/zoom.
    model.waveform.totalSamples = 1_000_000
    model.waveform.viewportWidth = 1000
    model.waveform.samplesPerPixel = 1000  // fit-whole-file, so a zoom is a visible change
    model.editedWaveform.viewportWidth = 1000
    model.editedWaveform.samplesPerPixel = 1000
    model.editedWaveform.visibleStartSample = 0
    return model
  }

  @Test func clickingASuggestionSelectsItsWordsScrollsAndZooms() {
    let model = editor()
    let suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [1, 3])

    model.cutSuggestionSelected(suggestion)

    expectNoDifference(model.transcript.selectedWordIDSet, [1, 2, 3])
    expectNoDifference(model.transcript.reveal, TranscriptReveal(wordID: 1, token: 1))
    // range 100_000..<250_000 (count 150_000), padded ×1.2 over 1000 px ⇒ 180 spp, centered.
    expectNoDifference(model.editedWaveform.samplesPerPixel, 180)
    expectNoDifference(model.editedWaveform.visibleStartSample, 85_000)
  }

  @Test func clickingAStaleSuggestionLeavesTheViewWhereItIs() {
    let model = editor()
    // A prior selection the user is looking at.
    model.transcript.selectWords(anchorID: 1, focusID: 1)
    model.zoomWaveformToSelection()
    let priorReveal = model.transcript.reveal
    let priorSpp = model.editedWaveform.samplesPerPixel
    let priorStart = model.editedWaveform.visibleStartSample

    // The suggestion references words no longer in the plan → must not jump the view.
    model.cutSuggestionSelected(Fixtures.cutSuggestion(id: Fixtures.uuid(9), wordIDs: [900, 901]))

    expectNoDifference(model.transcript.selectedWordIDSet, [1])
    expectNoDifference(model.transcript.reveal, priorReveal)
    expectNoDifference(model.editedWaveform.samplesPerPixel, priorSpp)
    expectNoDifference(model.editedWaveform.visibleStartSample, priorStart)
  }

  @Test func clickingAPartiallyStaleSuggestionLeavesTheViewWhereItIs() {
    let model = editor()
    model.transcript.selectWords(anchorID: 1, focusID: 1)
    model.zoomWaveformToSelection()
    let priorReveal = model.transcript.reveal
    let priorSpp = model.editedWaveform.samplesPerPixel
    let priorStart = model.editedWaveform.visibleStartSample

    // One surviving word (1) and one missing (900) — must NOT reveal the survivor's narrower span.
    model.cutSuggestionSelected(Fixtures.cutSuggestion(id: Fixtures.uuid(9), wordIDs: [1, 900]))

    expectNoDifference(model.transcript.selectedWordIDSet, [1])
    expectNoDifference(model.transcript.reveal, priorReveal)
    expectNoDifference(model.editedWaveform.samplesPerPixel, priorSpp)
    expectNoDifference(model.editedWaveform.visibleStartSample, priorStart)
  }

  @Test func clickingASuggestionResolvesEndpointsByPositionNotArrayOrder() {
    let model = editor()
    // wordIDs given out of transcript order — the span must still be word 1 … word 3.
    let suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [3, 1])

    model.cutSuggestionSelected(suggestion)

    expectNoDifference(model.transcript.selectedWordIDSet, [1, 2, 3])
    expectNoDifference(model.transcript.reveal, TranscriptReveal(wordID: 1, token: 1))
    expectNoDifference(model.editedWaveform.samplesPerPixel, 180)
  }

  @Test func clickingASuggestionWithNoWordsIsANoOp() {
    let model = editor()
    let suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(1), wordIDs: [])

    model.cutSuggestionSelected(suggestion)

    expectNoDifference(model.transcript.selectedWordIDSet, [])
    #expect(model.transcript.reveal == nil)
    expectNoDifference(model.editedWaveform.samplesPerPixel, 1000)
  }

  @Test func clickingASavedClipRevealsItTheSameWay() {
    let model = editor()
    let id = Fixtures.uuid(2)
    model.acceptCutSuggestionSlice(
      Slice(
        id: id, name: "A clip", startSample: 150_000, endSample: 250_000,
        wordIDs: [2, 3], snippet: "two three", warnings: []))

    model.sliceRevealTapped(id)

    expectNoDifference(model.transcript.selectedWordIDSet, [2, 3])
    expectNoDifference(model.transcript.reveal, TranscriptReveal(wordID: 2, token: 1))
    // range 150_000..<250_000 (count 100_000), padded ×1.2 over 1000 px ⇒ 120 spp, centered.
    expectNoDifference(model.editedWaveform.samplesPerPixel, 120)
    expectNoDifference(model.editedWaveform.visibleStartSample, 140_000)
  }

  @Test func revealingAnUnknownClipIsANoOp() {
    let model = editor()
    model.sliceRevealTapped(Fixtures.uuid(99))
    expectNoDifference(model.transcript.selectedWordIDSet, [])
    expectNoDifference(model.editedWaveform.samplesPerPixel, 1000)
  }

  @Test func zoomWaveformToSelectionIsANoOpWithNoSelection() {
    let model = editor()
    model.zoomWaveformToSelection()
    expectNoDifference(model.editedWaveform.samplesPerPixel, 1000)
  }
}
