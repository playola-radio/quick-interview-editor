import SwiftUI

struct WelcomePageView: View {
  @State var model: WelcomePageModel
  let modelSetupRequired: Bool

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "dot.radiowaves.left.and.right")
        .font(.system(size: 48))
        .foregroundStyle(.tint)

      Text(model.title)
        .font(.title2.bold())

      Text(model.message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)

      if let notice = model.notice {
        switch notice {
        case .error(let text):
          Text(text)
            .font(.footnote)
            .foregroundStyle(Color.red)
            .multilineTextAlignment(.center)
        case .warning(let text):
          Text(text)
            .font(.footnote)
            .foregroundStyle(Color.orange)
            .multilineTextAlignment(.center)
        }
      }

      if model.showsProgress {
        VStack(spacing: 8) {
          ProgressView().progressViewStyle(.linear)
          Text(model.waitingText)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 360)
      }

      HStack(spacing: 12) {
        if model.showsSignInButtons {
          Button(model.signInButtonTitle) {
            Task { await model.signInTapped() }
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          Button(model.localFileButtonTitle) {
            model.useLocalFileTapped()
          }
          .buttonStyle(.bordered)
        }
        if model.showsCancelButton {
          Button(model.cancelButtonTitle) {
            model.cancelTapped()
          }
          .buttonStyle(.bordered)
        }
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .frame(minWidth: 520, minHeight: 360)
    .dropDestination(for: URL.self) { urls, _ in
      model.fileDropped(urls, modelSetupRequired: modelSetupRequired)
    }
  }
}
