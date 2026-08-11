import ConcurrencyExtras
import CustomDump
import Dependencies
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
}
