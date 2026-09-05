import CustomDump
import Testing

@testable import PlayolaInterviewEditor

struct AnthropicAPIKeyResolutionTests {

  @Test func keychainWinsOverEnv() {
    expectNoDifference(resolveAnthropicAPIKey(keychain: "kc-key", env: "env-key"), "kc-key")
  }

  @Test func fallsBackToEnvWhenNoKeychainValue() {
    expectNoDifference(resolveAnthropicAPIKey(keychain: nil, env: "env-key"), "env-key")
  }

  @Test func nilWhenNeitherIsPresent() {
    expectNoDifference(resolveAnthropicAPIKey(keychain: nil, env: nil), nil)
  }

  @Test func whitespaceOnlyKeychainValueFallsThroughToEnv() {
    expectNoDifference(resolveAnthropicAPIKey(keychain: "   \n", env: "env-key"), "env-key")
  }

  @Test func emptyEnvValueResolvesToNil() {
    expectNoDifference(resolveAnthropicAPIKey(keychain: nil, env: ""), nil)
  }

  @Test func resolvedValueIsTrimmed() {
    expectNoDifference(resolveAnthropicAPIKey(keychain: "  kc-key\n", env: nil), "kc-key")
  }
}
