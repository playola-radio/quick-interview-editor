import Foundation

struct PlayolaAccount: Equatable, Sendable {
  var environment: PlayolaEnvironment
  var status: Status

  enum Status: Equatable, Sendable {
    case restoring
    case signedOut(SignedOutReason?)
    case signedIn(PlayolaUser?)
  }

  enum SignedOutReason: Equatable, Sendable {
    case rejectedByPlayola
  }

  var isSignedOut: Bool {
    if case .signedOut = status { return true }
    return false
  }
}

struct PlayolaUser: Equatable, Sendable, Decodable {
  var id: String
  var firstName: String
  var lastName: String?
  var email: String

  var displayName: String {
    [firstName, lastName].compactMap { $0 }.joined(separator: " ")
  }
}
