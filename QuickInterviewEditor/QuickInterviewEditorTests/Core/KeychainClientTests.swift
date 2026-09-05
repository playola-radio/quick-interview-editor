import CustomDump
import Testing

@testable import PlayolaInterviewEditor

struct KeychainClientTests {

  @Test func inMemoryRoundTripsSaveLoadDelete() throws {
    let client = KeychainClient.inMemory()
    expectNoDifference(try client.load(), nil)

    try client.save("sk-ant-123")
    expectNoDifference(try client.load(), "sk-ant-123")

    // Save overwrites (upsert), not appends.
    try client.save("sk-ant-456")
    expectNoDifference(try client.load(), "sk-ant-456")

    try client.delete()
    expectNoDifference(try client.load(), nil)
  }

  @Test func deleteWhenEmptyIsANoOp() throws {
    let client = KeychainClient.inMemory()
    try client.delete()
    expectNoDifference(try client.load(), nil)
  }

  @Test func inMemorySeedsAnInitialValue() throws {
    let client = KeychainClient.inMemory("seed-key")
    expectNoDifference(try client.load(), "seed-key")
  }

  @Test func testValueNeverTouchesTheRealKeychain() throws {
    // The default testValue is an empty in-memory store, so a forgotten override can't
    // read a real key off the developer's machine.
    expectNoDifference(try KeychainClient.testValue.load(), nil)
  }

  /// Pins the Keychain service id. Changing it silently drops the user's saved API key
  /// across an update (a returning user would have to re-enter it), so it must never
  /// drift by accident — see packaging/README.md (Release invariants).
  @Test func serviceIdIsStable() {
    expectNoDifference(
      KeychainStore.service, "fm.playola.PlayolaInterviewEditor.anthropicAPIKey")
  }
}
