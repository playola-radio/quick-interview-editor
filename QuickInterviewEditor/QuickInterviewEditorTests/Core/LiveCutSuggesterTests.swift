import CustomDump
import Foundation
import Synchronization
import Testing

@testable import PlayolaInterviewEditor

/// Pure coverage for the Swift→Python request wire: the JSON `LiveCutSuggester`
/// writes must carry the snake-cased keys `cut_suggester.cli` expects, and must plumb
/// the canonical sample rate the cutter needs to derive durations. No subprocess.
struct LiveCutSuggesterTests {

  private static func request(sampleRate: Int = 44100) -> CutSuggestRequest {
    CutSuggestRequest(
      transcriptUnits: [
        TranscriptUnit(
          id: 3, text: "So a young Hayes Carll", wordIDs: [7, 8, 9],
          startSample: 88200, endSample: 132300, startSec: 2.0, endSec: 3.0,
          speakerID: "SPEAKER_00")
      ],
      diarization: DiarizationEvidence(diarizationHash: "sha256:diar"),
      productSpecs: [.spotlight],
      options: CutSuggestOptions(model: "claude-sonnet-5"),
      transcriptHash: "sha256:t", sourceFingerprint: "fp", sampleRate: sampleRate)
  }

  private func encodedObject(_ request: CutSuggestRequest) throws -> [String: Any] {
    let data = try LiveCutSuggester.encodedRequest(request)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func encodesSnakeCasedTranscriptUnits() throws {
    let object = try encodedObject(Self.request())
    let units = try #require(object["transcript_units"] as? [[String: Any]])
    let unit = try #require(units.first)
    expectNoDifference(unit["id"] as? Int, 3)
    expectNoDifference(unit["word_ids"] as? [Int], [7, 8, 9])
    expectNoDifference(unit["start_sample"] as? Int, 88200)
    expectNoDifference(unit["end_sample"] as? Int, 132300)
    expectNoDifference(unit["speaker_id"] as? String, "SPEAKER_00")
  }

  @Test func encodesOptionsWithSampleRateFromRequest() throws {
    let object = try encodedObject(Self.request(sampleRate: 48000))
    let options = try #require(object["options"] as? [String: Any])
    expectNoDifference(options["model"] as? String, "claude-sonnet-5")
    expectNoDifference(options["prompt_version"] as? String, "v2")
    expectNoDifference(options["stage1_window"] as? Int, 130)
    expectNoDifference(options["stage1_step"] as? Int, 110)
    // The canonical rate the units' samples are expressed in — required so Python
    // derives duration from samples/rate correctly.
    expectNoDifference(options["sample_rate"] as? Int, 48000)
  }

  @Test func encodesProductSpecsAndDiarization() throws {
    let object = try encodedObject(Self.request())
    let specs = try #require(object["product_specs"] as? [[String: Any]])
    let spec = try #require(specs.first)
    expectNoDifference(spec["product_type"] as? String, "spotlight")
    expectNoDifference(spec["hard_min_sec"] as? Double, 15)
    let diar = try #require(object["diarization"] as? [String: Any])
    expectNoDifference(diar["diarization_hash"] as? String, "sha256:diar")
  }

  @Test func omitsDiarizationWhenAbsent() throws {
    var req = Self.request()
    req.diarization = nil
    let object = try encodedObject(req)
    #expect(object["diarization"] == nil || object["diarization"] is NSNull)
  }
}

extension LiveCutSuggesterTests {
  @Test func fullV2RequestMatchesSharedFixture() throws {
    let fixture = try suggestionContractFixture("suggestion-contract-v2")
    struct HistoricalRequest: Decodable { var configuration: SuggestionConfiguration }
    let capturedConfiguration = try JSONDecoder().decode(
      HistoricalRequest.self, from: fixture
    ).configuration
    let snapshot = SuggestionRunSnapshot(
      runID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      configuration: capturedConfiguration, configurationHash: "swift-only-hash",
      model: "fixture-model", discoveryPromptVersion: "configured-v1",
      extractionPromptVersion: "fields-v1", productSpecVersion: "configured-v1",
      transcriptHash: "fixture-transcript", sourceFingerprint: "fixture-source", sampleRate: 44100)
    let request = CutSuggestRequest(
      transcriptUnits: [
        TranscriptUnit(
          id: 0, text: "You're listening to Playola.", wordIDs: [0],
          startSample: 0, endSample: 88200, startSec: 0, endSec: 2, speakerID: nil)
      ], diarization: nil, productSpecs: [], options: CutSuggestOptions(),
      transcriptHash: snapshot.transcriptHash, sourceFingerprint: snapshot.sourceFingerprint,
      sampleRate: 44100, snapshot: snapshot)
    let actual =
      try JSONSerialization.jsonObject(with: LiveCutSuggester.encodedRequest(request))
      as? NSDictionary
    let expected = try JSONSerialization.jsonObject(with: fixture) as? NSDictionary
    expectNoDifference(actual, expected)
    var resume = request
    resume.mode = .resume
    resume.snapshot?.stage1Window = 160
    resume.snapshot?.stage1Step = 140
    let object = try encodedObject(resume)
    expectNoDifference(object["mode"] as? String, "resume")
    expectNoDifference((object["options"] as? [String: Any])?["stage1_window"] as? Int, 160)
    expectNoDifference((object["options"] as? [String: Any])?["stage1_step"] as? Int, 140)
    resume.transcriptHash = "different"
    #expect(throws: CutSuggestClientError.self) { try LiveCutSuggester.encodedRequest(resume) }
  }

