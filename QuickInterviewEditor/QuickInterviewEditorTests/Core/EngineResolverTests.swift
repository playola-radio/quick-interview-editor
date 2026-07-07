import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

/// Unit coverage for engine launch resolution: bundled helper first, dev `.venv`
/// fallback. Pure — the filesystem probe is injected, so nothing here touches
/// disk or spawns a subprocess.
struct EngineResolverTests {

  private let helper = URL(
    fileURLWithPath: "/App.app/Contents/Resources/engine/logic-markers-engine")
  private let filePathRepo = URL(fileURLWithPath: "/checkout/logic-utils")

  @Test func prefersBundledHelperWhenExecutable() {
    let launch = EngineResolver.resolve(
      bundledHelper: helper,
      repoRootOverride: nil,
      filePathRepoRoot: filePathRepo,
      isExecutable: { $0 == self.helper }
    )

    expectNoDifference(launch.executable, helper)
    expectNoDifference(launch.argumentPrefix, [])
    expectNoDifference(launch.isBundled, true)
    // Working dir is the engine folder alongside the helper (compare paths to
    // sidestep URL trailing-slash normalization).
    expectNoDifference(
      launch.workingDirectory.path,
      "/App.app/Contents/Resources/engine"
    )
  }

  @Test func bundledHelperArgumentsHaveNoModulePrefix() {
    let launch = EngineResolver.resolve(
      bundledHelper: helper,
      repoRootOverride: nil,
      filePathRepoRoot: filePathRepo,
      isExecutable: { _ in true }
    )

    expectNoDifference(
      launch.arguments(subcommand: "plan", ["/audio.m4a", "--work-dir", "/tmp/j"]),
      ["plan", "/audio.m4a", "--work-dir", "/tmp/j"]
    )
  }

  @Test func fallsBackToDevVenvWhenHelperMissing() {
    let launch = EngineResolver.resolve(
      bundledHelper: helper,
      repoRootOverride: nil,
      filePathRepoRoot: filePathRepo,
      isExecutable: { _ in false }  // nothing on disk
    )

    expectNoDifference(launch.isBundled, false)
    expectNoDifference(
      launch.executable,
      URL(fileURLWithPath: "/checkout/logic-utils/.venv/bin/python")
    )
    expectNoDifference(launch.argumentPrefix, ["-m", "logic_markers.cli"])
    expectNoDifference(launch.workingDirectory, filePathRepo)
  }

  @Test func fallsBackToDevWhenNoBundleResourceURL() {
    let launch = EngineResolver.resolve(
      bundledHelper: nil,  // no app resource URL
      repoRootOverride: nil,
      filePathRepoRoot: filePathRepo,
      isExecutable: { _ in true }
    )

    expectNoDifference(launch.isBundled, false)
    expectNoDifference(
      launch.executable,
      URL(fileURLWithPath: "/checkout/logic-utils/.venv/bin/python")
    )
  }

  @Test func envOverrideBeatsFilePathRepoRoot() {
    let launch = EngineResolver.resolve(
      bundledHelper: nil,
      repoRootOverride: "/custom/engine-repo",
      filePathRepoRoot: filePathRepo,
      isExecutable: { _ in false }
    )

    expectNoDifference(
      launch.executable,
      URL(fileURLWithPath: "/custom/engine-repo/.venv/bin/python")
    )
    expectNoDifference(launch.workingDirectory, URL(fileURLWithPath: "/custom/engine-repo"))
  }

  @Test func devArgumentsCarryTheModulePrefix() {
    let launch = EngineResolver.resolve(
      bundledHelper: nil,
      repoRootOverride: "/repo",
      filePathRepoRoot: filePathRepo,
      isExecutable: { _ in false }
    )

    expectNoDifference(
      launch.arguments(subcommand: "render", ["/a.m4a", "--request", "/r.json"]),
      ["-m", "logic_markers.cli", "render", "/a.m4a", "--request", "/r.json"]
    )
  }

  /// The bundled helper takes precedence over a `QIE_ENGINE_REPO` override — a
  /// packaged app should always run its own frozen engine, never a dev checkout.
  @Test func bundledHelperWinsEvenWithEnvOverride() {
    let launch = EngineResolver.resolve(
      bundledHelper: helper,
      repoRootOverride: "/custom/engine-repo",
      filePathRepoRoot: filePathRepo,
      isExecutable: { $0 == self.helper }
    )

    expectNoDifference(launch.isBundled, true)
    expectNoDifference(launch.executable, helper)
  }
}
