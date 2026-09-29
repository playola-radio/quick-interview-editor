import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import Testing

@testable import PlayolaInterviewEditor

// swiftlint:disable inclusive_language

private actor CapturedMasterTarget {
  var value: MasteredPartTarget?
  func set(_ target: MasteredPartTarget) { value = target }
}

actor CancellationGate {
  private var started = false
  private var cancelled = false
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var cancelWaiter: CheckedContinuation<Void, Never>?

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiter = $0 }
  }
  func waitForCancellation() async {
    started = true
    startWaiter?.resume()
    startWaiter = nil
    if !cancelled { await withCheckedContinuation { cancelWaiter = $0 } }
  }
  func cancel() {
    cancelled = true
    cancelWaiter?.resume()
    cancelWaiter = nil
  }
}

private actor SuspendedReturn {
  private var started = false
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?
  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiter = $0 }
  }
  func suspend() async {
    started = true
    startWaiter?.resume()
    startWaiter = nil
    await withCheckedContinuation { releaseWaiter = $0 }
  }
  func release() {
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}

@MainActor
struct MasteringPageTests {
  private func drop(_ urls: [URL], onto model: MasteringPageModel) async throws {
    let providers = try urls.map { try #require(NSItemProvider(contentsOf: $0)) }
    let task = try #require(model.providersDropped(providers))
    await task.value
  }
  private func run(returned: Bool = false) -> MasteringRun {
    .init(
      id: Fixtures.uuid(70), artist: "Frozen Artist", inputsDigest: "digest",
      parts: [
        .init(
          id: Fixtures.uuid(71), frameCount: 44_100, prepared: nil,
          pieces: [
            .init(
              id: Fixtures.uuid(72), sliceID: Fixtures.uuid(73), title: "Frozen Title",
              startFrame: 0, frameCount: 44_100, lrc: "[00:00.00]Hello",
              finished: returned
                ? .init(fileName: Fixtures.uuid(20).uuidString.lowercased() + ".m4a", byteCount: 4)
                : nil)
          ])
      ])
  }

  @Test func existingRunRequiresConfirmationBeforeAudioPreparation() async {
    let current = run()
    let model = MasteringPageModel(
      host: .init(
        finishTitleEdit: {},
        inputs: {
          .success(
            .init(
              artist: "Artist", canonicalAudioURL: URL(fileURLWithPath: "/tmp/audio"),
              canonicalFingerprint: "sha256:test", sourceSampleRate: 44_100,
              sourceDurationSamples: 44_100, pieces: [], inputsDigest: "digest"))
        },
        eligibility: { nil }, run: { current }, packageURL: { nil }, artifact: { _ in nil },
        commit: { _, _, _ in
          Issue.record("Committed before confirmation")
          return false
        }))
    await model.prepareTapped()
    #expect(model.confirmingPrepareAgain)
    expectNoDifference(model.run, current)
  }

  @Test func destinationCancelDoesNotCreateDirectory() throws {
    let current = run(returned: true)
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1, 2, 3, 4]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let owner = try MasteringStagingStore.copy(
      source, as: current.parts[0].pieces[0].finished!.fileName)
    let model = withDependencies {
      $0.workspace.createDirectory = { _ in Issue.record("Created cancelled directory") }
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(.notLoaded) },
          eligibility: { nil }, run: { current },
          packageURL: { URL(fileURLWithPath: "/tmp/interview.pie") },
          artifact: { _ in owner }, commit: { _, _, _ in false }))
    }
    model.saveFinalsTapped()
    expectNoDifference(model.destinationPrompt?.suggested.path, "/tmp/mastered")
    model.destinationCancelTapped()
    #expect(model.destinationPrompt == nil)
  }

  @Test func staleNoticeIsPure() {
    let current = run()
    var edits = 0
    let model = MasteringPageModel(
      host: .init(
        finishTitleEdit: { edits += 1 }, inputs: { .failure(.pendingEdit) },
        eligibility: { nil }, run: { current }, packageURL: { nil }, artifact: { _ in nil },
        commit: { _, _, _ in false }))
    #expect(model.showsStaleNotice)
    expectNoDifference(edits, 0)
  }

  @Test func missingSavedArtifactIsUnavailableInsteadOfReady() {
    let current = run(returned: true)
    let model = MasteringPageModel(
      host: .init(
        finishTitleEdit: {}, inputs: { .failure(.notLoaded) }, eligibility: { nil },
        run: { current }, packageURL: { URL(fileURLWithPath: "/tmp/interview.pie") },
        artifact: { _ in nil }, commit: { _, _, _ in false },
        stagingError: { "Disk was full while staging." }))
    expectNoDifference(model.rows[0].status, "0:01 · unavailable")
    #expect(!model.canSave)
    model.saveFinalsTapped()
    #expect(model.message?.contains("Disk was full") == true)
  }

  @Test func filenameReviewBlocksAnotherPreparation() async {
    let model = MasteringPageModel(
      host: .init(
        finishTitleEdit: { Issue.record("Preparation started during filename review") },
        inputs: { .failure(.notLoaded) }, eligibility: { nil }, run: { nil },
        packageURL: { nil }, artifact: { _ in nil }, commit: { _, _, _ in false }))
    model.exportReview = ExportReviewModel(
      request: .init(
        targets: [], sourceStem: "",
        renderedByID: [:], destination: URL(fileURLWithPath: "/tmp"),
        kind: .masteredM4A), scratchDirectory: nil)
    await model.prepareTapped()
    expectNoDifference(model.message, "Wait for the current step to finish.")
  }

  @Test func corruptPreparedAudioCannotBeDragged() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1, 2, 3, 4]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    var current = run()
    let ref = MasteringArtifactRef(
      fileName: Fixtures.uuid(21).uuidString.lowercased() + ".wav", byteCount: 4)
    current.parts[0].prepared = ref
    let owner = try MasteringStagingStore.copy(source, as: ref.fileName)
    let model = withDependencies {
      $0.masteringArtifactValidation = .liveValue
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(.notLoaded) }, eligibility: { nil },
          run: { current }, packageURL: { URL(fileURLWithPath: "/tmp/interview.pie") },
          artifact: { _ in owner }, commit: { _, _, _ in false }))
    }
    let url = await model.dragURL(for: current.parts[0].id)
    #expect(url == nil)
    expectNoDifference(model.message, model.corruptMessage)
  }

  @Test func failedReturnDoesNotCommitPart() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".wav")
    try Data([1, 2, 3, 4]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let current = run()
    var commits = 0
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.masteringStaging = .liveValue
      $0.masteringReturn = .init(
        inspect: { url in
          .init(
            fileName: url.lastPathComponent, sampleRate: 44_100, channels: 2,
            sourceFrames: 44_100)
        },
        encodePart: { _, _, _ in
          throw MasteringReturnError.encodeFailed(
            title: "Frozen Title", reason: "second piece failed")
        })
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(.notLoaded) },
          eligibility: { nil }, run: { current }, packageURL: { nil }, artifact: { _ in nil },
          commit: { _, _, _ in
            commits += 1
            return true
          }))
    }
    try await drop([source], onto: model)
    expectNoDifference(commits, 0)
    #expect(model.message?.contains("second piece failed") == true)
    #expect(!current.parts[0].isReturned)
  }

  @Test func returnedPartUsesFrozenMetadataAndFreshArtifactName() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".wav")
    try Data([1, 2, 3, 4]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let capture = CapturedMasterTarget()
    var current = run()
    let original = current
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.masteringStaging = .liveValue
      $0.masteringReturn = .init(
        inspect: { url in
          .init(
            fileName: url.lastPathComponent, sampleRate: 44_100, channels: 2,
            sourceFrames: 44_100)
        },
        encodePart: { _, target, work in
          await capture.set(target)
          let url = work.appendingPathComponent("encoded.m4a")
          try Data([1, 2, 3, 4]).write(to: url)
          return [.init(pieceID: target.pieces[0].pieceID, url: url, byteCount: 4)]
        })
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(.notLoaded) },
          eligibility: { nil }, run: { current }, packageURL: { nil }, artifact: { _ in nil },
          commit: { next, _, expected in
            #expect(expected == current.id)
            current = next
            return true
          }))
    }
    try await drop([source], onto: model)
    let target = await capture.value
    expectNoDifference(target?.pieces[0].artist, "Frozen Artist")
    expectNoDifference(target?.pieces[0].title, "Frozen Title")
    expectNoDifference(target?.pieces[0].lrc, "[00:00.00]Hello")
    expectNoDifference(target?.pieces[0].frameCount, 44_100)
    #expect(current.parts[0].isReturned)
    #expect(current.parts[0].pieces[0].finished?.fileName.hasSuffix(".m4a") == true)
    expectNoDifference(current.parts[0].prepared, original.parts[0].prepared)
  }

  @Test func supersededRunCannotCommitAnEncodedReturn() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".wav")
    try Data([1, 2, 3, 4]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let gate = SuspendedReturn()
    let output = LockIsolated<URL?>(nil)
    var current = run()
    let commits = LockIsolated(0)
    let model = withDependencies {
      $0.masteringStaging = .liveValue
      $0.masteringReturn = .init(
        inspect: { url in
          .init(
            fileName: url.lastPathComponent, sampleRate: 44_100, channels: 2,
            sourceFrames: 44_100)
        },
        encodePart: { _, target, work in
          let file = work.appendingPathComponent("encoded.m4a")
          try Data([1, 2, 3, 4]).write(to: file)
          output.setValue(file)
          await gate.suspend()
          return [.init(pieceID: target.pieces[0].pieceID, url: file, byteCount: 4)]
        })
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(.notLoaded) }, eligibility: { nil },
          run: { current }, packageURL: { nil }, artifact: { _ in nil },
          commit: { _, _, _ in
            commits.withValue { $0 += 1 }
            return true
          }))
    }
    let dropping = Task { try await drop([source], onto: model) }
    await gate.waitUntilStarted()
    current.id = Fixtures.uuid(99)
    await gate.release()
    try await dropping.value
    expectNoDifference(commits.value, 0)
    let path = try #require(output.value)
    #expect(!FileManager.default.fileExists(atPath: path.path))
  }

  @Test func ambiguousReturnHoldsBatchAndRejectsConcurrentDrop() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".wav")
    try Data([1, 2, 3, 4]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    var current = run()
    var second = current.parts[0]
    second.id = Fixtures.uuid(81)
    second.pieces[0].id = Fixtures.uuid(82)
    current.parts.append(second)
    let model = withDependencies {
      $0.masteringStaging = .liveValue
      $0.masteringReturn = .init(
        inspect: { url in
          .init(
            fileName: url.lastPathComponent, sampleRate: 44_100, channels: 2,
            sourceFrames: 44_100)
        },
        encodePart: { _, _, _ in
          Issue.record("Ambiguous return encoded without a choice")
          return []
        })
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(.notLoaded) },
          eligibility: { nil }, run: { current }, packageURL: { nil }, artifact: { _ in nil },
          commit: { _, _, _ in false }))
    }
    try await drop([source], onto: model)
    expectNoDifference(
      model.ambiguousReturn?.candidatePartIDs,
      [Fixtures.uuid(71), Fixtures.uuid(81)])
    #expect(model.providersDropped([try #require(NSItemProvider(contentsOf: source))]) == nil)
    expectNoDifference(model.message, "Wait for the current step to finish.")
    model.ambiguousReturnCancelled()
  }

  @Test func ambiguityChoicesIncludeEachCandidatesDuration() {
    var current = run()
    var second = current.parts[0]
    second.id = Fixtures.uuid(81)
    second.frameCount = 44_100 * 65
    current.parts.append(second)
    let model = MasteringPageModel(
      host: .init(
        finishTitleEdit: {}, inputs: { .failure(.notLoaded) },
        eligibility: { nil }, run: { current }, packageURL: { nil }, artifact: { _ in nil },
        commit: { _, _, _ in false }))
    model.ambiguousReturn = .init(candidatePartIDs: [Fixtures.uuid(71), Fixtures.uuid(81)])
    expectNoDifference(
      model.ambiguityChoices.map(\.title), ["Part 1 (0:01)", "Part 2 (1:05)"])
  }

  @Test func choosingAmbiguousPartResumesRemainingDropInOrder() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sources = ["first.wav", "second.wav"].map { directory.appendingPathComponent($0) }
    for source in sources { try Data([1, 2, 3, 4]).write(to: source) }
    var current = run()
    var second = current.parts[0]
    second.id = Fixtures.uuid(81)
    second.pieces[0].id = Fixtures.uuid(82)
    current.parts.append(second)
    let encodedNames = LockIsolated<[String]>([])
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.masteringStaging = .liveValue
      $0.masteringReturn = .init(
        inspect: { url in
          .init(
            fileName: url.lastPathComponent, sampleRate: 44_100, channels: 2,
            sourceFrames: 44_100)
        },
        encodePart: { url, target, work in
          encodedNames.withValue { $0.append(url.lastPathComponent) }
          let output = work.appendingPathComponent("encoded.m4a")
          try Data([1, 2, 3, 4]).write(to: output)
          return [.init(pieceID: target.pieces[0].pieceID, url: output, byteCount: 4)]
        })
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(.notLoaded) }, eligibility: { nil },
          run: { current }, packageURL: { nil }, artifact: { _ in nil },
          commit: { next, _, _ in
            current = next
            return true
          }))
    }
    try await drop(sources, onto: model)
    #expect(model.ambiguousReturn != nil)
    await model.ambiguousChoiceTapped(current.parts[0].id)
    let allReturned = current.parts.allSatisfy { $0.isReturned }
    #expect(allReturned)
    expectNoDifference(encodedNames.value, ["first.wav", "second.wav"])
  }

  @Test func selectedDestinationIsCreatedOnceAndFinalIsCopied() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let current = run(returned: true)
    let source = directory.appendingPathComponent("source.m4a")
    try Data([1, 2, 3, 4]).write(to: source)
    let owner = try MasteringStagingStore.copy(
      source, as: current.parts[0].pieces[0].finished!.fileName)
    let created = LockIsolated<[URL]>([])
    let model = withDependencies {
      $0.masteringStaging = .liveValue
      $0.workspace.createDirectory = { url in
        created.withValue { $0.append(url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      }
      $0.exportCopy = .liveValue
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(.notLoaded) }, eligibility: { nil },
          run: { current }, packageURL: { directory.appendingPathComponent("interview.pie") },
          artifact: { _ in owner }, commit: { _, _, _ in false }))
    }
    model.saveFinalsTapped()
    await model.destinationSaveSelected()
    expectNoDifference(
      created.value.map(\.path), [directory.appendingPathComponent("mastered").path])
    expectNoDifference(model.savedFiles.map(\.lastPathComponent), ["Frozen Title.m4a"])
    #expect(FileManager.default.fileExists(atPath: model.savedFiles[0].path))
  }

  @Test func partialSaveRetriesOnlyTheRemainingFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var current = run(returned: true)
    var second = current.parts[0].pieces[0]
    second.id = Fixtures.uuid(83)
    second.title = "Second Title"
    second.finished = .init(
      fileName: Fixtures.uuid(84).uuidString.lowercased() + ".m4a", byteCount: 4)
    current.parts[0].pieces.append(second)
    let refs = try Dictionary(
      uniqueKeysWithValues: current.parts[0].pieces.map { piece in
        let source = directory.appendingPathComponent(piece.title + ".m4a")
        try Data([1, 2, 3, 4]).write(to: source)
        let ref = try #require(piece.finished)
        return (ref.fileName, try MasteringStagingStore.copy(source, as: ref.fileName))
      })
    let attempts = LockIsolated<[String]>([])
    let model = withDependencies {
      $0.masteringStaging = .liveValue
      $0.workspace.createDirectory = {
        try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
      }
      $0.exportCopy = .init(
        listNames: ExportCopyClient.liveValue.listNames,
        copy: { source, target in
          let shouldFail = attempts.withValue { names -> Bool in
            names.append(target.lastPathComponent)
            return target.lastPathComponent == "Second Title.m4a" && names.count == 2
          }
          if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
          try FileManager.default.copyItem(at: source, to: target)
        })
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(.notLoaded) }, eligibility: { nil },
          run: { current }, packageURL: { directory.appendingPathComponent("interview.pie") },
          artifact: { refs[$0.fileName] }, commit: { _, _, _ in false }))
    }
    model.saveFinalsTapped()
    await model.destinationSaveSelected()
    expectNoDifference(model.savedFiles.map(\.lastPathComponent), ["Frozen Title.m4a"])
    model.saveFinalsTapped()
    await model.destinationSaveSelected()
    expectNoDifference(
      attempts.value, ["Frozen Title.m4a", "Second Title.m4a", "Second Title.m4a"])
    expectNoDifference(
      Set(model.savedFiles.map(\.lastPathComponent)),
      Set(["Frozen Title.m4a", "Second Title.m4a"]))
  }

  // swiftlint:disable function_body_length
  @Test func cancelledSaveRetainsCopiedFilesForRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var current = run(returned: true)
    var second = current.parts[0].pieces[0]
    second.id = Fixtures.uuid(85)
    second.title = "Second Title"
    second.finished = .init(
      fileName: Fixtures.uuid(86).uuidString.lowercased() + ".m4a", byteCount: 4)
    current.parts[0].pieces.append(second)
    let refs = try Dictionary(
      uniqueKeysWithValues: current.parts[0].pieces.map { piece in
        let source = directory.appendingPathComponent(piece.title + ".m4a")
        try Data([1, 2, 3, 4]).write(to: source)
        let ref = try #require(piece.finished)
        return (ref.fileName, try MasteringStagingStore.copy(source, as: ref.fileName))
      })
    let gate = CancellationGate()
    let attempts = LockIsolated<[String]>([])
    let model = withDependencies {
      $0.masteringStaging = .liveValue
      $0.workspace.createDirectory = {
        try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
      }
      $0.exportCopy = .init(
        listNames: ExportCopyClient.liveValue.listNames,
        copy: { source, target in
          let isFirstSecond = attempts.withValue { names -> Bool in
            names.append(target.lastPathComponent)
            return names.count == 2
          }
          if isFirstSecond {
            await withTaskCancellationHandler {
              await gate.waitForCancellation()
            } onCancel: {
              Task { await gate.cancel() }
            }
            throw CancellationError()
          }
          try FileManager.default.copyItem(at: source, to: target)
        })
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(.notLoaded) }, eligibility: { nil },
          run: { current }, packageURL: { directory.appendingPathComponent("interview.pie") },
          artifact: { refs[$0.fileName] }, commit: { _, _, _ in false }))
    }
    model.saveFinalsTapped()
    let save = Task { await model.destinationSaveSelected() }
    await gate.waitUntilStarted()
    await model.cancelTapped()
    await save.value
    expectNoDifference(model.savedFiles.map(\.lastPathComponent), ["Frozen Title.m4a"])
    expectNoDifference(model.message, "Save cancelled. Files already copied remain.")
    model.saveFinalsTapped()
    await model.destinationSaveSelected()
    expectNoDifference(
      attempts.value, ["Frozen Title.m4a", "Second Title.m4a", "Second Title.m4a"])
    expectNoDifference(
      Set(model.savedFiles.map(\.lastPathComponent)),
      Set(["Frozen Title.m4a", "Second Title.m4a"]))
  }
  // swiftlint:enable function_body_length

  @Test func abandoningFilenameReviewReleasesStagedCopiesForAFreshSave() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let mastered = directory.appendingPathComponent("mastered")
    try FileManager.default.createDirectory(at: mastered, withIntermediateDirectories: true)
    try Data([1, 2, 3, 4]).write(to: mastered.appendingPathComponent("Frozen Title.m4a"))
    let current = run(returned: true)
    let source = directory.appendingPathComponent("source.m4a")
    try Data([1, 2, 3, 4]).write(to: source)
    let owner = try MasteringStagingStore.copy(
      source, as: current.parts[0].pieces[0].finished!.fileName)
    let model = withDependencies {
      $0.masteringStaging = .liveValue
      $0.workspace.createDirectory = {
        try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
      }
      $0.exportCopy = .liveValue
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(.notLoaded) }, eligibility: { nil },
          run: { current }, packageURL: { directory.appendingPathComponent("interview.pie") },
          artifact: { _ in owner }, commit: { _, _, _ in false }))
    }
    model.saveFinalsTapped()
    await model.destinationSaveSelected()
    #expect(model.exportReview != nil)
    model.exportReview?.reviewNamesTapped()
    await Task.yield()
    #expect(model.exportReview == nil)
    #expect(model.savedFiles.isEmpty)
    // A fresh save must re-stage from the source artifact rather than silently reuse the
    // abandoned review's `saveOwners` — proven by seeing the same collision surface again,
    // not by finding stale state already "saved".
    model.saveFinalsTapped()
    await model.destinationSaveSelected()
    #expect(model.exportReview != nil)
    expectNoDifference(
      model.exportReview?.mappings.first?.proposedName, "Frozen Title 2.m4a")
  }

  @Test func replacingReturnedPartUsesFreshArtifactName() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".wav")
    try Data([1, 2, 3, 4]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    var current = run(returned: true)
    let previous = current.parts[0].pieces[0].finished
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.masteringStaging = .liveValue
      $0.masteringReturn = .init(
        inspect: { url in
          .init(
            fileName: url.lastPathComponent, sampleRate: 44_100, channels: 2,
            sourceFrames: 44_100)
        },
        encodePart: { _, target, work in
          let output = work.appendingPathComponent("encoded.m4a")
          try Data([1, 2, 3, 4]).write(to: output)
          return [.init(pieceID: target.pieces[0].pieceID, url: output, byteCount: 4)]
        })
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(.notLoaded) }, eligibility: { nil },
          run: { current }, packageURL: { nil }, artifact: { _ in nil },
          commit: { next, _, _ in
            current = next
            return true
          }))
    }
    model.replacePartTapped(current.parts[0].id)
    try await drop([source], onto: model)
    #expect(current.parts[0].isReturned)
    #expect(current.parts[0].pieces[0].finished != previous)
    #expect(current.parts[0].pieces[0].finished?.byteCount == previous?.byteCount)
  }

  @Test func truePeakFailureKeepsOldRunAndRemovesWorkDirectory() async throws {
    let current = run()
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let removed = LockIsolated<[URL]>([])
    let model = withDependencies {
      $0.masteringAudio = .init(prepare: { _, _ in
        throw MasteringPreparationError.truePeakCeilingExceeded(part: 1, measuredDBTP: -1.0)
      })
      $0.masteringStaging = .liveValue
      $0.masteringStaging.makeWorkDirectory = {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
      }
      $0.masteringStaging.removeDirectory = { url in
        removed.withValue { $0.append(url) }
        try? FileManager.default.removeItem(at: url)
      }
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {},
          inputs: {
            .success(
              .init(
                artist: "Artist", canonicalAudioURL: URL(fileURLWithPath: "/tmp/audio"),
                canonicalFingerprint: "sha256:test", sourceSampleRate: 44_100,
                sourceDurationSamples: 44_100, pieces: [], inputsDigest: "new"))
          }, eligibility: { nil }, run: { current }, packageURL: { nil },
          artifact: { _ in nil },
          commit: { _, _, _ in
            Issue.record("Failed preparation committed")
            return false
          }))
    }
    await model.prepareTapped()
    await model.prepareAgainConfirmed()
    #expect(model.message?.contains("above the −1.5 dBTP ceiling") == true)
    expectNoDifference(removed.value, [work])
    #expect(!FileManager.default.fileExists(atPath: work.path))
  }

  @Test func teardownCancelsPreparationAndRemovesItsWorkDirectory() async {
    let current = run()
    let gate = CancellationGate()
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let removed = LockIsolated(false)
    let model = withDependencies {
      $0.masteringStaging = .liveValue
      $0.masteringStaging.makeWorkDirectory = {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
      }
      $0.masteringStaging.removeDirectory = { url in
        removed.setValue(true)
        try? FileManager.default.removeItem(at: url)
      }
      $0.masteringAudio = .init(prepare: { _, _ in
        await withTaskCancellationHandler {
          await gate.waitForCancellation()
          return .init(parts: [], warnings: [], inputsDigest: "new")
        } onCancel: {
          Task { await gate.cancel() }
        }
      })
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {},
          inputs: {
            .success(
              .init(
                artist: "Artist", canonicalAudioURL: URL(fileURLWithPath: "/tmp/audio"),
                canonicalFingerprint: "sha256:test", sourceSampleRate: 44_100,
                sourceDurationSamples: 44_100, pieces: [], inputsDigest: "new"))
          }, eligibility: { nil }, run: { current }, packageURL: { nil },
          artifact: { _ in nil },
          commit: { _, _, _ in
            Issue.record("Cancelled preparation committed")
            return false
          }))
    }
    let preparation = Task { await model.prepareAgainConfirmed() }
    await gate.waitUntilStarted()
    await model.teardown()
    await preparation.value
    expectNoDifference(model.run?.id, current.id)
    #expect(model.activity == .idle)
    #expect(removed.value)
    #expect(!FileManager.default.fileExists(atPath: work.path))
  }
  @Test func preparationBlockersNeverCommit() async {
    var commits = 0
    let host = MasteringPageModel.Host(
      finishTitleEdit: {}, inputs: { .failure(.unsaved) }, eligibility: { nil },
      run: { nil }, packageURL: { nil }, artifact: { _ in nil },
      commit: { _, _, _ in
        commits += 1
        return true
      })
    let model = MasteringPageModel(host: host)
    await model.prepareTapped()
    expectNoDifference(model.message, "Save the project before preparing for mastering.")
    expectNoDifference(commits, 0)
  }

  @Test func preparationReportsArtistIntroAndTitleBlockers() async {
    for (blocker, expected) in [
      (MasteringBlocker.missingArtist, "Enter the interview artist first."),
      (.noIntros, "No intro clips to prepare. Only clips typed as Intro are included."),
      (.blankTitles([Fixtures.uuid(1)]), "Name every intro before preparing."),
    ] {
      let model = MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(blocker) }, eligibility: { nil },
          run: { nil }, packageURL: { nil }, artifact: { _ in nil },
          commit: { _, _, _ in false }))
      await model.prepareTapped()
      expectNoDifference(model.message, expected)
    }
  }

  @Test func titleEditFinishesBeforePreparationReadsInputs() async {
    var events: [String] = []
    let model = MasteringPageModel(
      host: .init(
        finishTitleEdit: { events.append("finish") },
        inputs: {
          events.append("read")
          return .failure(.missingArtist)
        },
        eligibility: { nil }, run: { nil }, packageURL: { nil },
        artifact: { _ in nil }, commit: { _, _, _ in false }))
    await model.prepareTapped()
    expectNoDifference(events, ["finish", "read"])
  }

  @Test func returnedPartIsNotMatchedWithoutReplace() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".wav")
    try Data([1, 2, 3, 4]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let current = run(returned: true)
    let model = withDependencies {
      $0.masteringStaging = .liveValue
      $0.masteringReturn = .init(
        inspect: { url in
          .init(
            fileName: url.lastPathComponent, sampleRate: 44_100, channels: 2,
            sourceFrames: 44_100)
        },
        encodePart: { _, _, _ in
          Issue.record("Completed part encoded without Replace")
          return []
        })
    } operation: {
      MasteringPageModel(
        host: .init(
          finishTitleEdit: {}, inputs: { .failure(.notLoaded) }, eligibility: { nil },
          run: { current }, packageURL: { nil }, artifact: { _ in nil },
          commit: { _, _, _ in
            Issue.record("Committed completed part")
            return false
          }))
    }
    try await drop([source], onto: model)
    #expect(model.message?.contains("does not match any part still needed") == true)
  }

  @Test func eligibilitySummaryExplainsIncludedAndExcludedClips() {
    let intro = Slice(
      id: Fixtures.uuid(1), name: "Intro", startSample: 0,
      endSample: 100, wordIDs: [], snippet: "")
    let model = MasteringPageModel(
      host: .init(
        finishTitleEdit: {}, inputs: { .failure(.notLoaded) },
        eligibility: {
          .init(
            intros: [intro], blankTitledIntroIDs: [],
            excluded: [
              .init(sliceID: Fixtures.uuid(2), name: "Spotlight", reason: .notIntro),
              .init(sliceID: Fixtures.uuid(3), name: "Removed", reason: .fullyRemoved),
            ])
        }, run: { nil }, packageURL: { nil }, artifact: { _ in nil },
        commit: { _, _, _ in false }))
    expectNoDifference(
      model.eligibilitySummary,
      "1 intro included · 1 other clip excluded · 1 fully removed intro excluded")
  }
}

// swiftlint:enable inclusive_language
