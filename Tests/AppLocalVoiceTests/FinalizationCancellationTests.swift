import XCTest
@testable import AppLocalVoice

final class FinalizationCancellationTests: XCTestCase {
    func testCancellationDuringFinalizationCannotReturnStaleSuccess() async throws {
        let input = BlockingFinalizationInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        try await coordinator.startListening()

        let finishing = Task { try await coordinator.endListening() }
        await input.waitUntilStopEntered()
        finishing.cancel()
        await coordinator.cancelListening()
        let pendingState = await coordinator.state
        XCTAssertEqual(pendingState, .failed)
        await input.releaseStop()

        do {
            _ = try await finishing.value
            XCTFail("cancelled finalization unexpectedly returned text")
        } catch is CancellationError {
            // Swift task cancellation is acceptable at this test boundary.
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let reconciled = await coordinator.closeAndReport()
        XCTAssertTrue(reconciled)
        let state = await coordinator.state
        let balanced = await input.ledger.isBalanced()
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(balanced)
    }

    func testIndependentCancelDuringFinalizationCannotReturnCompletedText() async throws {
        let input = BlockingFinalizationInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        try await coordinator.startListening()

        let finishing = Task { try await coordinator.endListening() }
        await input.waitUntilStopEntered()
        let cancelling = Task { await coordinator.cancelListening() }
        await input.waitUntilCancelEntered()
        await cancelling.value
        let pendingState = await coordinator.state
        XCTAssertEqual(pendingState, .failed)
        await input.releaseStop()

        do {
            _ = try await finishing.value
            XCTFail("independent cancellation unexpectedly allowed completed text")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let reconciled = await coordinator.closeAndReport()
        XCTAssertTrue(reconciled)
        let state = await coordinator.state
        let balanced = await input.ledger.isBalanced()
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(balanced)
    }

    func testCloseDuringFinalizationCancelsAndReleasesResources() async throws {
        let input = BlockingFinalizationInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        try await coordinator.startListening()

        let finishing = Task { try await coordinator.endListening() }
        await input.waitUntilStopEntered()
        let closing = Task { await coordinator.close() }
        await input.waitUntilCancelEntered()
        await input.releaseStop()
        await closing.value

        do {
            _ = try await finishing.value
            XCTFail("close unexpectedly allowed finalization to complete")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let state = await coordinator.state
        let balanced = await input.ledger.isBalanced()
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(balanced)
    }

    func testCloseDoesNotReportSuccessWhileFinalizationIgnoresCancellation() async throws {
        let input = BlockingFinalizationInput()
        let coordinator = VoiceCoordinator(
            input: input,
            output: ControlledSpeechOutput(),
            cleanupTimeout: .milliseconds(30)
        )
        try await coordinator.startListening()

        let finishing = Task { try await coordinator.endListening() }
        await input.waitUntilStopEntered()

        let closedBeforeStopReturns = await coordinator.closeAndReport()
        XCTAssertFalse(closedBeforeStopReturns)
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .failed)
        let failedBalanced = await input.ledger.isBalanced()
        XCTAssertTrue(failedBalanced)

        await input.releaseStop()
        do {
            _ = try await finishing.value
            XCTFail("cancelled finalization unexpectedly returned text")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }

        let closedAfterReconciliation = await coordinator.closeAndReport()
        XCTAssertTrue(closedAfterReconciliation)
        let idleState = await coordinator.state
        XCTAssertEqual(idleState, .idle)
    }
}

private actor BlockingFinalizationInput: SpeechInput {
    let ledger = ResourceLedger()
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var stopEnteredWaiter: CheckedContinuation<Void, Never>?
    private var cancelEnteredWaiter: CheckedContinuation<Void, Never>?
    private var streamContinuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private var cancelEntered = false
    private var stopReleased = false
    private var active = false

    func capabilities(for locale: Locale) async -> SpeechCapabilities {
        SpeechCapabilities(locale: locale, isSupported: true, supportsOnDevice: true)
    }

    func requestAuthorization() async -> SpeechAuthorization { .authorized }
    func requestMicrophonePermission() async -> Bool { true }

    func start(configuration: RecognitionConfiguration) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        active = true
        await ledger.acquire(.microphone)
        // Keep the provider stream open until the explicit stop/cancel
        // boundary. Returning an already-finished stream introduces a race
        // with the coordinator's normal-completion recovery path and can
        // prevent this finalization test from ever entering `stop()`.
        return AsyncThrowingStream { continuation in
            self.streamContinuation = continuation
        }
    }

    func stop() async throws -> String {
        stopEnteredWaiter?.resume()
        stopEnteredWaiter = nil
        if !stopReleased {
            await withCheckedContinuation { stopWaiter = $0 }
        }
        streamContinuation?.finish()
        streamContinuation = nil
        await releaseIfNeeded()
        return "stale"
    }

    func cancel() async {
        cancelEntered = true
        cancelEnteredWaiter?.resume()
        cancelEnteredWaiter = nil
        streamContinuation?.finish()
        streamContinuation = nil
        await releaseIfNeeded()
    }

    func waitUntilStopEntered() async {
        if stopWaiter != nil || stopReleased { return }
        await withCheckedContinuation { stopEnteredWaiter = $0 }
    }

    func waitUntilCancelEntered() async {
        if cancelEntered { return }
        await withCheckedContinuation { continuation in
            cancelEnteredWaiter = continuation
        }
    }

    func releaseStop() {
        stopReleased = true
        stopWaiter?.resume()
        stopWaiter = nil
    }

    private func releaseIfNeeded() async {
        guard active else { return }
        active = false
        await ledger.release(.microphone)
    }
}
