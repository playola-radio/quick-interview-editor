import Dependencies
import Foundation

/// Reads process environment variables behind the dependency boundary, so key resolution
/// (Keychain → env fallback) is testable without mutating the real environment. Live reads
/// `ProcessInfo`; tests inject values with ``constant(_:)``.
struct EnvironmentClient: Sendable {
  var value: @Sendable (String) -> String?
}

extension EnvironmentClient: DependencyKey {
  static var liveValue: EnvironmentClient {
    EnvironmentClient(value: { ProcessInfo.processInfo.environment[$0] })
  }
}

extension EnvironmentClient: TestDependencyKey {
  /// Tests default to an empty environment (no fallback), and inject values explicitly
  /// via ``constant(_:)`` when a test exercises the env-var path.
  static var testValue: EnvironmentClient {
    EnvironmentClient(value: { _ in nil })
  }
}

extension EnvironmentClient {
  /// A fixed environment for tests/previews.
  static func constant(_ values: [String: String]) -> EnvironmentClient {
    EnvironmentClient(value: { values[$0] })
  }
}

extension DependencyValues {
  var environment: EnvironmentClient {
    get { self[EnvironmentClient.self] }
    set { self[EnvironmentClient.self] = newValue }
  }
}
