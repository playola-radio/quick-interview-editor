import Dependencies
import Foundation
import Security

struct SecureRandomClient: Sendable {
  var bytes: @Sendable (Int) -> Data
}

extension SecureRandomClient: DependencyKey {
  static var liveValue: SecureRandomClient {
    SecureRandomClient { count in
      var data = Data(count: count)
      let status = data.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
      }
      precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
      return data
    }
  }

  static var testValue: SecureRandomClient {
    SecureRandomClient { Data(repeating: 0, count: $0) }
  }
}

extension SecureRandomClient {
  static func constant(_ data: Data) -> SecureRandomClient {
    SecureRandomClient { _ in data }
  }
}

extension DependencyValues {
  var secureRandom: SecureRandomClient {
    get { self[SecureRandomClient.self] }
    set { self[SecureRandomClient.self] = newValue }
  }
}
