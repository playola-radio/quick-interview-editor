import Dependencies
import Foundation

/// The one sanctioned path for reading a `.pie` package's audio by URL (spec A5): clones the
/// bundled `audio/canonical.aiff` into a fresh `CanonicalAudioStore` session dir so the editor
/// never plays, draws, or renders from inside the document package itself. The copy is an APFS
/// clone via `FileManager.copyItem`, so it is instant and shares blocks until either side changes.
struct CanonicalAudioStoreClient: Sendable {
  /// Copies the AIFF at the given URL into a new per-session dir and returns the copy's URL.
  var clone: @Sendable (URL) async throws -> URL
}

extension CanonicalAudioStoreClient: DependencyKey {
  static var liveValue: CanonicalAudioStoreClient {
    CanonicalAudioStoreClient(clone: { source in
      try await Task.detached(priority: .userInitiated) {
        try CanonicalAudioStore.store(planAIFF: source)
      }.value
    })
  }
}

extension CanonicalAudioStoreClient: TestDependencyKey {
  static var testValue: CanonicalAudioStoreClient {
    CanonicalAudioStoreClient(clone: { _ in
      throw EngineClientError.unimplemented("CanonicalAudioStoreClient.clone")
    })
  }
}

extension DependencyValues {
  var canonicalAudioStore: CanonicalAudioStoreClient {
    get { self[CanonicalAudioStoreClient.self] }
    set { self[CanonicalAudioStoreClient.self] = newValue }
  }
}
