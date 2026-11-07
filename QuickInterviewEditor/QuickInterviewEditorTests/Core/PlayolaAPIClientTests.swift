import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct PlayolaAPIClientTests {

  private func response(status: Int) -> URLResponse {
    HTTPURLResponse(
      url: URL(string: "https://admin-api.playola.fm/v1/users/me")!, statusCode: status,
      httpVersion: nil, headerFields: nil)!
  }

  @Test func currentUserRequestTargetsEnvironmentBaseURL() {
    let request = PlayolaAPIRequests.currentUser(environment: .staging, token: "T")

    expectNoDifference(
      request.url?.absoluteString, "https://admin-api-staging.playola.fm/v1/users/me")
    expectNoDifference(request.httpMethod, "GET")
    expectNoDifference(request.value(forHTTPHeaderField: "Authorization"), "Bearer T")
  }

  @Test func exchangeRequestPostsCodeAndVerifierWithoutAuthorization() throws {
    let request = PlayolaAPIRequests.exchange(
      environment: .production, code: "c", codeVerifier: "v")

    expectNoDifference(
      request.url?.absoluteString, "https://admin-api.playola.fm/v1/auth/desktop/token")
    expectNoDifference(request.httpMethod, "POST")
    expectNoDifference(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let body = try JSONDecoder().decode(
      [String: String].self, from: try #require(request.httpBody))
    expectNoDifference(body, ["code": "c", "codeVerifier": "v"])
  }

  @Test func successStatusReturnsTheBody() throws {
    let body = Data("ok".utf8)
    expectNoDifference(try PlayolaAPIResponse.validated(body, response(status: 200)), body)
    expectNoDifference(try PlayolaAPIResponse.validated(body, response(status: 204)), body)
  }

  @Test func unauthorizedStatusMapsToUnauthorized() {
    #expect(throws: PlayolaAPIError.unauthorized) {
      try PlayolaAPIResponse.validated(Data(), response(status: 401))
    }
  }

  @Test func otherStatusMapsToBadStatus() {
    #expect(throws: PlayolaAPIError.badStatus(500)) {
      try PlayolaAPIResponse.validated(Data(), response(status: 500))
    }
    #expect(throws: PlayolaAPIError.badStatus(400)) {
      try PlayolaAPIResponse.validated(Data(), response(status: 400))
    }
    #expect(throws: PlayolaAPIError.badStatus(302)) {
      try PlayolaAPIResponse.validated(Data(), response(status: 302))
    }
  }

  @Test func nonHTTPResponseMapsToInvalidResponse() {
    let nonHTTP = URLResponse(
      url: URL(string: "https://admin-api.playola.fm")!, mimeType: nil,
      expectedContentLength: 0, textEncodingName: nil)
    #expect(throws: PlayolaAPIError.invalidResponse) {
      try PlayolaAPIResponse.validated(Data(), nonHTTP)
    }
  }

  @Test func userDecodesWithNullLastNameAndUnknownFields() throws {
    let json = """
      {"id":"u1","firstName":"Ana","lastName":null,"email":"a@p.fm","role":"admin",\
      "profileImageUrl":"x"}
      """
    let user = try JSONDecoder().decode(PlayolaUser.self, from: Data(json.utf8))

    expectNoDifference(
      user, PlayolaUser(id: "u1", firstName: "Ana", lastName: nil, email: "a@p.fm"))
  }

  @Test func tokenResponseDecodes() throws {
    let decoded = try JSONDecoder().decode(
      DesktopTokenResponse.self, from: Data(#"{"playolaToken":"eyJ"}"#.utf8))

    expectNoDifference(decoded.playolaToken, "eyJ")
  }

  @Test func noRedirectDelegateRefusesRedirects() async {
    let url = URL(string: "https://admin-api.playola.fm/v1/users/me")!
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: url)
    let redirect = HTTPURLResponse(
      url: url, statusCode: 302, httpVersion: nil,
      headerFields: ["Location": "https://evil.example/steal"])!

    let followed = await PlayolaNoRedirectDelegate().urlSession(
      session, task: task, willPerformHTTPRedirection: redirect,
      newRequest: URLRequest(url: URL(string: "https://evil.example/steal")!))

    #expect(followed == nil)
  }
}
