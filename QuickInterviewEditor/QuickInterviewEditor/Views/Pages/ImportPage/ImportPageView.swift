import SwiftUI

struct ImportPageView: View {
  @Bindable var model: RootModel

  var body: some View {
    VStack(spacing: 12) {
      Text(model.emptyStateTitle).font(.system(size: 20, weight: .semibold))
        .foregroundStyle(Color(white: 0.85))
      Text(model.emptyStateSubtitle).foregroundStyle(Color(white: 0.5))
      Button(model.importButtonLabel) { model.importButtonTapped() }
        .padding(.top, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
  }
}
