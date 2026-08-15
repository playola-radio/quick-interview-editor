import SwiftUI

extension Color {
  /// Renders a model-side `ClipStyleColor` token as a SwiftUI colour. A pure rendering
  /// adapter kept in the view layer, so the palette itself stays in the (portable) model.
  init(_ token: ClipStyleColor) {
    self.init(red: token.red, green: token.green, blue: token.blue, opacity: token.alpha)
  }
}
