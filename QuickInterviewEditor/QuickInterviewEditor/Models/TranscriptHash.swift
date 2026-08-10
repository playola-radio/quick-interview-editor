import CryptoKit
import Foundation

extension EditPlan {
  /// A canonical, deterministic hash of the transcript's word content — each word's `id`
  /// and `text`, in order. Two plans with the same spoken words hash identically even if a
  /// re-run shifted sample alignment; any word added, removed, or re-transcribed changes
  /// the hash. This is the transcript-drift gate for cut suggestions: a suggestion whose
  /// `provenance.transcriptHash` ≠ the current transcript's hash is stale.
  ///
  /// Sample bounds are deliberately excluded — the accept path re-derives a slice's samples
  /// from the current words, and a changed *source file* is caught separately by
  /// `sourceFingerprint`. What matters here is whether the words themselves changed. The
  /// each word is length-prefixed (`id`, then the text's UTF-8 byte count, then the bytes)
  /// so no word's content — even text containing separator or control characters — can bleed
  /// into the next word's field and make distinct transcripts collide.
  var transcriptHash: String {
    var hasher = SHA256()
    for word in words {
      let textBytes = Data(word.text.utf8)
      hasher.update(data: Data("\(word.id):\(textBytes.count):".utf8))
      hasher.update(data: textBytes)
    }
    let digest = hasher.finalize()
    return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }
}
