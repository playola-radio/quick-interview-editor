import CustomDump
import Foundation
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

  private static let engineError =
    #"QIE_ERROR {"schema_version":1,"domain":"logic_markers","operation":"plan","#
    + #""phase":"transcribing","message":"afconvert failed (1): bad format","#
    + #""error_type":"RuntimeError"}"#

  @Test func helperFailurePicksTheLastValidErrorLine() {
    let stderr = [
      #"QIE_EVENT {"type":"progress","phase":"transcribing","message":"Preparing"}"#,
      Self.engineError,
      "QIE_ERROR {not json",
      #"QIE_ERROR {"schema_version":2,"domain":"x","operation":"y","message":"z","error_type":"E"}"#,
    ].joined(separator: "\n")
    expectNoDifference(
      HelperFailure(exitCode: 1, stderr: stderr, logURL: nil).report,
      HelperErrorReport(
        domain: "logic_markers", operation: "plan", phase: "transcribing",
        message: "afconvert failed (1): bad format", errorType: "RuntimeError"))
  }

  @Test func helperFailureDecodesProviderFacts() {
    let line =
      #"QIE_ERROR {"schema_version":1,"domain":"cut_suggester","operation":"suggest","#
      + #""phase":"discovering","message":"Too low.","error_type":"LLMError","#
      + #""provider_error":{"category":"credits","message":"Too low.","status_code":400,"#
      + #""request_id":"req_1","retry_after":null,"retryable":false}}"#
    expectNoDifference(
      HelperFailure(exitCode: 1, stderr: line, logURL: nil).report?.providerError,
      .init(
        category: .credits, message: "Too low.", statusCode: 400, requestID: "req_1",
        retryAfter: nil, retryable: false))
  }

  @Test func helperFailureFallsBackToTheLastNonProtocolLine() {
    let stderr = [
      "Traceback (most recent call last):",
      "ModuleNotFoundError: No module named 'whisperx'",
      #"QIE_EVENT {"type":"progress","message":"x"}"#,
      "QIE_ERROR {broken",
      "",
    ].joined(separator: "\n")
    let failure = HelperFailure(exitCode: 1, stderr: stderr, logURL: nil)
    expectNoDifference(failure.report, nil)
    expectNoDifference(failure.cause, "ModuleNotFoundError: No module named 'whisperx'")
  }

  @Test func helperFailureNamesASignalWhenThereIsNoReport() {
    let failure = HelperFailure(exitCode: 137, stderr: "", logURL: nil)
    expectNoDifference(failure.signal, 9)
    expectNoDifference(failure.cause, "the helper was stopped by signal 9")
  }

  @Test func helperFailureFallsBackToTheExitCode() {
    let failure = HelperFailure(exitCode: 3, stderr: "QIE_EVENT {}\n", logURL: nil)
    expectNoDifference(failure.signal, nil)
    expectNoDifference(failure.cause, "the helper exited with code 3")
  }

  @Test func helperFailureTruncatesLongFallbackText() {
    let failure = HelperFailure(
      exitCode: 1, stderr: String(repeating: "x", count: 1_000), logURL: nil)
    expectNoDifference(failure.cause.count, 301)
    #expect(failure.cause.hasSuffix("…"))
  }

  @Test func transcriptionExitDescribesPhaseCauseAndLogWithoutProtocolLines() {
    let stderr =
      #"QIE_EVENT {"type":"progress","phase":"transcribing","message":"x"}"# + "\n"
      + Self.engineError
    let error = EngineClientError.transcriptionExited(
      HelperFailure(
        exitCode: 1, stderr: stderr, logURL: URL(fileURLWithPath: "/tmp/transcribe-1.log")))
    expectNoDifference(
      error.errorDescription,
      "Transcription failed while transcribing: afconvert failed (1): bad format."
        + "\n\nFull engine log: /tmp/transcribe-1.log")
  }

  @Test func transcriptionExitBySignalSaysSo() {
    let error = EngineClientError.transcriptionExited(
      HelperFailure(exitCode: 139, stderr: "", logURL: nil))
    expectNoDifference(
      error.errorDescription, "Transcription failed: the helper was stopped by signal 11.")
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
