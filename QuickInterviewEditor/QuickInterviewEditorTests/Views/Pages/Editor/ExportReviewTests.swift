import CustomDump
import Dependencies
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct ExportReviewTests {
  @Test func reviewNamesCanCancelWhileApprovedCopiesAreRunning() async {
    let (enteredStream, entered) = AsyncStream.makeStream(of: Void.self)
    let (releaseStream, release) = AsyncStream.makeStream(of: Void.self)
    let model = withDependencies {
      $0.exportCopy = .init(
        listNames: { _ in [] },
        copy: { _, _ in
          entered.yield(())
          for await _ in releaseStream {}
        })
    } operation: {
      ExportReviewModel(request: request([clip(1, name: "ID 1")]), scratchDirectory: nil)
    }
    let worker = Task { await model.copy(approved: nil) }
    var cancelled = false
    model.onReviewNames = {
      cancelled = true
      worker.cancel()
    }
    for await _ in enteredStream { break }
    #expect(model.isCopying)
    model.reviewNamesTapped()
    #expect(cancelled)
    release.finish()
    _ = await worker.value
  }
  @Test func reviewActionsAuthorizeOnlyDisplayedMappingsAndUseExactWarning() async {
    let model = withDependencies {
      $0.exportCopy = .init(
        listNames: { _ in ["ID 1.aiff"] },
        copy: { _, _ in Issue.record("Review must precede copy") })
    } operation: {
      ExportReviewModel(request: request([clip(1, name: "ID 1")]), scratchDirectory: nil)
    }
    _ = await model.copy(approved: nil)
    var approved: [ExportNameMapping] = []
    var cancelled = false
    model.onExport = { approved = $0 }
    model.onReviewNames = { cancelled = true }
    expectNoDifference(
      model.warning,
      "A file with this name already exists or is included twice. Check your clip names or starting numbers."
    )
    model.exportWithSuffixesTapped()
    expectNoDifference(approved, model.mappings)
    model.reviewNamesTapped()
    #expect(cancelled)
  }
  private func clip(_ index: Int, name: String, generated: Bool = true) -> Slice {
    var slice = Slice(
      id: Fixtures.uuid(index), name: name, startSample: 0, endSample: 100, wordIDs: [], snippet: ""
    )
    if generated {
      slice.suggestionNaming = .init(
        runID: Fixtures.uuid(90), typeID: "image-id", typeName: "ID",
        typeGroup: .audioImages, discoveryLabel: "ID", extractedValues: [:], missingFieldIDs: [],
        correctedValues: [:], reservation: nil)
    }
    return slice
  }

  private func request(_ clips: [Slice]) -> ExportCopyRequest {
    .init(
      targets: clips, sourceStem: "Tape",
      renderedByID: Dictionary(
        uniqueKeysWithValues: clips.map { ($0.id, URL(fileURLWithPath: "/render/\($0.id).aiff")) }),
      destination: URL(fileURLWithPath: "/destination"))
  }

  @Test func safeNamesCopyWithoutReview() async {
    let copies = LockIsolated<[String]>([])
    let client = ExportCopyClient(
      listNames: { _ in [] },
      copy: { _, destination in copies.withValue { $0.append(destination.lastPathComponent) } })
    let outcome = await copyRenderedExports(request([clip(1, name: "ID 1")]), client: client)
    expectNoDifference(copies.value, ["ID 1.aiff"])
    expectNoDifference(outcome.copied.count, 1)
    expectNoDifference(outcome.reviewMappings, nil)
  }

  @Test func raceAfterPreflightRequiresReviewWithoutCopyingSuffix() async {
    let lists = LockIsolated(0)
    let copies = LockIsolated<[String]>([])
    let client = ExportCopyClient(
      listNames: { _ in
        lists.withValue { $0 += 1 }
        return lists.value > 1 ? ["ID 1.aiff"] : []
      }, copy: { _, destination in copies.withValue { $0.append(destination.lastPathComponent) } })
    let outcome = await copyRenderedExports(request([clip(1, name: "ID 1")]), client: client)
    expectNoDifference(copies.value, [])
    expectNoDifference(outcome.reviewMappings?.first?.proposedName, "ID 1 2.aiff")
  }

  @Test func copyTimeRacesRequireFreshApprovalEveryTime() async {
    let contents = LockIsolated<Set<String>>([])
    let client = ExportCopyClient(
      listNames: { _ in contents.value },
      copy: { _, destination in
        contents.withValue { $0.insert(destination.lastPathComponent) }
        throw CocoaError(.fileWriteFileExists)
      })
    var job = request([clip(1, name: "ID 1")])
    let first = await copyRenderedExports(job, client: client)
    expectNoDifference(first.reviewMappings?.first?.proposedName, "ID 1 2.aiff")
    job.approvedMappings = first.reviewMappings
    let second = await copyRenderedExports(job, client: client)
    expectNoDifference(second.reviewMappings?.first?.proposedName, "ID 1 3.aiff")
    expectNoDifference(second.copied, [])
    expectNoDifference(contents.value, ["ID 1.aiff", "ID 1 2.aiff"])
  }

  @Test func partialCopyResumeNeverCopiesFinishedTargetsAgain() async {
    let contents = LockIsolated<Set<String>>([])
    let copies = LockIsolated<[String]>([])
    let collide = LockIsolated(true)
    let client = ExportCopyClient(
      listNames: { _ in contents.value },
      copy: { _, destination in
        if destination.lastPathComponent == "ID 2.aiff", collide.value {
          contents.withValue { $0.insert("ID 2.aiff") }
          collide.setValue(false)
          throw CocoaError(.fileWriteFileExists)
        }
        contents.withValue { $0.insert(destination.lastPathComponent) }
        copies.withValue { $0.append(destination.lastPathComponent) }
      })
    var job = request([clip(1, name: "ID 1"), clip(2, name: "ID 2")])
    let first = await copyRenderedExports(job, client: client)
    expectNoDifference(first.copied.count, 1)
    job.copied = first.copied
    job.approvedMappings = first.reviewMappings
    let second = await copyRenderedExports(job, client: client)
    expectNoDifference(copies.value, ["ID 1.aiff", "ID 2 2.aiff"])
    expectNoDifference(second.copied.count, 2)
    expectNoDifference(second.reviewMappings, nil)
  }

  @Test func cancelAfterFirstCopyReportsPartialCount() async {
    let client = ExportCopyClient(
      listNames: { _ in [] },
      copy: { _, _ in
        withUnsafeCurrentTask { $0?.cancel() }
      })
    let job = request([clip(1, name: "ID 1"), clip(2, name: "ID 2")])
    let task = Task { await copyRenderedExports(job, client: client) }
    let outcome = await task.value
    #expect(outcome.cancelled)
    expectNoDifference(outcome.copied.count, 1)
  }

  @Test func listFailureIsAnErrorAndNeverAssumesEmptyDestination() async {
    let copies = LockIsolated(0)
    let client = ExportCopyClient(
      listNames: { _ in throw CocoaError(.fileReadNoPermission) },
      copy: { _, _ in copies.withValue { $0 += 1 } })
    let outcome = await copyRenderedExports(request([clip(1, name: "ID 1")]), client: client)
    #expect(outcome.errorMessage != nil)
    expectNoDifference(copies.value, 0)
  }

  @Test func remainingLegacyFallbackRetainsOriginalExportIndex() async {
    var job = request([clip(1, name: "ID 1"), clip(2, name: "", generated: false)])
    job.copied = [.init(id: Fixtures.uuid(1), url: URL(fileURLWithPath: "/destination/ID 1.aiff"))]
    let copies = LockIsolated<[String]>([])
    let client = ExportCopyClient(
      listNames: { _ in ["ID 1.aiff"] },
      copy: { _, destination in copies.withValue { $0.append(destination.lastPathComponent) } })
    _ = await copyRenderedExports(job, client: client)
    expectNoDifference(copies.value, ["Tape - Slice 002.aiff"])
  }
}
