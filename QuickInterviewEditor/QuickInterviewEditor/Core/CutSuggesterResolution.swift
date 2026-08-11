import Foundation

// MARK: - CutSuggesterResolver

/// Resolves how to launch the Python `cut_suggester` for one suggestion run — the
/// bundled frozen helper first, then the dev `.venv` fallback.
///
/// Deliberately a small parallel of ``EngineResolver`` rather than a generalization
/// of it: the two share the `EngineLaunch` shape, but the cutter has its own module
/// (`cut_suggester.cli`), its own (eventual) frozen helper, and different env / auth /
/// cache concerns. Keeping them separate keeps each pure and unit-testable without
/// smearing engine and cutter assumptions together.
///
/// - Note: The frozen `cut-suggester-engine` helper (bundling `cut_suggester` + the
///   provider SDK) is **not built yet** — that packaging is a tracked follow-up. Today
///   only the dev path runs; the bundled branch is a ready seam so wiring the frozen
///   helper later is a one-line resource drop, no call-site change.
enum CutSuggesterResolver {

  /// - Parameters:
  ///   - bundledHelper: candidate path to the packaged helper
  ///     (`…/Resources/engine/cut-suggester-engine`), or `nil` when the app has no
  ///     resource URL.
  ///   - repoRootOverride: `QIE_ENGINE_REPO` — forces the dev repo root when set (the
  ///     same override the engine honors, so a moved/renamed checkout resolves once).
  ///   - filePathRepoRoot: repo root derived from `#filePath` (dev default).
  ///   - isExecutable: filesystem probe (injected in tests).
  static func resolve(
    bundledHelper: URL?,
    repoRootOverride: String?,
    filePathRepoRoot: URL,
    isExecutable: (URL) -> Bool
  ) -> EngineLaunch {
    // 1. Packaged helper wins whenever it's present and runnable.
    if let helper = bundledHelper, isExecutable(helper) {
      return EngineLaunch(
        executable: helper,
        argumentPrefix: [],
        workingDirectory: helper.deletingLastPathComponent(),
        isBundled: true
      )
    }

    // 2. Dev fallback: `python -m cut_suggester.cli` from the resolved repo root.
    let repoRoot =
      repoRootOverride.map { URL(fileURLWithPath: $0) } ?? filePathRepoRoot
    return EngineLaunch(
      executable: repoRoot.appendingPathComponent(".venv/bin/python"),
      argumentPrefix: ["-m", "cut_suggester.cli"],
      workingDirectory: repoRoot,
      isBundled: false
    )
  }
}
