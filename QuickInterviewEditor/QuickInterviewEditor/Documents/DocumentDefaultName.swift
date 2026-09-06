import AppKit
import SwiftUI

/// Gives a still-unsaved project window a default save name. SwiftUI's `DocumentGroup` exposes no
/// first-party hook for the untitled document's suggested filename (it stays "Untitled"), so this
/// zero-size representable reaches the window's backing `NSDocument` and sets its `displayName`
/// while the document has no file URL yet. The `.pie` extension is appended by the document type;
/// we hand over the extensionless stem only. Once the window is saved (`fileURL != nil`) it stops
/// touching the name so a saved project's real filename is never overwritten.
struct DocumentDefaultName: NSViewRepresentable {
  let suggestedName: String?

  func makeNSView(context: Context) -> NameApplyingView {
    let view = NameApplyingView()
    view.suggestedName = suggestedName
    return view
  }

  func updateNSView(_ view: NameApplyingView, context: Context) {
    view.suggestedName = suggestedName
    view.applyIfNeeded()
  }

  final class NameApplyingView: NSView {
    var suggestedName: String?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      applyIfNeeded()
    }

    /// Sets the backing document's display name to the suggestion, but only for an untitled
    /// (unsaved) document, and only when it differs — so a re-run during transcription progress
    /// or after saving is a no-op.
    func applyIfNeeded() {
      guard let suggestedName, !suggestedName.isEmpty,
        let document = window?.windowController?.document as? NSDocument,
        document.fileURL == nil,
        document.displayName != suggestedName
      else { return }
      document.displayName = suggestedName
    }
  }
}
