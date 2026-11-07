import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct PlayolaEnvironmentTests {
  @Test func baseURLsMatchIOSConfig() {
    expectNoDifference(
      PlayolaEnvironment.production.baseURL.absoluteString, "https://admin-api.playola.fm")
    expectNoDifference(
      PlayolaEnvironment.staging.baseURL.absoluteString, "https://admin-api-staging.playola.fm")
    expectNoDifference(
      PlayolaEnvironment.local.baseURL.absoluteString, "http://localhost:10020")
  }

  @Test func releaseAlwaysResolvesToProduction() {
    expectNoDifference(
      PlayolaEnvironment.resolved(.staging, allowsSwitching: false), .production)
    expectNoDifference(PlayolaEnvironment.resolved(.local, allowsSwitching: true), .local)
  }

  @Test func displayNameJoinsFirstAndLastName() {
    expectNoDifference(
      PlayolaUser(id: "u", firstName: "Brian", lastName: "Keane", email: "b@p.fm").displayName,
      "Brian Keane")
    expectNoDifference(
      PlayolaUser(id: "u", firstName: "Brian", lastName: nil, email: "b@p.fm").displayName,
      "Brian")
  }

  @Test func displayNameSkipsEmptyNameParts() {
    expectNoDifference(
      PlayolaUser(id: "u", firstName: "Brian", lastName: "", email: "b@p.fm").displayName,
      "Brian")
    expectNoDifference(
      PlayolaUser(id: "u", firstName: "", lastName: "Keane", email: "b@p.fm").displayName,
      "Keane")
  }
}
