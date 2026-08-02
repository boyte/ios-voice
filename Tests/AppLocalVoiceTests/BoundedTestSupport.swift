import Foundation
@testable import AppLocalVoice

enum BoundedTestError: Error, CustomStringConvertible {
    case timedOut(Duration)

    var description: String {
        switch self {
        case .timedOut(let duration):
            return "bounded test operation timed out after \(duration)"
        }
    }
}

/// Runs one asynchronous test operation with a hard upper bound. The timeout
/// task is cancelled when the operation wins, and the operation is cancelled
/// when the timeout wins, so a bad provider fake cannot keep the test alive.
/// SAFETY: `lock` protects the winner flag, waiter, and child-task handles.
/// Child cancellation and continuation resumption occur only after unlocking.
private final class BoundedTimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let duration: Duration
    private let operation: @Sendable () async throws -> T
    private var finished = false
    private var continuation: CheckedContinuation<T, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(duration: Duration, operation: @escaping @Sendable () async throws -> T) {
        self.duration = duration
        self.operation = operation
    }

    func start(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        let operationTask = Task { [self] in
            do {
                complete(.success(try await operation()))
            } catch {
                complete(.failure(error))
            }
        }
        install(operationTask: operationTask)

        let timeoutTask = Task { [self] in
            do {
                try await Task.sleep(for: duration)
                complete(.failure(BoundedTestError.timedOut(duration)))
            } catch is CancellationError {
                // The other side of the race completed first.
            } catch {
                complete(.failure(error))
            }
        }
        install(timeoutTask: timeoutTask)
    }

    private func install(operationTask: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            operationTask.cancel()
        } else {
            self.operationTask = operationTask
            lock.unlock()
        }
    }

    private func install(timeoutTask: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            timeoutTask.cancel()
        } else {
            self.timeoutTask = timeoutTask
            lock.unlock()
        }
    }

    private func complete(_ result: Result<T, Error>) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation.resume(with: result)
    }
}

/// Returns as soon as either the operation or the timeout wins. The losing
/// task is cancelled, but a deliberately non-cooperative fake may continue in
/// the background; this is why the helper is test-only and why fakes must not
/// retain test-owned resources after cancellation.
func withBoundedTimeout<T: Sendable>(
    _ duration: Duration = .seconds(1),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        BoundedTimeoutRace(duration: duration, operation: operation).start(continuation)
    }
}

/// Drains one lifecycle stream only through its terminal idle state. The
/// stream remains open for future turns, so callers must never await an
/// absent event with an unbounded `first(where:)`.
func collectVoiceEventsThroughIdle(_ stream: AsyncStream<VoiceEvent>) async -> [VoiceEvent] {
    var events: [VoiceEvent] = []
    for await event in stream {
        events.append(event)
        if event == .stateChanged(.idle) { break }
    }
    return events
}

func collectVoiceEventsThroughListeningFinished(_ stream: AsyncStream<VoiceEvent>) async -> [VoiceEvent] {
    var events: [VoiceEvent] = []
    for await event in stream {
        events.append(event)
        if case .listeningFinished = event { break }
    }
    return events
}
