import Foundation

// MARK: - EngineLaunch

/// How to launch the Python engine for one job: which executable to spawn and
/// the arguments that must precede the CLI subcommand.
///
/// The **packaged** app runs a self-contained frozen helper
/// (`logic-markers-engine plan …`) with no prefix. **Dev** runs the engine as a
/// module through the `.venv` python (`python -m logic_markers.cli plan …`).
/// Everything else (the subcommand and its args) is identical, so callers append
/// it via ``arguments(subcommand:_:)``.
struct EngineLaunch: Equatable, Sendable {
  /// The binary to spawn (the frozen helper, or the dev `.venv` python).
  var executable: URL
  /// Args before the subcommand: `[]` bundled, `["-m", "logic_markers.cli"]` dev.
  var argumentPrefix: [String]
  /// Child working directory. Dev: the repo root (so `logic_markers` is importable
  /// via `PYTHONPATH`). Bundled: the engine folder.
  var workingDirectory: URL
  /// True when running the packaged frozen helper (no dev `.venv` involved).
  var isBundled: Bool
  /// Extra env for the child (e.g. the `QIE_*` model dirs for the bundled helper).
  /// Empty in dev, where the engine falls back to its default caches.
  var environment: [String: String] = [:]

  /// The full argument vector (after the executable) for a CLI subcommand.
  func arguments(subcommand: String, _ rest: [String]) -> [String] {
    argumentPrefix + [subcommand] + rest
  }
}

// MARK: - EngineResolver

/// Resolves how to launch the engine: the **bundled frozen helper first**, then
/// the **dev `.venv` fallback**. Keeping this a pure function with an injected
/// filesystem probe lets it be unit-tested without spawning a subprocess or
/// touching disk (see `EngineResolverTests`).
enum EngineResolver {

  /// - Parameters:
  ///   - bundledHelper: candidate path to the packaged helper
  ///     (`…/Resources/engine/logic-markers-engine`), or `nil` if the app has no
  ///     resource URL.
  ///   - repoRootOverride: `QIE_ENGINE_REPO` — forces the dev repo root when set.
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

    // 2. Dev fallback: `python -m logic_markers.cli` from the resolved repo root.
    //    An explicit `QIE_ENGINE_REPO` beats the `#filePath`-derived guess, which
    //    Xcode can remap unreliably.
    let repoRoot =
      repoRootOverride.map { URL(fileURLWithPath: $0) } ?? filePathRepoRoot
    return EngineLaunch(
      executable: repoRoot.appendingPathComponent(".venv/bin/python"),
      argumentPrefix: ["-m", "logic_markers.cli"],
      workingDirectory: repoRoot,
      isBundled: false
    )
  }
}
