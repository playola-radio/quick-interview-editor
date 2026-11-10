import CryptoKit
import Foundation

struct PlayolaAuthAttempt: Equatable, Sendable {
  let state: String
  let verifier: String
  let challenge: String
}

enum PlayolaCallbackError: Error, Equatable {
  case invalidCallback
  case providerError
}

enum PlayolaPKCE {
  static let callbackScheme = "playola-interview-editor"
  private static let callbackHost = "auth"
  private static let callbackPath = "/callback"

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func makeAttempt(stateBytes: Data, verifierBytes: Data) -> PlayolaAuthAttempt {
    let verifier = base64URL(verifierBytes)
    let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    return PlayolaAuthAttempt(
      state: base64URL(stateBytes), verifier: verifier, challenge: challenge)
  }

  static func authorizeURL(environment: PlayolaEnvironment, attempt: PlayolaAuthAttempt) -> URL {
    var components = URLComponents(
      url: environment.baseURL.appendingPathComponent("v1/auth/desktop/authorize"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "state", value: attempt.state),
      URLQueryItem(name: "code_challenge", value: attempt.challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    return components.url!
  }

  static func code(fromCallback url: URL, expectedState: String) throws(PlayolaCallbackError)
    -> String
  {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw .invalidCallback
    }
    let items = components.queryItems ?? []
    if items.contains(where: { $0.name == "error" }) { throw .providerError }
    guard components.scheme == callbackScheme, components.host == callbackHost,
      components.path == callbackPath
    else { throw .invalidCallback }
    let codes = items.filter { $0.name == "code" }
    let states = items.filter { $0.name == "state" }
    guard codes.count == 1, let code = codes[0].value,
      states.count == 1, states[0].value == expectedState
    else { throw .invalidCallback }
    return code
  }
}
