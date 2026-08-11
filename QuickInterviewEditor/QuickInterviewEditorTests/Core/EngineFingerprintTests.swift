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
    #expect(one == two)
  }

  @Test func bundledFingerprintHashesTheBinary() {
    let launch = EngineLaunch(
      executable: URL(fileURLWithPath: "/app/engine/logic-markers-engine"),
      argumentPrefix: [], workingDirectory: URL(fileURLWithPath: "/app/engine"), isBundled: true)
    let value = EngineFingerprint.compute(
      launch: launch, pythonFiles: { _ in [] }, contentHash: { _ in "binhash" })
    #expect(value == "engine:bin:binhash")
  }
}
