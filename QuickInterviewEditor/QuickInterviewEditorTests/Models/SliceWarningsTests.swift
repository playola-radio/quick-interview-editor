import CustomDump
import Testing

@testable import PlayolaInterviewEditor

/// Covers the sample-label formatting helpers that remain in `SliceWarnings.swift` after the
/// tight-join concept was retired (every exported/auditioned clip now gets a boundary declick
/// instead — see `DeclickFadeTests`).
struct SampleLabelFormattingTests {
  @Test func timecodeAndDurationFormat() {
    expectNoDifference(sampleTimecodeLabel(44100 * 5 + 44100 * 9 / 10, sampleRate: 44100), "0:05.9")
    expectNoDifference(sampleTimecodeLabel(44100 * 65, sampleRate: 44100), "1:05.0")
    expectNoDifference(sampleDurationLabel(44100 * 3 + 4410 * 2, sampleRate: 44100), "3.2s")
  }

  @Test func timecodeCarriesRoundedSecondsIntoMinutes() {
    // 59.95s must round up to 1:00.0, not 0:60.0
    let samples = 44100 * 59 + 44100 * 95 / 100
    expectNoDifference(sampleTimecodeLabel(samples, sampleRate: 44100), "1:00.0")
  }
}
