import Dependencies
import Foundation
import IssueReporting
import Observation

/// Drives the Anthropic API-key entry surface — used both by the Settings scene (the
/// durable home, Cmd-,) and by the cut-suggester's onboarding sheet. All behavior and copy
/// live here; the view only renders and binds (`SecureField` ↔ `apiKeyDraft`).
///
/// The stored key is never loaded back into the visible field — the model only reports
/// whether one exists (`hasStoredKey`) — and the raw key is never logged.
@MainActor
@Observable
final class SettingsModel: ViewModel, Identifiable {

  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.keychain) var keychain

  // MARK: - Initialization
  /// Fired after a successful save or clear, so a presenting model can refresh its
  /// key-resolution state and dismiss.
  @ObservationIgnored var onSaved: (() -> Void)?

  init(onSaved: (() -> Void)? = nil) {
    self.onSaved = onSaved
    super.init()
  }

  // MARK: - Properties
  /// Bound to the `SecureField`. Not seeded from the stored key (never show it back).
  var apiKeyDraft = ""
  private(set) var hasStoredKey = false
  private(set) var statusMessage: String?

  // MARK: - Display Text
  let title = "Cut Suggestions"
  let fieldLabel = "Anthropic API Key"
  let fieldPrompt = "sk-ant-…"
  let helpText =
    "Paste your Anthropic API key to enable AI cut suggestions. It's stored in your macOS "
    + "Keychain (set once per machine) and usage is billed to your own key."
  let getKeyLinkLabel = "Get an Anthropic API key"
  let getKeyURL = URL(string: "https://console.anthropic.com/settings/keys")!
  let saveLabel = "Save Key"
  let clearLabel = "Remove Key"

  // MARK: - View Helpers
  var canSave: Bool {
    !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var canClear: Bool { hasStoredKey }
  var storedKeyStatus: String {
    hasStoredKey ? "A key is saved for this machine." : "No key saved yet."
  }

  // MARK: - User Actions
  func onAppear() { refreshStoredKeyState() }

  func saveTapped() {
    let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      try keychain.save(trimmed)
      apiKeyDraft = ""
      hasStoredKey = true
      statusMessage = "Saved."
      onSaved?()
    } catch {
      statusMessage = "Could not save the key. Please try again."
      reportIssue(error)
    }
  }

  func clearTapped() {
    do {
      try keychain.delete()
      apiKeyDraft = ""
      hasStoredKey = false
      statusMessage = "Removed."
      onSaved?()
    } catch {
      statusMessage = "Could not remove the key. Please try again."
      reportIssue(error)
    }
  }

  // MARK: - Private Helpers
  private func refreshStoredKeyState() {
    hasStoredKey = ((try? keychain.load()) ?? nil) != nil
  }
}