  @Test func olderSnapshotDecodesPinnedWindowDefaults() throws {
    let snapshot = suggestionResultSnapshot()
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
    object.removeValue(forKey: "stage1Window")
    object.removeValue(forKey: "stage1Step")
    let decoded = try JSONDecoder().decode(
      SuggestionRunSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    expectNoDifference(decoded.stage1Window, 130)
    expectNoDifference(decoded.stage1Step, 110)
  }
}

func suggestionContractFixture(_ name: String) throws -> Data {
  let url = try #require(
    Bundle(for: SuggestionWireFixtureBundle.self).url(forResource: name, withExtension: "json"))
  return try Data(contentsOf: url)
}

private final class SuggestionWireFixtureBundle {}

func suggestionResultSnapshot() -> SuggestionRunSnapshot {
  var configuration = SuggestionDefaults.configuration
  configuration.types.append(
    .init(
      id: "custom-voice", name: "Custom Voice", group: .spotlights,
      guidelines: "Reflections", template: [.init(kind: .field, value: "descriptive-title")],
      sequenceFieldIDs: ["artist-name"]))
  return SuggestionRunSnapshot(
    runID: UUID(uuidString: "12345678-1234-5678-1234-567812345678")!,
    configuration: configuration, configurationHash: "opaque-swift-hash", model: "fixture-model",
    discoveryPromptVersion: "configured-v1", extractionPromptVersion: "fields-v1",
    productSpecVersion: "configured-v1", transcriptHash: "fixture-transcript",
    sourceFingerprint: "fixture-source", sampleRate: 48000)
}

extension LiveCutSuggesterTests {
  @Test func liveAdapterEmitsCheckpointIgnoresStaleAndCompletesValidEmpty() async throws {
    let request = Self.configuredRequest()
    let id = try #require(request.snapshot?.runID)
    let lines = [
      "QIE_EVENT {\"type\":\"checkpoint\",\"run_id\":\"\(id)\",\"revision\":3}",
      "QIE_EVENT {\"type\":\"checkpoint\",\"run_id\":\"\(id)\",\"revision\":2}",
      "QIE_EVENT {\"type\":\"checkpoint\",\"run_id\":\"\(id)\",\"revision\":3}",
      "QIE_EVENT {\"type\":\"progress\",\"phase\":\"completed\",\"message\":\"done\"}",
    ]
    let runner = Self.runner(output: Self.emptyResult(id), lines: lines)
    let events = try await Array(LiveCutSuggester.suggestCuts(request, apiKey: nil, runner: runner))
    expectNoDifference(
      events, [.checkpoint(runID: id, revision: 3), .progress("done"), .completed([])])
  }

  @Test(arguments: [false, true])
  func emptyCompletionPreservesDiagnosticMetadata(configured: Bool) async throws {
    var object: [String: Any] = ["suggestions": [], "meta": ["n_raw_clips": 0]]
    var expected: [CutSuggestEvent] = []
    if configured {
      let id = suggestionResultSnapshot().runID
      object.merge([
        "schema_version": 2, "run_id": id.uuidString,
        "checkpoint_revision": 3, "status": "ready",
      ]) { _, new in new }
      expected.append(.checkpoint(runID: id, revision: 3))
    }
    expected += [.diagnostic("0 raw clip(s) from the model."), .completed([])]
    let runner = Self.runner(output: try JSONSerialization.data(withJSONObject: object))
    let events = try await Array(
      LiveCutSuggester.suggestCuts(
        configured ? Self.configuredRequest() : Self.request(), apiKey: nil, runner: runner))
    expectNoDifference(events, expected)
  }

