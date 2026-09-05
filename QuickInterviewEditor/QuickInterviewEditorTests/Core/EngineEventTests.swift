import CustomDump
import Testing

@testable import PlayolaInterviewEditor

struct EngineEventTests {
  @Test func parsesNewPerPhaseFields() {
    let line =
      "QIE_EVENT "
      + #"{"type":"progress","phase":"aligning","phase_index":2,"phase_count":3,"#
      + #""label":"Aligning words","message":"Aligning words","fraction":0.42}"#
    expectNoDifference(
      LiveEngine.parseProgressEvent(line),
      EngineProgress(
        phase: "aligning", phaseIndex: 2, phaseCount: 3,
        label: "Aligning words", message: "Aligning words", fraction: 0.42))
  }

  @Test func rendersUnknownFuturePhaseInsteadOfDropping() {
    // A phase string the app has never heard of must still decode and render.
    let line =
      "QIE_EVENT "
      + #"{"type":"progress","phase":"diarizing","phase_index":2,"phase_count":4,"#
      + #""label":"Diarizing","message":"Diarizing speakers","fraction":0.1}"#
    let progress = LiveEngine.parseProgressEvent(line)
    expectNoDifference(progress?.phaseOfNText, "Phase 2 of 4")
    expectNoDifference(progress?.displayText, "Diarizing speakers")
  }

  @Test func decodesOldFormatEventWithoutMetadata() {
    let line =
      "QIE_EVENT "
      + #"{"type":"progress","phase":"transcribing","message":"Preparing audio…"}"#
    expectNoDifference(
      LiveEngine.parseProgressEvent(line),
      EngineProgress(phase: "transcribing", message: "Preparing audio…"))
    // No "Phase X of N" prefix without index/count.
    expectNoDifference(LiveEngine.parseProgressEvent(line)?.phaseOfNText, nil)
  }

  @Test func nullFractionIsIndeterminateLikeAbsent() {
    let line =
      "QIE_EVENT "
      + #"{"type":"progress","phase":"finalizing","phase_index":3,"phase_count":3,"#
      + #""label":"Finalizing","message":"Converting audio…","fraction":null}"#
    expectNoDifference(LiveEngine.parseProgressEvent(line)?.fraction, nil)
  }

  @Test func malformedMetadataFieldsAreIgnoredNotDropped() {
    // Wrong JSON types on optional fields must not drop the whole event: the message
    // and any well-typed field still render; the bad fields fall back to nil.
    let line =
      "QIE_EVENT "
      + #"{"type":"progress","phase":"transcribing","phase_index":"two","phase_count":3,"#
      + #""fraction":"soon","message":"Transcribing"}"#
    let progress = LiveEngine.parseProgressEvent(line)
    expectNoDifference(progress?.phase, "transcribing")
    expectNoDifference(progress?.message, "Transcribing")
    expectNoDifference(progress?.phaseIndex, nil)  // "two" ignored
    expectNoDifference(progress?.phaseCount, 3)  // well-typed field kept
    expectNoDifference(progress?.fraction, nil)  // "soon" ignored
    expectNoDifference(progress?.phaseOfNText, nil)  // index missing -> no prefix
  }

  @Test func nonProgressAndNonEventLinesAreIgnored() {
    #expect(LiveEngine.parseProgressEvent("plain stderr noise") == nil)
    #expect(LiveEngine.parseProgressEvent(#"QIE_EVENT {"type":"other"}"#) == nil)
  }

  @Test func phaseOfNTextRequiresSaneMetadata() {
    // index > count, count <= 0, or index without count -> no prefix (but message +
    // fraction still render elsewhere).
    expectNoDifference(
      EngineProgress(phase: "x", phaseIndex: 4, phaseCount: 3, message: "m").phaseOfNText, nil)
    expectNoDifference(
      EngineProgress(phase: "x", phaseIndex: 1, phaseCount: 0, message: "m").phaseOfNText, nil)
    expectNoDifference(
      EngineProgress(phase: "x", phaseIndex: 2, message: "m").phaseOfNText, nil)
    expectNoDifference(
      EngineProgress(phase: "x", phaseIndex: 2, phaseCount: 3, message: "m").phaseOfNText,
      "Phase 2 of 3")
  }

  @Test func displayTextFallsBackLabelThenPhaseThenGeneric() {
    // message wins when present -> keeps the Finalizing sub-status live.
    expectNoDifference(
      EngineProgress(phase: "finalizing", label: "Finalizing", message: "Finding silence…")
        .displayText, "Finding silence…")
    expectNoDifference(
      EngineProgress(phase: "aligning", label: "Aligning words", message: "").displayText,
      "Aligning words")
    expectNoDifference(EngineProgress(phase: "aligning", message: "").displayText, "aligning")
    expectNoDifference(EngineProgress(phase: "", message: "").displayText, "Working")
  }

  @Test func errorHasUserFacingDescription() {
    let error = EngineClientError.engineFailed("boom")
    #expect(error.errorDescription?.contains("boom") == true)
  }

  @Test func sanitizedFractionClampsAndDropsJunk() {
    expectNoDifference(LiveEngine.sanitizedFraction(0.4), 0.4)
    expectNoDifference(LiveEngine.sanitizedFraction(-1), 0)
    expectNoDifference(LiveEngine.sanitizedFraction(2), 1)
    expectNoDifference(LiveEngine.sanitizedFraction(.nan), nil)
    expectNoDifference(LiveEngine.sanitizedFraction(.infinity), nil)
    expectNoDifference(LiveEngine.sanitizedFraction(nil), nil)
  }
}
