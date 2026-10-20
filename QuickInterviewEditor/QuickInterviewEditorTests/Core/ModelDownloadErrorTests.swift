import Foundation
import Testing

@testable import PlayolaInterviewEditor

@Suite struct ModelDownloadErrorTests {
  @Test func checksumFailureNamesFileUrlAndBothHashes() {
    let text =
      ModelDownloadError.checksumMismatch(
        file: "align/model.pt", url: "https://example.com/model.pt", expected: "aa11",
        actual: "bb22"
      ).errorDescription ?? ""

    #expect(text.contains("align/model.pt"))
    #expect(text.contains("https://example.com/model.pt"))
    #expect(text.contains("aa11"))
    #expect(text.contains("bb22"))
  }

  @Test func storeFailureNamesFileDestinationAndCause() {
    let text =
      ModelDownloadError.couldNotStoreDownload(
        file: "model.bin", destination: "/Models/model.bin", reason: "No space left on device"
      ).errorDescription ?? ""

    #expect(text.contains("model.bin"))
    #expect(text.contains("/Models/model.bin"))
    #expect(text.contains("No space left on device"))
    #expect(text.contains("free space"))
  }
}