  @Test func needsRetryExitOneIsRecoverableBeforeAuthClassification() async throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: suggestionContractFixture("suggestion-result-v2"))
        as? [String: Any])
    object["status"] = "needs_retry"
    object["failed_batches"] = [
      ["kind": "extraction", "request_key": "retry-key", "retryable": true]
    ]
    let output = try JSONSerialization.data(withJSONObject: object)
    let events = try await Array(
      LiveCutSuggester.suggestCuts(
        Self.configuredRequest(), apiKey: nil,
        runner: Self.runner(output: output, exitCode: 1, stderr: "authentication failure")))
    expectNoDifference(
      events.last,
      .recoverableFailure(
        runID: suggestionResultSnapshot().runID,
        failedRequestKeys: ["retry-key"],
        message: "Some requests failed. Resume to retry the unfinished requests."))
  }

  @Test func inputSizeFailureExplainsThatRetryCannotFixIt() async throws {
    let id = suggestionResultSnapshot().runID
    let data = Data(
      """
      {"schema_version":2,"run_id":"\(id)","checkpoint_revision":1,"status":"needs_retry",
      "suggestions":[],"failed_batches":[{"kind":"input_size","retryable":false}]}
      """
      .utf8)
    let events = try await Array(
      LiveCutSuggester.suggestCuts(
        Self.configuredRequest(), apiKey: nil,
        runner: Self.runner(output: data, exitCode: 1)))
    expectNoDifference(
      events.last,
      .recoverableFailure(
        runID: id, failedRequestKeys: [],
        message:
          "Some candidates exceed the extraction input limit. "
          + "Retrying unchanged input cannot complete them; "
          + "discard this run and start a new search with adjusted settings."
      ))
  }

  @Test func nonzeroReadyDoesNotCompleteAndProgressDoesNotClassifyAuth() async throws {
    let stderr =
      "QIE_EVENT {\"type\":\"progress\",\"message\":\"401 credential\"}\nnetwork unavailable"
    do {
      _ = try await Array(
        LiveCutSuggester.suggestCuts(
          Self.configuredRequest(), apiKey: nil,
          runner: Self.runner(
            output: Self.emptyResult(suggestionResultSnapshot().runID), exitCode: 1, stderr: stderr)
        ))
      Issue.record("Expected failure")
    } catch {
      expectNoDifference(error as? CutSuggestClientError, .suggestFailed(stderr))
    }
    do {
      _ = try await Array(
        LiveCutSuggester.suggestCuts(
          Self.request(), apiKey: nil,
          runner: Self.runner(output: Data(), exitCode: 1, stderr: "401 unauthorized")))
      Issue.record("Expected authentication failure")
    } catch {
      expectNoDifference(error as? CutSuggestClientError, .authMissing("401 unauthorized"))
    }
  }

  @Test(arguments: [SuggestionSearchMode.fresh, .automatic, .resume])
  func credentialsOnlyReachChildEnvironmentAndJournalPersists(mode: SuggestionSearchMode)
    async throws
  {
    var request = Self.configuredRequest()
    request.mode = mode
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: journal) }
    let marker = journal.appendingPathComponent("checkpoint.json")
    try Data("saved".utf8).write(to: marker)
    request.journalDirectory = journal
    var runner = Self.runner(output: Self.emptyResult(suggestionResultSnapshot().runID))
    let originalSpawn = runner.spawn
    runner.spawn = { launch, args, environment in
      expectNoDifference(environment["ANTHROPIC_API_KEY"], "secret-test-key")
      #expect(!args.joined().contains("secret-test-key"))
      let index = try #require(args.firstIndex(of: "--request"))
      let requestURL = URL(fileURLWithPath: args[index + 1])
      let text = try String(contentsOf: requestURL, encoding: .utf8)
      #expect(!text.contains("secret-test-key"))
      let journalIndex = try #require(args.firstIndex(of: "--journal-dir"))
      expectNoDifference(args[journalIndex + 1], journal.path)
      expectNoDifference(args.contains("--refresh"), mode == .fresh)
      #expect(!args.contains("--cache-dir"))
      return try originalSpawn(launch, args, environment)
    }
    _ = try await Array(
      LiveCutSuggester.suggestCuts(request, apiKey: " secret-test-key ", runner: runner))
    expectNoDifference(try String(contentsOf: marker, encoding: .utf8), "saved")
  }

  private static func configuredRequest() -> CutSuggestRequest {
    let snapshot = suggestionResultSnapshot()
    var request = Self.request(sampleRate: snapshot.sampleRate)
    request.snapshot = snapshot
    request.transcriptHash = snapshot.transcriptHash
    request.sourceFingerprint = snapshot.sourceFingerprint
    return request
  }

  private static func emptyResult(_ id: UUID) -> Data {
    Data(
      "{\"schema_version\":2,\"run_id\":\"\(id)\",\"checkpoint_revision\":3,\"status\":\"ready\",\"suggestions\":[]}"
        .utf8)
  }

  private static func runner(
    output: Data, lines: [String] = [], exitCode: Int32 = 0,
    stderr: String = ""
  ) -> LiveCutSuggester.Runner {
    LiveCutSuggester.Runner(
      resolveLaunch: {
        EngineLaunch(
          executable: URL(fileURLWithPath: "/fake/helper"),
          argumentPrefix: [], workingDirectory: FileManager.default.temporaryDirectory,
          isBundled: true)
      },
      makeWorkDirectory: {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
      }, cacheDirectory: { nil },
      spawn: { _, _, _ in
        LiveCutSuggester.ProcessHandle(
          readStdoutToEnd: { output }, waitForExit: { exitCode },
          stderrLines: {
            AsyncStream { continuation in
              for line in lines { continuation.yield(line) }
              continuation.finish()
            }
          }, stderrTail: { stderr }, terminate: {})
      })
  }
}

