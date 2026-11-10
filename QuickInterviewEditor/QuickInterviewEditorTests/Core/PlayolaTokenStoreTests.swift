import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

struct PlayolaTokenStoreTests {

  @Test func serviceIdIsStable() {
    expectNoDifference(
      PlayolaKeychain.service, "fm.playola.PlayolaInterviewEditor.playolaToken")
  }

  @Test func nonUTF8ItemDataIsAnErrorNotAbsent() {
    #expect(throws: PlayolaKeychainError.unreadableData) {
      try PlayolaKeychain.token(from: Data([0xFF, 0xFE]))
    }
  }

  @Test func utf8ItemDataDecodesToTheToken() throws {
    expectNoDifference(try PlayolaKeychain.token(from: Data("abc".utf8)), "abc")
  }

  @Test func inMemoryStoreKeepsEachEnvironmentSeparate() async throws {
    let store = PlayolaTokenStore.inMemory()
    try await store.save("p", .production)
    try await store.save("s", .staging)

    let stagingBefore = try await store.load(.staging)
    try await store.delete(.staging)
    let stagingAfter = try await store.load(.staging)
    let production = try await store.load(.production)

    expectNoDifference(stagingBefore, "s")
    expectNoDifference(stagingAfter, nil)
    expectNoDifference(production, "p")
  }

  @Test func inMemoryStoreSeedsInitialTokens() async throws {
    let store = PlayolaTokenStore.inMemory([.local: "l"])
    let local = try await store.load(.local)
    let production = try await store.load(.production)

    expectNoDifference(local, "l")
    expectNoDifference(production, nil)
  }
}
