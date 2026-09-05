import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

/// Unit coverage for cut-suggester launch resolution: bundled helper first, dev
/// `.venv` fallback running `python -m cut_suggester.cli`. Pure — the filesystem
/// probe is injected, so nothing here touches disk or spawns a subprocess.
struct CutSuggesterResolverTests {

  private let helper = URL(
    fileURLWithPath: "/App.app/Contents/Resources/engine/cut-suggester-engine")
  private let filePathRepo = URL(fileURLWithPath: "/checkout/logic-utils")

  @Test func prefersBundledHelperWhenExecutable() {
    let launch = CutSuggesterResolver.resolve(
      bundledHelper: helper,
      repoRootOverride: nil,
      filePathRepoRoot: filePathRepo,
      isExecutable: { $0 == self.helper }
    )

    expectNoDifference(launch.executable, helper)
    expectNoDifference(launch.argumentPrefix, [])
    expectNoDifference(launch.isBundled, true)
    expectNoDifference(
      launch.workingDirectory.path, "/App.app/Contents/Resources/engine")
  }

  @Test func bundledHelperArgumentsHaveNoModulePrefix() {
    let launch = CutSuggesterResolver.resolve(
      bundledHelper: helper,
      repoRootOverride: nil,
      filePathRepoRoot: filePathRepo,
      isExecutable: { _ in true }
    )

    expectNoDifference(
      launch.arguments(subcommand: "suggest", ["--request", "/tmp/j/request.json"]),
      ["suggest", "--request", "/tmp/j/request.json"]
    )
  }

  @Test func fallsBackToDevVenvWithCutSuggesterModule() {
    let launch = CutSuggesterResolver.resolve(
      bundledHelper: helper,
      repoRootOverride: nil,
      filePathRepoRoot: filePathRepo,
      isExecutable: { _ in false }  // nothing on disk
    )

    expectNoDifference(launch.isBundled, false)
    expectNoDifference(
      launch.executable, URL(fileURLWithPath: "/checkout/logic-utils/.venv/bin/python"))
    expectNoDifference(launch.argumentPrefix, ["-m", "cut_suggester.cli"])
    expectNoDifference(launch.workingDirectory, filePathRepo)
  }

  @Test func devArgumentsCarryTheModulePrefix() {
    let launch = CutSuggesterResolver.resolve(
      bundledHelper: nil,
      repoRootOverride: "/repo",
      filePathRepoRoot: filePathRepo,
      isExecutable: { _ in false }
    )

    expectNoDifference(
      launch.arguments(subcommand: "suggest", ["--request", "/r.json", "--cache-dir", "/c"]),
      ["-m", "cut_suggester.cli", "suggest", "--request", "/r.json", "--cache-dir", "/c"]
    )
  }

  @Test func envOverrideBeatsFilePathRepoRoot() {
    let launch = CutSuggesterResolver.resolve(
      bundledHelper: nil,
      repoRootOverride: "/custom/engine-repo",
      filePathRepoRoot: filePathRepo,
      isExecutable: { _ in false }
    )

    expectNoDifference(
      launch.executable, URL(fileURLWithPath: "/custom/engine-repo/.venv/bin/python"))
    expectNoDifference(launch.workingDirectory, URL(fileURLWithPath: "/custom/engine-repo"))
  }

  /// A packaged app must always run its own frozen helper, never a dev checkout.
  @Test func bundledHelperWinsEvenWithEnvOverride() {
    let launch = CutSuggesterResolver.resolve(
      bundledHelper: helper,
      repoRootOverride: "/custom/engine-repo",
      filePathRepoRoot: filePathRepo,
      isExecutable: { $0 == self.helper }
    )

    expectNoDifference(launch.isBundled, true)
    expectNoDifference(launch.executable, helper)
  }
}
