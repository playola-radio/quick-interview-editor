import Foundation

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
