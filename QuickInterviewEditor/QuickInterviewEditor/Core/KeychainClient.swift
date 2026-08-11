import Dependencies
import Foundation
import Security
import Synchronization

/// Stores the user's BYO Anthropic API key in the macOS Keychain. A `Sendable`
/// dependency client so Settings can save/clear it and the credential resolver can read
/// it, all overridable in tests with an in-memory store (no real Keychain touched).
///
/// The item is keyed by a STABLE, machine-wide service id (``KeychainStore/service``) —
/// never derived from the workspace path or build dir — so a key set once is shared
/// across every dev workspace/build on the machine. Never stored in UserDefaults / a
/// plist; the raw key is never logged.
struct KeychainClient: Sendable {
  /// Upserts the Anthropic key (overwriting any existing value).
  var save: @Sendable (String) throws -> Void
  /// The stored key, or `nil` when none has been saved.
  var load: @Sendable () throws -> String?
  /// Removes the stored key (a no-op when none exists).
  var delete: @Sendable () throws -> Void
}

extension KeychainClient: DependencyKey {
  static var liveValue: KeychainClient {
    KeychainClient(
      save: { try KeychainStore.save($0) },
      load: { try KeychainStore.load() },
      delete: { try KeychainStore.delete() }
    )
  }
}

extension KeychainClient: TestDependencyKey {
  /// Tests and previews default to an in-memory store, so a forgotten override can never
  /// read or write the developer's real Keychain.
  static var testValue: KeychainClient { .inMemory() }
  static var previewValue: KeychainClient { .inMemory() }
}

extension KeychainClient {
  /// An in-memory stand-in — never touches the real Keychain. Used as the test/preview
  /// default and constructable with a seed value for a "key already set" scenario.
  static func inMemory(_ initial: String? = nil) -> KeychainClient {
    let storage = Mutex<String?>(initial)
    return KeychainClient(
      save: { key in storage.withLock { $0 = key } },
      load: { storage.withLock { $0 } },
      delete: { storage.withLock { $0 = nil } }
    )
  }
}

extension DependencyValues {
  var keychain: KeychainClient {
    get { self[KeychainClient.self] }
    set { self[KeychainClient.self] = newValue }
  }
}

// MARK: - KeychainStore

/// The thin `Security` wrapper behind ``KeychainClient/liveValue``. A generic-password
/// item under a fixed, machine-wide service id + account, so the key is shared across
/// every build/workspace on the machine and survives app reinstalls.
enum KeychainStore {
  /// Stable, machine-wide service id. Deliberately a constant literal (not derived from
  /// the bundle path or build dir) so a key set once is reused everywhere.
  static let service = "fm.playola.QuickInterviewEditor.anthropicAPIKey"
  static let account = "anthropic"

  private static func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  static func save(_ key: String) throws {
    let data = Data(key.utf8)
    let update = SecItemUpdate(
      baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if update == errSecItemNotFound {
      var insert = baseQuery()
      insert[kSecValueData as String] = data
      let add = SecItemAdd(insert as CFDictionary, nil)
      if add == errSecDuplicateItem {
        // A concurrent first save inserted the item between our update and add; the item
        // now exists, so update it rather than reporting a spurious failure.
        let retry = SecItemUpdate(
          baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard retry == errSecSuccess else { throw KeychainError.unexpectedStatus(retry) }
      } else {
        guard add == errSecSuccess else { throw KeychainError.unexpectedStatus(add) }
      }
    } else {
      guard update == errSecSuccess else { throw KeychainError.unexpectedStatus(update) }
    }
  }

  static func load() throws -> String? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
      return nil
    }
    return string
  }

  static func delete() throws {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(status)
    }
  }
}

/// A Keychain failure. The `OSStatus` is surfaced for debugging; the key value is never
/// included in the message.
enum KeychainError: Error, Equatable, LocalizedError {
  case unexpectedStatus(OSStatus)
  var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      return "Keychain access failed (status \(status))."
    }
  }
}
