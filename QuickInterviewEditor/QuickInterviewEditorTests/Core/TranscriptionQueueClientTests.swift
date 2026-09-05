import ConcurrencyExtras
import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct TranscriptionQueueClientTests {

  /// A fake `transcribe` whose streams never finish on their own: each call records its
  /// continuation and signals a start, so the test drives completion explicitly (no sleeps).
  private func controllableTranscribe() -> (
    transcribe: @Sendable (URL, String, CachePolicy) -> AsyncThrowingStream<EngineEvent, Error>,
    continuations: LockIsolated<[AsyncThrowingStream<EngineEvent, Error>.Continuation]>,
    starts: AsyncStream<Int>
  ) {
    let continuations = LockIsolated<[AsyncThrowingStream<EngineEvent, Error>.Continuation]>([])
    let (starts, startsContinuation) = AsyncStream<Int>.makeStream()
    let transcribe:
      @Sendable (URL, String, CachePolicy) -> AsyncThrowingStream<EngineEvent, Error> = {
        _, _, _ in
        AsyncThrowingStream { continuation in
          let index = continuations.withValue { list -> Int in
            list.append(continuation)
            return list.count
          }
          startsContinuation.yield(index)
        }
      }
    return (transcribe, continuations, starts)
  }

  private let job = TranscriptionJob(
    source: URL(fileURLWithPath: "/clip.m4a"), sourceFingerprint: "fp", policy: .useCache)

  @Test func thirdJobWaitsUntilASlotFrees() async {
    let (transcribe, continuations, starts) = controllableTranscribe()

    await withMainSerialExecutor {
      let queue = TranscriptionQueue(maxConcurrent: 2, transcribe: transcribe)
      for _ in 0..<3 {
        Task {
          let stream = await queue.enqueue(job)
          do { for try await _ in stream {} } catch {}
        }
      }

      var startIterator = starts.makeAsyncIterator()
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

  @Test func forwardsEventsFromTheUnderlyingStream() async throws {
    let result = Fixtures.transcriptionResult(Fixtures.editPlan())
    let queue = TranscriptionQueue(maxConcurrent: 2) { _, _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.completed(result))
        continuation.finish()
      }
    }
    var received: [EngineEvent] = []
    for try await event in await queue.enqueue(job) { received.append(event) }
    expectNoDifference(received, [.completed(result)])
  }

  @Test func forwardsThrownErrors() async {
    let queue = TranscriptionQueue(maxConcurrent: 2) { _, _, _ in
      AsyncThrowingStream { continuation in
        continuation.finish(throwing: EngineClientError.engineFailed("boom"))
      }
    }
    await #expect(throws: EngineClientError.engineFailed("boom")) {
      for try await _ in await queue.enqueue(job) {}
    }
  }
}
