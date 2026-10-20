import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import Security
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct SettingsModelTests {

  @Test func onAppearReflectsWhetherAKeyIsStored() {
    withDependencies {
      $0.keychain = .inMemory("sk-existing")
    } operation: {
      let model = SettingsModel()
      model.onAppear()
      expectNoDifference(model.hasStoredKey, true)
      expectNoDifference(model.storedKeyStatus, "A key is saved for this machine.")
    }
  }

  @Test func saveTrimsPersistsClearsDraftAndFiresOnSaved() {
    let saved = LockIsolated(false)
    let keychain = KeychainClient.inMemory(nil)
    withDependencies {
      $0.keychain = keychain
    } operation: {
      let model = SettingsModel(onSaved: { saved.setValue(true) })
      model.apiKeyDraft = "  sk-new\n"
      expectNoDifference(model.canSave, true)
      model.saveTapped()

      expectNoDifference(try? keychain.load(), "sk-new")
      expectNoDifference(model.apiKeyDraft, "")
      expectNoDifference(model.hasStoredKey, true)
      expectNoDifference(saved.value, true)
    }
  }

  @Test func saveIgnoresAWhitespaceOnlyDraft() {
    let keychain = KeychainClient.inMemory(nil)
    withDependencies {
      $0.keychain = keychain
    } operation: {
      let model = SettingsModel()
      model.apiKeyDraft = "   "
      expectNoDifference(model.canSave, false)
      model.saveTapped()
      expectNoDifference(try? keychain.load(), .some(nil))
    }
  }

  @Test func clearRemovesTheKeyAndFiresOnSaved() {
    let saved = LockIsolated(false)
    let keychain = KeychainClient.inMemory("sk-existing")
    withDependencies {
      $0.keychain = keychain
    } operation: {
      let model = SettingsModel(onSaved: { saved.setValue(true) })
      model.onAppear()
      expectNoDifference(model.canClear, true)
      model.clearTapped()

      expectNoDifference(try? keychain.load(), .some(nil))
      expectNoDifference(model.hasStoredKey, false)
      expectNoDifference(saved.value, true)
    }
  }

  @Test func onAppearReadsCacheSizeAndClearWipesIt() {
    let size = LockIsolated<Int64>(2_300_000_000)
    let cleared = LockIsolated(false)
    let model = withDependencies {
      $0.transcriptCache = TranscriptCacheClient(
        lookup: { _ in nil },
        store: { _, plan, url in CachedTranscription(editPlan: plan, canonicalAudioURL: url) },
        clear: {
          cleared.setValue(true)
          size.setValue(0)
        },
        totalSize: { size.value })
    } operation: {
      SettingsModel()
    }

    model.onAppear()
    #expect(model.canClearCache)
    // Build the expected size string via the same formatter the model uses, so the
    // assertion doesn't depend on the runtime locale's decimal separator.
    let expectedSize = ByteCountFormatter.string(fromByteCount: 2_300_000_000, countStyle: .file)
    #expect(model.cacheStatus.contains(expectedSize))

    model.clearCacheTapped()
    #expect(cleared.value)
    #expect(!model.canClearCache)
  }

  @Test func saveFailureNamesTheKeychainErrorAndNextStep() {
    let saved = LockIsolated(false)
    withDependencies {
      $0.keychain = .failing
    } operation: {
      let model = SettingsModel(onSaved: { saved.setValue(true) })
      model.apiKeyDraft = "sk-new"
      model.saveTapped()

      expectNoDifference(
        model.statusMessage,
        "Couldn't save the key: test Keychain failure. "
          + "Make sure your login keychain is unlocked in Keychain Access, "
          + "then try again.")
      expectNoDifference(model.apiKeyDraft, "sk-new")
      expectNoDifference(saved.value, false)
    }
  }

  @Test func removeFailureNamesTheKeychainErrorAndNextStep() {
    withDependencies {
      $0.keychain = .failing
    } operation: {
      let model = SettingsModel()
      model.clearTapped()

      expectNoDifference(
        model.statusMessage,
        "Couldn't remove the key: test Keychain failure. "
          + "Make sure your login keychain is unlocked in Keychain Access, "
          + "then try again.")
    }
  }

  @Test func clearCacheFailureNamesTheCauseAndNextStep() {
    let model = withDependencies {
      $0.transcriptCache = TranscriptCacheClient(
        lookup: { _ in nil },
        store: { _, plan, url in CachedTranscription(editPlan: plan, canonicalAudioURL: url) },
        clear: { throw CocoaError(.fileWriteNoPermission) },
        totalSize: { 1_000 })
    } operation: {
      SettingsModel()
    }
    model.onAppear()

    model.clearCacheTapped()

    expectNoDifference(
      model.statusMessage,
      "Couldn't clear the transcription cache: \(CocoaError(.fileWriteNoPermission).localizedDescription) "
        + "Check that the app is allowed to change files in your Library folder, then try again.")
    expectNoDifference(model.canClearCache, true)
  }

  @Test func keyReadFailureIsNotReportedAsNoKeySaved() {
    withDependencies {
      $0.keychain = .failing
    } operation: {
      let model = SettingsModel()
      model.onAppear()

      expectNoDifference(
        model.storedKeyStatus,
        "Couldn't check for a saved key: test Keychain failure. Make sure your login keychain is unlocked in Keychain "
          + "Access, then reopen Settings.")
    }
  }

  @Test func successfulSaveClearsAnEarlierKeyReadFailure() {
    withDependencies {
      $0.keychain = KeychainClient(
        save: { _ in },
        load: { throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed) },
        delete: {})
    } operation: {
      let model = SettingsModel()
      model.onAppear()
      model.apiKeyDraft = "sk-new"

      model.saveTapped()

      expectNoDifference(model.storedKeyStatus, "A key is saved for this machine.")
    }
  }
}

extension KeychainClient {
  fileprivate static var failing: KeychainClient {
    let error = TestKeychainError()
    return KeychainClient(
      save: { _ in throw error },
      load: { throw error },
      delete: { throw error })
  }
}

private struct TestKeychainError: LocalizedError {
  var errorDescription: String? { "test Keychain failure." }
}
