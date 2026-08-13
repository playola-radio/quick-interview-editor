import SwiftUI

/// The always-visible interview transport: Play / Pause / Stop. Logic-free — it binds to the
/// model's computed labels and enabled flags and forwards taps. Space (Play/Stop) routes through
/// the key monitor to the same transport; these buttons are the pointer path to it.
struct TransportPanelView: View {
  @Bindable var model: EditorModel

  private let accent = Color(red: 0.96, green: 0.86, blue: 0.4)

  var body: some View {
    HStack(spacing: 8) {
      button(
        system: "play.fill", help: model.transportPlayLabel,
        enabled: model.canTransportPlay, active: model.isTransportPlaying
      ) {
        Task { await model.transportPlayTapped() }
      }
      button(
        system: "pause.fill", help: model.transportPauseLabel,
        enabled: model.canTransportPause, active: model.isTransportPaused
      ) {
        Task { await model.transportPauseTapped() }
      }
      button(
        system: "stop.fill", help: model.transportStopLabel,
        enabled: model.canTransportStop, active: false
      ) {
        Task { await model.transportStopTapped() }
      }
    }
    .buttonStyle(.borderless)
  }

  private func button(
    system: String, help: String, enabled: Bool, active: Bool, _ run: @escaping () -> Void
  ) -> some View {
    Button(action: run) {
      Image(systemName: system)
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 26, height: 22)
    }
    .disabled(!enabled)
    .help(help)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .fill(active ? accent.opacity(0.28) : Color.white.opacity(0.1))
    )
    .foregroundStyle(active ? accent : Color(white: 0.85))
  }
}
