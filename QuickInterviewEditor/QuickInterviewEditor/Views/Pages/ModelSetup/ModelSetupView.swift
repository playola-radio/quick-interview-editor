import SwiftUI

/// First-launch model setup screen. Visuals only — every string and flag comes
/// from ``ModelSetupModel``.
struct ModelSetupView: View {
  @State var model: ModelSetupModel

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "waveform.badge.magnifyingglass")
        .font(.system(size: 48))
        .foregroundStyle(.tint)

      Text(model.title)
        .font(.title2.bold())

      Text(model.subtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)

      if model.showsProgressBar {
        ProgressView(value: model.progressFraction)
          .frame(maxWidth: 360)
      }

      Text(model.statusMessage)
        .font(.footnote)
        .foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
        .multilineTextAlignment(.center)

      HStack(spacing: 12) {
        if model.showsRetry {
          Button(model.retryButtonLabel) {
            Task { await model.retryTapped() }
          }
          .keyboardShortcut(.defaultAction)
        }
        if model.showsCancel {
          Button(model.cancelButtonLabel) {
            model.cancelTapped()
          }
        }
      }
    }
    .padding(40)
    .frame(minWidth: 520, minHeight: 360)
    .task { await model.viewAppeared() }
  }
}
