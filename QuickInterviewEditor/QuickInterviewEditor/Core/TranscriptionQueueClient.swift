import Dependencies
import Foundation

/// One transcription request: the source audio plus the fingerprint and cache policy the
/// underlying `TranscriptionClient` needs. A value so the queue can hold and reorder it.
struct TranscriptionJob: Sendable, Equatable {
  var source: URL
  var sourceFingerprint: String
  var policy: CachePolicy
}

/// App-level transcription entry point that caps how many heavy WhisperX subprocesses run at
/// once. `RootModel` used to own this cap via its own queue pump; moving it into a dependency
/// lets every window share one limiter once each `.pie` is its own document (spec A3). Enqueuing
/// suspends until a slot is free, then returns the underlying engine stream.
struct TranscriptionQueueClient: Sendable {
  var enqueue: @Sendable (TranscriptionJob) async -> AsyncThrowingStream<EngineEvent, Error>
}

/// Serializes access to a fixed number of transcription slots. A job holds its slot for as long
/// as its engine stream runs; when the stream finishes, fails, or is cancelled the slot is handed
/// to the next waiter (or released) so at most `maxConcurrent` engines ever run together.
actor TranscriptionQueue {
  private struct Waiter {
    let id: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  private let maxConcurrent: Int
  private let transcribe:
    @Sendable (URL, String, CachePolicy) -> AsyncThrowingStream<EngineEvent, Error>
  private var running = 0
  private var waiters: [Waiter] = []
  private var nextWaiterID: UInt64 = 0

  init(
    maxConcurrent: Int,
    transcribe:
      @escaping @Sendable (URL, String, CachePolicy) -> AsyncThrowingStream<
        EngineEvent, Error
      >
  ) {
    self.maxConcurrent = maxConcurrent
    self.transcribe = transcribe
  }

  func enqueue(_ job: TranscriptionJob) async -> AsyncThrowingStream<EngineEvent, Error> {
    do {
      try await acquire()
    } catch {
      // Cancelled while parked: never got a slot, so start no engine job.
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
    // Cancelled after being handed a slot but before starting: hand the slot back rather than
    // burn a heavy engine run for a consumer that has already gone away.
    if Task.isCancelled {
      release()
      return AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
    let upstream = transcribe(job.source, job.sourceFingerprint, job.policy)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await event in upstream { continuation.yield(event) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
        // The slot is held for the life of the engine stream, not the consumer's consumption —
        // draining `upstream` eagerly here means a slow reader can't pin a slot open, and a
        // cancelled reader (via `onTermination`) still frees it once the loop unwinds.
        //
        // Known teardown-window limitation: on natural completion `upstream` (LiveEngine) only
        // finishes after `waitForExit` reaps the child, so the slot is held until the process is
        // truly dead. On *cancellation*, `AsyncThrowingStream` short-circuits this loop's `next()`
        // to nil before the downstream SIGTERM→SIGKILL→reap completes, so `release()` can hand a
        // slot to the next waiter while the cancelled WhisperX is still exiting — a brief >maxConcurrent
        // overlap. Binding release to actual process reap needs the engine-stream layer to expose a
        // reap barrier (or the queue to own the process); tracked as an engine-layer follow-up.
        await release()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func acquire() async throws {
    if running < maxConcurrent {
      running += 1
      return
    }
    // Full: park until `release` hands this waiter the freed slot. The slot count is preserved
    // across the hand-off (no decrement in `release`, no increment here), so it never double-counts.
    // Cancelling a parked waiter removes it and throws, so a closed window never later starts a job.
    let id = nextWaiterID
    nextWaiterID += 1
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters.append(Waiter(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: UInt64) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }

  private func release() {
    if waiters.isEmpty {
      running -= 1
    } else {
      waiters.removeFirst().continuation.resume()
    }
  }
}

extension TranscriptionQueueClient: DependencyKey {
  static var liveValue: TranscriptionQueueClient {
    @Dependency(\.transcription) var transcription
    let queue = TranscriptionQueue(maxConcurrent: 2, transcribe: transcription.transcribe)
    return TranscriptionQueueClient(enqueue: { await queue.enqueue($0) })
  }
}

extension TranscriptionQueueClient: TestDependencyKey {
  /// No queue: hand back the underlying stream immediately so model tests drive phase logic
  /// with a controllable `transcription` override and never wait on real concurrency.
  static var testValue: TranscriptionQueueClient {
    TranscriptionQueueClient(enqueue: { job in
      @Dependency(\.transcription) var transcription
      return transcription.transcribe(job.source, job.sourceFingerprint, job.policy)
    })
  }
}

extension DependencyValues {
  var transcriptionQueue: TranscriptionQueueClient {
    get { self[TranscriptionQueueClient.self] }
    set { self[TranscriptionQueueClient.self] = newValue }
  }
}
