import Foundation

/// A cut is "clean" when a detected silence region touches or overlaps the cut
/// sample. Cuts at the very start/end of the file have no neighbour to join, so
/// they are always clean. This is cut-safety, distinct from the transcript's
/// run-together (gap-slider) reading aid.
func sliceWarnings(
  startSample: Int, endSample: Int, durationSamples: Int, silences: [EditPlan.Silence]
) -> [SliceWarning] {
  var warnings: [SliceWarning] = []
  if startSample > 0, !silenceTouches(startSample, silences) {
    warnings.append(.tightStart)
  }
  if endSample < durationSamples, !silenceTouches(endSample, silences) {
    warnings.append(.tightEnd)
  }
  return warnings
}

private func silenceTouches(_ sample: Int, _ silences: [EditPlan.Silence]) -> Bool {
  silences.contains { sample >= $0.startSample && sample <= $0.endSample }
}

func sampleTimecodeLabel(_ samples: Int, sampleRate: Int) -> String {
  let rate = max(1, sampleRate)
  let tenths = Int((Double(max(0, samples)) / Double(rate) * 10).rounded())
  let minutes = tenths / 600
  let seconds = Double(tenths % 600) / 10
  return String(format: "%d:%04.1f", minutes, seconds)
}

func sampleDurationLabel(_ samples: Int, sampleRate: Int) -> String {
  String(format: "%.1fs", Double(max(0, samples)) / Double(max(1, sampleRate)))
}
