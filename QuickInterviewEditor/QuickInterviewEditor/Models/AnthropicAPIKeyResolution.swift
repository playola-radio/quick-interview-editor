import Foundation

/// The environment variable the Anthropic SDK (and the Python cutter's provider) reads
/// for credentials. Used as the dev-convenience fallback when no Keychain key is set.
let anthropicAPIKeyEnvVar = "ANTHROPIC_API_KEY"

/// Resolves the Anthropic API key by a fixed order: a non-empty Keychain value wins, then
/// the `ANTHROPIC_API_KEY` environment variable, else `nil` — the "no key" state that
/// drives the onboarding UI. Whitespace-only values count as absent, and the resolved key
/// is trimmed. Pure so the order is unit-tested without the Keychain or a real environment.
func resolveAnthropicAPIKey(keychain: String?, env: String?) -> String? {
  if let key = nonEmptyTrimmed(keychain) { return key }
  if let key = nonEmptyTrimmed(env) { return key }
  return nil
}

private func nonEmptyTrimmed(_ value: String?) -> String? {
  guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
  else { return nil }
  return trimmed
}
