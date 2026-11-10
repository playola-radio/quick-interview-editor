import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct PlayolaPKCETests {
  static let rfcVerifierBytes = Data([
    116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
    22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121,
  ])

  static let attempt = PlayolaAuthAttempt(state: "S", verifier: "V", challenge: "C")

  static func callback(_ string: String) -> URL { URL(string: string)! }

  @Test func attemptMatchesRFC7636Vector() {
    let attempt = PlayolaPKCE.makeAttempt(
      stateBytes: Data(repeating: 1, count: 32), verifierBytes: Self.rfcVerifierBytes)
    expectNoDifference(attempt.verifier, "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    expectNoDifference(attempt.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  @Test func base64URLHasNoPaddingAndUsesURLSafeAlphabet() {
    expectNoDifference(PlayolaPKCE.base64URL(Data([0xfb, 0xff, 0xfe])), "-__-")
    expectNoDifference(PlayolaPKCE.base64URL(Data([0x01])), "AQ")
  }

  @Test func secureRandomClientConstantReturnsGivenBytes() {
    let client = SecureRandomClient.constant(Data([1, 2, 3]))
    expectNoDifference(client.bytes(3), Data([1, 2, 3]))
  }

  @Test func authorizeURLHasStateChallengeAndS256AndNoProvider() throws {
    let url = PlayolaPKCE.authorizeURL(environment: .staging, attempt: Self.attempt)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    expectNoDifference(components.scheme, "https")
    expectNoDifference(components.host, "admin-api-staging.playola.fm")
    expectNoDifference(components.path, "/v1/auth/desktop/authorize")
    expectNoDifference(
      components.queryItems,
      [
        URLQueryItem(name: "state", value: "S"),
        URLQueryItem(name: "code_challenge", value: "C"),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
      ])
  }

  @Test func authorizeURLKeepsLocalPortAndScheme() {
    let url = PlayolaPKCE.authorizeURL(environment: .local, attempt: Self.attempt)
    expectNoDifference(url.host, "localhost")
    expectNoDifference(url.port, 10020)
    expectNoDifference(url.scheme, "http")
  }

  @Test func callbackWithMatchingStateReturnsCode() throws {
    let url = Self.callback("playola-interview-editor://auth/callback?code=abc&state=S")
    expectNoDifference(try PlayolaPKCE.code(fromCallback: url, expectedState: "S"), "abc")
  }

  @Test func callbackRejectsWrongSchemeHostOrPath() {
    for string in [
      "https://auth/callback?code=abc&state=S",
      "playola-interview-editor://evil/callback?code=abc&state=S",
      "playola-interview-editor://auth/other?code=abc&state=S",
      "playola-interview-editor://auth/callback/extra?code=abc&state=S",
    ] {
      #expect(throws: PlayolaCallbackError.invalidCallback) {
        try PlayolaPKCE.code(fromCallback: Self.callback(string), expectedState: "S")
      }
    }
  }

  @Test func callbackRejectsMissingOrDuplicateCode() {
    for string in [
      "playola-interview-editor://auth/callback?state=S",
      "playola-interview-editor://auth/callback?code=a&code=b&state=S",
    ] {
      #expect(throws: PlayolaCallbackError.invalidCallback) {
        try PlayolaPKCE.code(fromCallback: Self.callback(string), expectedState: "S")
      }
    }
  }

  @Test func callbackRejectsMismatchedMissingOrDuplicateState() {
    for string in [
      "playola-interview-editor://auth/callback?code=abc&state=other",
      "playola-interview-editor://auth/callback?code=abc",
      "playola-interview-editor://auth/callback?code=abc&state=S&state=S",
    ] {
      #expect(throws: PlayolaCallbackError.invalidCallback) {
        try PlayolaPKCE.code(fromCallback: Self.callback(string), expectedState: "S")
      }
    }
  }

  @Test func callbackWithErrorParameterIsProviderError() {
    let url = Self.callback("playola-interview-editor://auth/callback?error=access_denied&state=S")
    #expect(throws: PlayolaCallbackError.providerError) {
      try PlayolaPKCE.code(fromCallback: url, expectedState: "S")
    }
  }
}