extension Array {
  fileprivate init(_ stream: AsyncThrowingStream<Element, Error>) async throws {
    self = []
    for try await value in stream { append(value) }
  }
}

extension LiveCutSuggesterTests {
  @Test func cancellationTerminatesChildCleansScratchAndNeverCompletes() async throws {
    let started = AsyncStream<Void>.makeStream()
    let terminated = AsyncStream<Void>.makeStream()
    let stderr = AsyncStream<String>.makeStream()
    let stdout = AsyncStream<Data>.makeStream()
    let workPath = Mutex<URL?>(nil)
    let completionObserved = Mutex(false)
    let terminationObserved = Mutex(false)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: scratch) }
    var runner = Self.runner(output: Data())
    runner.makeWorkDirectory = {
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      workPath.withLock { $0 = scratch }
      return scratch
    }
    runner.spawn = { _, _, _ in
      started.continuation.yield(())
      return LiveCutSuggester.ProcessHandle(
        readStdoutToEnd: {
          for await data in stdout.stream { return data }
          return Data()
        }, waitForExit: { 0 }, stderrLines: { stderr.stream }, stderrTail: { "" },
        terminate: {
          terminationObserved.withLock { $0 = true }
          terminated.continuation.yield(())
          stderr.continuation.finish()
          stdout.continuation.yield(Self.emptyResult(suggestionResultSnapshot().runID))
          stdout.continuation.finish()
        })
    }
    let stream = LiveCutSuggester.suggestCuts(Self.configuredRequest(), apiKey: nil, runner: runner)
    let consumer = Task {
      for try await event in stream {
        if case .completed = event { completionObserved.withLock { $0 = true } }
      }
    }
    var startIterator = started.stream.makeAsyncIterator()
    _ = await startIterator.next()
    consumer.cancel()
    var terminationIterator = terminated.stream.makeAsyncIterator()
    _ = await terminationIterator.next()
    _ = try await consumer.value
    expectNoDifference(terminationObserved.withLock { $0 }, true)
    expectNoDifference(completionObserved.withLock { $0 }, false)
    let path = try #require(workPath.withLock { $0 })
    await waitForScratchDeletion(path)
    #expect(!FileManager.default.fileExists(atPath: path.path))
  }

  private func waitForScratchDeletion(_ path: URL) async {
    let workRemoved = AsyncStream<Void>.makeStream()
    // The adapter task drains its child after the cancelled consumer has already returned.
    // Observe the scratch deletion without sleeps or scheduling assumptions.
    let descriptor = open(path.path, O_EVTONLY)
    if descriptor >= 0 {
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: .delete, queue: .global())
      source.setEventHandler { workRemoved.continuation.yield(()) }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      if FileManager.default.fileExists(atPath: path.path) {
        var removedIterator = workRemoved.stream.makeAsyncIterator()
        _ = await removedIterator.next()
      }
      source.cancel()
    }
  }
}

extension LiveCutSuggesterTests {
  @Test func rejectsTerminalResultOlderThanObservedCheckpoint() async throws {
    let id = suggestionResultSnapshot().runID
    let runner = Self.runner(
      output: Self.emptyResult(id),
      lines: [
        "QIE_EVENT {\"type\":\"checkpoint\",\"run_id\":\"\(id)\",\"revision\":4}"
      ])
    var events: [CutSuggestEvent] = []
    do {
      for try await event in LiveCutSuggester.suggestCuts(
        Self.configuredRequest(), apiKey: nil, runner: runner)
      {
        events.append(event)
      }
      Issue.record("Expected stale result to fail")
    } catch {
      expectNoDifference(
        error as? CutSuggestClientError,
        .decodeFailed("Final result is older than the latest checkpoint."))
    }
    expectNoDifference(events, [.checkpoint(runID: id, revision: 4)])
  }
}
