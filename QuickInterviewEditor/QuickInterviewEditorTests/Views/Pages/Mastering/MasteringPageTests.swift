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

@MainActor
struct MasteringPageTests {
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
    await model.mastersDropped([source])
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
    await model.mastersDropped([source])
    let target = await capture.value
    expectNoDifference(target?.pieces[0].artist, "Frozen Artist")
    expectNoDifference(target?.pieces[0].title, "Frozen Title")
    expectNoDifference(target?.pieces[0].lrc, "[00:00.00]Hello")
    expectNoDifference(target?.pieces[0].frameCount, 44_100)
    #expect(current.parts[0].isReturned)
    #expect(current.parts[0].pieces[0].finished?.fileName.hasSuffix(".m4a") == true)
    expectNoDifference(current.parts[0].prepared, original.parts[0].prepared)
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
    await model.mastersDropped([source])
    expectNoDifference(
      model.ambiguousReturn?.candidatePartIDs,
      [Fixtures.uuid(71), Fixtures.uuid(81)])
    await model.mastersDropped([source])
    expectNoDifference(model.message, "Wait for the current step to finish.")
    model.ambiguousReturnCancelled()
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
