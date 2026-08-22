import Foundation

/// A cancellation-aware one-shot signal used to bound observation of an
/// unstructured provider startup task without dropping ownership of the task.
/// SAFETY: `lock` protects the one-shot signal and waiter. The continuation is
/// removed while locked and resumed only after unlocking.
final class CancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Error>?

    func signal() {
        lock.lock()
        guard !signaled else {
            lock.unlock()
            return
        }
        signaled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    func wait() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if signaled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }, onCancel: { [self] in
            signal()
        })
    }
}

/// Races a provider startup task against cancellation without introducing a
/// structured child that would wait for a non-cooperative provider forever.
/// The provider task remains owned by `VoiceCoordinator`; this object only
/// bounds the caller's observation of it.
/// SAFETY: `lock` protects the winner flag, waiter, and observer-task handles.
/// Observer cancellation and continuation resumption happen only after the
/// critical section, so neither operation can re-enter while the lock is held.
final class ProviderStartupRace: @unchecked Sendable {
    private let provider: Task<Void, Error>
    private let cancellation: CancellationSignal
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var providerObserver: Task<Void, Never>?
    private var cancellationObserver: Task<Void, Never>?

    init(provider: Task<Void, Error>, cancellation: CancellationSignal) {
        self.provider = provider
        self.cancellation = cancellation
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            start(continuation)
        }
    }

    private func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: VoiceError.cancelled)
            return
        }
        self.continuation = continuation
        lock.unlock()

        installProviderObserver(Task { [self] in
            do {
                try await provider.value
                complete(.success(()))
            } catch {
                complete(.failure(error))
            }
        })
        installCancellationObserver(Task { [self] in
            do {
                try await cancellation.wait()
                complete(.failure(VoiceError.cancelled))
            } catch {
                complete(.failure(error))
            }
        })
    }

    private func installProviderObserver(_ observer: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            observer.cancel()
        } else {
            providerObserver = observer
            lock.unlock()
        }
    }

    private func installCancellationObserver(_ observer: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            observer.cancel()
        } else {
            cancellationObserver = observer
            lock.unlock()
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        let providerObserver = self.providerObserver
        let cancellationObserver = self.cancellationObserver
        lock.unlock()

        // These are observers only. Cancelling them must never cancel the
        // provider task itself; the coordinator retains that task explicitly
        // when cancellation wins.
        providerObserver?.cancel()
        cancellationObserver?.cancel()
        continuation.resume(with: result)
    }
}

/// Races observation of an unstructured task against a timeout without
/// cancelling the observed task. The observed task may still be cleaning up;
/// the owner retains it and can reconcile on a later close.
/// SAFETY: `lock` protects the winner flag, waiter, and observer-task handles.
/// Task cancellation and continuation resumption happen only after unlocking.
final class BoundedTaskRace<Value: Sendable>: @unchecked Sendable {
    private let task: Task<Value, Never>
    private let timeout: Duration
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Value?, Never>?
    private var valueTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(task: Task<Value, Never>, timeout: Duration) {
        self.task = task
        self.timeout = timeout
    }

    func start(_ continuation: CheckedContinuation<Value?, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        let valueTask = Task { [self] in
            complete(await task.value)
        }
        install(valueTask: valueTask)

        let timeoutTask = Task { [self] in
            do {
                try await Task.sleep(for: timeout)
                complete(nil)
            } catch {
                // The value side won the race.
            }
        }
        install(timeoutTask: timeoutTask)
    }

    private func install(valueTask: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            valueTask.cancel()
        } else {
            self.valueTask = valueTask
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

    private func complete(_ value: Value?) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        let valueTask = self.valueTask
        let timeoutTask = self.timeoutTask
        lock.unlock()

        valueTask?.cancel()
        timeoutTask?.cancel()
        continuation.resume(returning: value)
    }
}
