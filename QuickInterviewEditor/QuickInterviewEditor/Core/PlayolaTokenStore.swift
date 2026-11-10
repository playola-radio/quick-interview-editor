import Dependencies
import Foundation
import Security
import Synchronization

/// Stores the Playola sign-in token in the macOS Keychain, one item per server
/// (``PlayolaEnvironment``), so each server keeps its own sign-in. The token is never logged.
struct PlayolaTokenStore: Sendable {
  /// The stored token for the server, or `nil` only when none has been saved.
  var load: @Sendable (PlayolaEnvironment) async throws -> String?
  /// Upserts the token for the server.
  var save: @Sendable (String, PlayolaEnvironment) async throws -> Void
  /// Removes the token for the server (a no-op when none exists).
  var delete: @Sendable (PlayolaEnvironment) async throws -> Void
  var deleteIfMatching: @Sendable (String, PlayolaEnvironment) async throws -> Void
}

extension PlayolaTokenStore: DependencyKey {
  /// Every call runs on ONE private serial queue so calls execute in the order they reach
  /// the queue. An actor would not guarantee that: its job order is not FIFO.
  static var liveValue: PlayolaTokenStore {
    let queue = DispatchQueue(label: "fm.playola.PlayolaInterviewEditor.playolaTokenStore")
    @Sendable func onQueue<T: Sendable>(
      _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
      try await withCheckedThrowingContinuation { continuation in
        queue.async { continuation.resume(with: Result { try work() }) }
      }
    }
    return PlayolaTokenStore(
      load: { environment in
        try await onQueue { try PlayolaKeychain.load(environment: environment) }
      },
      save: { token, environment in
        try await onQueue { try PlayolaKeychain.save(token, environment: environment) }
      },
      delete: { environment in
        try await onQueue { try PlayolaKeychain.delete(environment: environment) }
      },
      deleteIfMatching: { token, environment in
        try await onQueue {
          guard try PlayolaKeychain.load(environment: environment) == token else { return }
          try PlayolaKeychain.delete(environment: environment)
        }
      }
    )
  }
}

extension PlayolaTokenStore: TestDependencyKey {
  /// Tests and previews default to an in-memory store, so a forgotten override can never
  /// read or write the developer's real Keychain.
  static var testValue: PlayolaTokenStore { .inMemory() }
  static var previewValue: PlayolaTokenStore { .inMemory() }
}

extension PlayolaTokenStore {
  static func inMemory(_ initial: [PlayolaEnvironment: String] = [:]) -> PlayolaTokenStore {
    let storage = Mutex<[PlayolaEnvironment: String]>(initial)
    return PlayolaTokenStore(
      load: { environment in storage.withLock { $0[environment] } },
      save: { token, environment in storage.withLock { $0[environment] = token } },
      delete: { environment in storage.withLock { $0[environment] = nil } },
      deleteIfMatching: { token, environment in
        storage.withLock {
          guard $0[environment] == token else { return }
          $0[environment] = nil
        }
      }
    )
  }
}

extension DependencyValues {
  var playolaTokenStore: PlayolaTokenStore {
    get { self[PlayolaTokenStore.self] }
    set { self[PlayolaTokenStore.self] = newValue }
  }
}

// MARK: - PlayolaKeychain

/// The thin `Security` wrapper behind ``PlayolaTokenStore/liveValue``. A generic-password
/// item under a fixed service id, with the server's raw value as the account.
enum PlayolaKeychain {
  /// INVARIANT: changing this string, the bundle id, or the Team ID breaks silent token
  /// reads across Sparkle self-updates — see packaging/README.md (Release invariants).
  static let service = "fm.playola.PlayolaInterviewEditor.playolaToken"

  private static func baseQuery(_ environment: PlayolaEnvironment) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: environment.rawValue,
    ]
  }

  /// Item data that isn't UTF-8 is an error, never "no token": the caller must not mistake
  /// a damaged item for a signed-out state.
  static func token(from data: Data) throws(PlayolaKeychainError) -> String {
    guard let token = String(data: data, encoding: .utf8) else {
      throw PlayolaKeychainError.unreadableData
    }
    return token
  }

  static func save(_ token: String, environment: PlayolaEnvironment) throws {
    let data = Data(token.utf8)
    let attributes = [kSecValueData as String: data] as CFDictionary
    let update = SecItemUpdate(baseQuery(environment) as CFDictionary, attributes)
    if update == errSecItemNotFound {
      var insert = baseQuery(environment)
      insert[kSecValueData as String] = data
      let add = SecItemAdd(insert as CFDictionary, nil)
      if add == errSecDuplicateItem {
        let retry = SecItemUpdate(baseQuery(environment) as CFDictionary, attributes)
        guard retry == errSecSuccess else { throw PlayolaKeychainError.unexpectedStatus(retry) }
      } else {
        guard add == errSecSuccess else { throw PlayolaKeychainError.unexpectedStatus(add) }
      }
    } else {
      guard update == errSecSuccess else { throw PlayolaKeychainError.unexpectedStatus(update) }
    }
  }

  static func load(environment: PlayolaEnvironment) throws -> String? {
    var query = baseQuery(environment)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw PlayolaKeychainError.unexpectedStatus(status) }
    guard let data = item as? Data else { throw PlayolaKeychainError.unreadableData }
    return try token(from: data)
  }

  static func delete(environment: PlayolaEnvironment) throws {
    let status = SecItemDelete(baseQuery(environment) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PlayolaKeychainError.unexpectedStatus(status)
    }
  }
}

enum PlayolaKeychainError: Error, Equatable {
  case unexpectedStatus(OSStatus)
  case unreadableData
}
