import ConcurrencyExtras
import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct TranscriptionQueueClientTests {

  /// A fake `transcribe` whose streams never finish on their own: each call records its
  /// continuation and source and signals a start, so the test drives completion explicitly
  /// (no sleeps) and can assert which job actually reached the engine.
  private struct Controllable {
    let transcribe: @Sendable (URL, String, CachePolicy) -> AsyncThrowingStream<EngineEvent, Error>
    let continuations: LockIsolated<[AsyncThrowingStream<EngineEvent, Error>.Continuation]>
    let sources: LockIsolated<[URL]>
    let starts: AsyncStream<Int>
  }

  private func controllableTranscribe() -> Controllable {
    let continuations = LockIsolated<[AsyncThrowingStream<EngineEvent, Error>.Continuation]>([])
    let sources = LockIsolated<[URL]>([])
    let (starts, startsContinuation) = AsyncStream<Int>.makeStream()
    let transcribe:
      @Sendable (URL, String, CachePolicy) -> AsyncThrowingStream<EngineEvent, Error> = {
        source, _, _ in
        AsyncThrowingStream { continuation in
          let index = continuations.withValue { list -> Int in
            list.append(continuation)
            return list.count
          }
          sources.withValue { $0.append(source) }
          startsContinuation.yield(index)
        }
      }
    return Controllable(
      transcribe: transcribe, continuations: continuations, sources: sources, starts: starts)
  }

  private func job(_ path: String = "/clip.m4a") -> TranscriptionJob {
    TranscriptionJob(
      source: URL(fileURLWithPath: path), sourceFingerprint: "fp", policy: .useCache)
  }

  @Test func thirdJobWaitsUntilASlotFrees() async {
    let fake = controllableTranscribe()
    let continuations = fake.continuations

    await withMainSerialExecutor {
      let queue = TranscriptionQueue(maxConcurrent: 2, transcribe: fake.transcribe)
      for _ in 0..<3 {
        Task {
          let stream = await queue.enqueue(job())
          do { for try await _ in stream {} } catch {}
        }
      }

      var startIterator = fake.starts.makeAsyncIterator()
      _ = await startIterator.next()  // first slot
      _ = await startIterator.next()  // second slot
      // The cap is 2, so the third job is parked and never reached the fake yet.
      expectNoDifference(continuations.value.count, 2)

      // Finishing the first job frees its slot; the parked third job starts.
      continuations.withValue { $0[0].finish() }
      _ = await startIterator.next()
      expectNoDifference(continuations.value.count, 3)

      continuations.withValue { for continuation in $0 { continuation.finish() } }
    }
  }

  @Test func cancellingAParkedWaiterFreesItsSlotWithoutStartingItsJob() async {
    let fake = controllableTranscribe()
    let continuations = fake.continuations
    let sources = fake.sources

    await withMainSerialExecutor {
      let queue = TranscriptionQueue(maxConcurrent: 2, transcribe: fake.transcribe)
      Task { do { for try await _ in await queue.enqueue(job("/a.m4a")) {} } catch {} }
      Task { do { for try await _ in await queue.enqueue(job("/b.m4a")) {} } catch {} }
      let parked = Task {
        do { for try await _ in await queue.enqueue(job("/parked.m4a")) {} } catch {}
      }

      var startIterator = fake.starts.makeAsyncIterator()
      _ = await startIterator.next()
      _ = await startIterator.next()
      expectNoDifference(continuations.value.count, 2)

      // Cancelling the parked waiter must remove it, so freeing a slot never starts its job.
      parked.cancel()
      await parked.value

      // Freeing a slot and enqueuing a fresh job proves the freed slot went to the new job, not
      // the cancelled waiter: the third engine start is `/next.m4a`, never `/parked.m4a`.
      continuations.withValue { $0[0].finish() }
      Task { do { for try await _ in await queue.enqueue(job("/next.m4a")) {} } catch {} }
      _ = await startIterator.next()

      expectNoDifference(continuations.value.count, 3)
      expectNoDifference(sources.value.map(\.path), ["/a.m4a", "/b.m4a", "/next.m4a"])

      continuations.withValue { for continuation in $0 { continuation.finish() } }
    }
  }

  @Test func forwardsEventsFromTheUnderlyingStream() async throws {
    let result = Fixtures.transcriptionResult(Fixtures.editPlan())
    let queue = TranscriptionQueue(maxConcurrent: 2) { _, _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.completed(result))
        continuation.finish()
      }
    }
    var received: [EngineEvent] = []
    for try await event in await queue.enqueue(job()) { received.append(event) }
    expectNoDifference(received, [.completed(result)])
  }

  @Test func forwardsThrownErrors() async {
    let queue = TranscriptionQueue(maxConcurrent: 2) { _, _, _ in
      AsyncThrowingStream { continuation in
        continuation.finish(throwing: EngineClientError.engineFailed("boom"))
      }
    }
    await #expect(throws: EngineClientError.engineFailed("boom")) {
      for try await _ in await queue.enqueue(job()) {}
    }
  }
}
