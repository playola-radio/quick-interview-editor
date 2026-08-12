import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

@Suite struct EngineFingerprintTests {
  private func devLaunch(root: URL) -> EngineLaunch {
    EngineLaunch(
      executable: root.appendingPathComponent(".venv/bin/python"),
      argumentPrefix: ["-m", "logic_markers.cli"],
      workingDirectory: root, isBundled: false)
  }

  @Test func devFingerprintCoversPythonSourcesAndPins() {
    let root = URL(fileURLWithPath: "/repo")
    let fileA = root.appendingPathComponent("logic_markers/cli.py")
    let fileB = root.appendingPathComponent("logic_markers/whisperx_backend.py")
    var contents = [
      fileA.path: "h1", fileB.path: "h2",
      root.appendingPathComponent("requirements.txt").path: "r1",
    ]

    let first = EngineFingerprint.compute(
      launch: devLaunch(root: root),
      pythonFiles: { _ in [fileB, fileA] },  // unsorted on purpose
      contentHash: { contents[$0.path] })

    // Changing a source file changes the fingerprint.
    contents[fileA.path] = "h1-modified"
    let second = EngineFingerprint.compute(
      launch: devLaunch(root: root),
      pythonFiles: { _ in [fileA, fileB] },
      contentHash: { contents[$0.path] })

    #expect(first.hasPrefix("engine:src:"))
    #expect(first != second)
  }

  @Test func devFingerprintIsStableRegardlessOfFileOrder() {
    let root = URL(fileURLWithPath: "/repo")
    let fileA = root.appendingPathComponent("logic_markers/a.py")
    let fileB = root.appendingPathComponent("logic_markers/b.py")
    let contents = [fileA.path: "ha", fileB.path: "hb"]
    let one = EngineFingerprint.compute(
      launch: devLaunch(root: root), pythonFiles: { _ in [fileA, fileB] },
      contentHash: { contents[$0.path] })
    let two = EngineFingerprint.compute(
      launch: devLaunch(root: root), pythonFiles: { _ in [fileB, fileA] },
      contentHash: { contents[$0.path] })
    expectNoDifference(one, two)
  }

  private func bundledLaunch() -> EngineLaunch {
    EngineLaunch(
      executable: URL(fileURLWithPath: "/app/engine/logic-markers-engine"),
      argumentPrefix: [], workingDirectory: URL(fileURLWithPath: "/app/engine"), isBundled: true)
  }

  @Test func bundledFingerprintReflectsEngineTreeNotJustLauncher() {
    let launch = bundledLaunch()
    // A same-path content change (identity differs) must change the fingerprint —
    // exactly the "same path & size" case that a size-only digest would miss.
    let baseTree: [(relativePath: String, identity: String)] = [
      (relativePath: "_internal/logic_markers/cli.py", identity: "h:aaa"),
      (relativePath: "_internal/libtorch.dylib", identity: "s:50000000"),
    ]
    let changedTree: [(relativePath: String, identity: String)] = [
      (relativePath: "_internal/logic_markers/cli.py", identity: "h:bbb"),
      (relativePath: "_internal/libtorch.dylib", identity: "s:50000000"),
    ]

    let first = EngineFingerprint.compute(
      launch: launch,
      pythonFiles: { _ in [] },
      contentHash: { _ in "launcherhash" },
      engineTree: { _ in baseTree },
      modelIdentity: "v1:abc",
      appVersion: "1.0-100")
    let second = EngineFingerprint.compute(
      launch: launch,
      pythonFiles: { _ in [] },
      contentHash: { _ in "launcherhash" },
      engineTree: { _ in changedTree },
      modelIdentity: "v1:abc",
      appVersion: "1.0-100")

    #expect(first != second)
  }

