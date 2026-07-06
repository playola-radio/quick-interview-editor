import CustomDump
import Testing

@testable import QuickInterviewEditor

struct SliceWarningsTests {
  private func silence(_ start: Int, _ end: Int) -> EditPlan.Silence {
    EditPlan.Silence(startSample: start, endSample: end)
  }

  @Test func noWarningsWhenSilenceTouchesBothCuts() {
    // silence [900,1000) ends at startSample 1000; silence [2000,2100) starts at endSample 2000
    let warnings = sliceWarnings(
      startSample: 1000, endSample: 2000, durationSamples: 5000,
      silences: [silence(900, 1000), silence(2000, 2100)])
    expectNoDifference(warnings, [])
  }

  @Test func tightStartWhenNoSilenceAtStartCut() {
    let warnings = sliceWarnings(
      startSample: 1000, endSample: 2000, durationSamples: 5000,
      silences: [silence(2000, 2100)])
    expectNoDifference(warnings, [.tightStart])
  }

  @Test func tightEndWhenNoSilenceAtEndCut() {
    let warnings = sliceWarnings(
      startSample: 1000, endSample: 2000, durationSamples: 5000,
      silences: [silence(900, 1000)])
    expectNoDifference(warnings, [.tightEnd])
  }

  @Test func bothTightWhenNoSilenceAtAll() {
    let warnings = sliceWarnings(
      startSample: 1000, endSample: 2000, durationSamples: 5000, silences: [])
    expectNoDifference(warnings, [.tightStart, .tightEnd])
  }

  @Test func overlappingSilenceCountsAsClean() {
    // silence spans across the start cut → clean start
    let warnings = sliceWarnings(
      startSample: 1000, endSample: 2000, durationSamples: 5000,
      silences: [silence(950, 1050), silence(1950, 2050)])
    expectNoDifference(warnings, [])
  }

  @Test func cutsAtFileEdgesAreClean() {
    // start at 0 (no predecessor) and end at durationSamples (no successor)
    let warnings = sliceWarnings(
      startSample: 0, endSample: 5000, durationSamples: 5000, silences: [])
    expectNoDifference(warnings, [])
  }

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
