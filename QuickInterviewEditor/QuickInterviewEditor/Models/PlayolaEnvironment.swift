import Foundation

enum PlayolaEnvironment: String, Codable, CaseIterable, Sendable {
  case production, staging, local

  var baseURL: URL {
    switch self {
    case .production: URL(string: "https://admin-api.playola.fm")!
    case .staging: URL(string: "https://admin-api-staging.playola.fm")!
    case .local: URL(string: "http://localhost:10020")!
    }
  }

  var label: String {
    switch self {
    case .production: "Production"
    case .staging: "Staging"
    case .local: "Local"
    }
  }

  static var allowsSwitching: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  static func resolved(_ setting: PlayolaEnvironment, allowsSwitching: Bool) -> PlayolaEnvironment {
    allowsSwitching ? setting : .production
  }
}
