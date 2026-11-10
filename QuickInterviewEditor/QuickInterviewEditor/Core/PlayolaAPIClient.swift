import Dependencies
import Foundation
import IssueReporting

/// Talks to the Playola admin API for sign-in: trades the one-time browser code for a
/// token, and loads the signed-in user. The token, code and verifier are never logged.
struct PlayolaAPIClient: Sendable {
  /// Trades the one-time code plus the PKCE verifier for a Playola token.
  var exchangeCode:
    @Sendable (_ environment: PlayolaEnvironment, _ code: String, _ codeVerifier: String)
      async throws -> String
  /// The user the token belongs to.
  var currentUser:
    @Sendable (_ environment: PlayolaEnvironment, _ token: String) async throws -> PlayolaUser
}

enum PlayolaAPIError: Error, Equatable {
  case unauthorized
  case badStatus(Int)
  case invalidResponse
}

struct DesktopTokenResponse: Decodable {
  let playolaToken: String
}

// MARK: - Requests

enum PlayolaAPIRequests {
  static func exchange(
    environment: PlayolaEnvironment, code: String, codeVerifier: String
  ) -> URLRequest {
    var request = URLRequest(url: environment.baseURL.appending(path: "v1/auth/desktop/token"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(
      ["code": code, "codeVerifier": codeVerifier])
    return request
  }

  static func currentUser(environment: PlayolaEnvironment, token: String) -> URLRequest {
    var request = URLRequest(url: environment.baseURL.appending(path: "v1/users/me"))
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
  }
}

// MARK: - Responses

enum PlayolaAPIResponse {
  static func validated(_ data: Data, _ response: URLResponse) throws(PlayolaAPIError) -> Data {
    guard let http = response as? HTTPURLResponse else { throw .invalidResponse }
    switch http.statusCode {
    case 200..<300: return data
    case 401: throw .unauthorized
    default: throw .badStatus(http.statusCode)
    }
  }
}

// MARK: - No-redirect delegate

/// The token must only ever go to the server it was issued for, so a redirect is never
/// followed: every one completes with `nil` and the 3xx response surfaces as a bad status.
final class PlayolaNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}

// MARK: - Dependency

extension PlayolaAPIClient: DependencyKey {
  static func makeSession() -> URLSession {
    URLSession(
      configuration: .ephemeral, delegate: PlayolaNoRedirectDelegate(), delegateQueue: nil)
  }

  static var liveValue: PlayolaAPIClient {
    let session = makeSession()

    @Sendable func send<Value: Decodable>(
      _ request: URLRequest, as type: Value.Type
    ) async throws -> Value {
      do {
        let (data, response) = try await session.data(for: request)
        let body = try PlayolaAPIResponse.validated(data, response)
        return try JSONDecoder().decode(Value.self, from: body)
      } catch {
        if let apiError = error as? PlayolaAPIError {
          switch apiError {
          case .badStatus(let status):
            AppLog.playola.error("Playola request failed with status \(status)")
          case .unauthorized:
            AppLog.playola.error("Playola request failed with status 401")
          case .invalidResponse:
            AppLog.playola.error("Playola request got a non-HTTP response")
          }
        } else {
          AppLog.playola.error(
            "Playola request failed: \(String(describing: Swift.type(of: error)), privacy: .public)"
          )
        }
        throw error
      }
    }

    return PlayolaAPIClient(
      exchangeCode: { environment, code, codeVerifier in
        let response = try await send(
          PlayolaAPIRequests.exchange(
            environment: environment, code: code, codeVerifier: codeVerifier),
          as: DesktopTokenResponse.self)
        return response.playolaToken
      },
      currentUser: { environment, token in
        try await send(
          PlayolaAPIRequests.currentUser(environment: environment, token: token),
          as: PlayolaUser.self)
      }
    )
  }
}

extension PlayolaAPIClient: TestDependencyKey {
  static var testValue: PlayolaAPIClient {
    PlayolaAPIClient(
      exchangeCode: unimplemented("PlayolaAPIClient.exchangeCode"),
      currentUser: unimplemented("PlayolaAPIClient.currentUser")
    )
  }
}

extension DependencyValues {
  var playolaAPI: PlayolaAPIClient {
    get { self[PlayolaAPIClient.self] }
    set { self[PlayolaAPIClient.self] = newValue }
  }
}
