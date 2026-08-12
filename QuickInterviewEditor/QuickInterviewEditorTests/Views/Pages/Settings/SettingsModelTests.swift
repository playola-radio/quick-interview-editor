import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import QuickInterviewEditor

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
}