  @Test func bundledFingerprintChangesWithModelManifest() {
    let launch = bundledLaunch()
    let tree: [(relativePath: String, identity: String)] = [
      (relativePath: "_internal/logic_markers/cli.py", identity: "h:aaa")
    ]

    let first = EngineFingerprint.compute(
      launch: launch,
      pythonFiles: { _ in [] },
      contentHash: { _ in "launcherhash" },
      engineTree: { _ in tree },
      modelIdentity: "v1:abc",
      appVersion: "1.0-100")
    let second = EngineFingerprint.compute(
      launch: launch,
      pythonFiles: { _ in [] },
      contentHash: { _ in "launcherhash" },
      engineTree: { _ in tree },
      modelIdentity: "v2:xyz",
      appVersion: "1.0-100")

    #expect(first != second)
  }

  @Test func bundledFingerprintChangesWithAppVersion() {
    let launch = bundledLaunch()
    let tree: [(relativePath: String, identity: String)] = [
      (relativePath: "_internal/logic_markers/cli.py", identity: "h:aaa")
    ]

    let first = EngineFingerprint.compute(
      launch: launch,
      pythonFiles: { _ in [] },
      contentHash: { _ in "launcherhash" },
      engineTree: { _ in tree },
      modelIdentity: "v1:abc",
      appVersion: "1.0-100")
    let second = EngineFingerprint.compute(
      launch: launch,
      pythonFiles: { _ in [] },
      contentHash: { _ in "launcherhash" },
      engineTree: { _ in tree },
      modelIdentity: "v1:abc",
      appVersion: "1.1-101")

    #expect(first != second)
  }

  @Test func bundledFingerprintStableForIdenticalInputs() {
    let launch = bundledLaunch()
    let treeInOrderA: [(relativePath: String, identity: String)] = [
      (relativePath: "_internal/logic_markers/cli.py", identity: "h:aaa"),
      (relativePath: "_internal/libtorch.dylib", identity: "s:50000000"),
    ]
    let treeInOrderB: [(relativePath: String, identity: String)] = [
      (relativePath: "_internal/libtorch.dylib", identity: "s:50000000"),
      (relativePath: "_internal/logic_markers/cli.py", identity: "h:aaa"),
    ]

    let first = EngineFingerprint.compute(
      launch: launch,
      pythonFiles: { _ in [] },
      contentHash: { _ in "launcherhash" },
      engineTree: { _ in treeInOrderA },
      modelIdentity: "v1:abc",
      appVersion: "1.0-100")
    let second = EngineFingerprint.compute(
      launch: launch,
      pythonFiles: { _ in [] },
      contentHash: { _ in "launcherhash" },
      engineTree: { _ in treeInOrderB },
      modelIdentity: "v1:abc",
      appVersion: "1.0-100")

    expectNoDifference(first, second)
    #expect(first.hasPrefix("engine:bin:"))
  }

  @Test func currentIsMemoizedOncePerProcess() {
    let launch = EngineLaunch(
      executable: URL(fileURLWithPath: "/app/engine/logic-markers-engine"),
      argumentPrefix: [], workingDirectory: URL(fileURLWithPath: "/app/engine"), isBundled: true)
    let first = EngineFingerprint.current(launch: launch)
    let second = EngineFingerprint.current(launch: launch)
    expectNoDifference(first, second)
  }

  @Test func devFingerprintChangesWhenAPinFileChanges() {
    let root = URL(fileURLWithPath: "/repo")
    let file = root.appendingPathComponent("logic_markers/cli.py")
    let pin = root.appendingPathComponent("requirements.txt")
    var contents = [file.path: "h1", pin.path: "r1"]

    let first = EngineFingerprint.compute(
      launch: devLaunch(root: root),
      pythonFiles: { _ in [file] },
      contentHash: { contents[$0.path] })

    // Changing a pin file (not a .py source) changes the fingerprint.
    contents[pin.path] = "r1-modified"
    let second = EngineFingerprint.compute(
      launch: devLaunch(root: root),
      pythonFiles: { _ in [file] },
      contentHash: { contents[$0.path] })

    #expect(first != second)
  }
}
