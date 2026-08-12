import Testing

@testable import QuickInterviewEditor

@Suite struct TranscriptionCacheKeyTests {
  @Test func sha256FingerprintProducesStableKey() {
    let firstKey = TranscriptionCacheKey.make(
      sourceFingerprint: "sha256:abc", engineFingerprint: "engine:src:1")
    let secondKey = TranscriptionCacheKey.make(
      sourceFingerprint: "sha256:abc", engineFingerprint: "engine:src:1")
    #expect(firstKey != nil)
    #expect(firstKey == secondKey)
  }

  @Test func differentEngineFingerprintChangesKey() {
    let firstKey = TranscriptionCacheKey.make(
      sourceFingerprint: "sha256:abc", engineFingerprint: "engine:src:1")
    let secondKey = TranscriptionCacheKey.make(
      sourceFingerprint: "sha256:abc", engineFingerprint: "engine:src:2")
    #expect(firstKey != secondKey)
  }

  @Test func pathFingerprintBypassesCache() {
    let key = TranscriptionCacheKey.make(
      sourceFingerprint: "path:/tmp/x.wav", engineFingerprint: "engine:src:1")
    #expect(key == nil)
  }
}
