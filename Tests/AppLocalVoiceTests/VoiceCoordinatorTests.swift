import XCTest
@testable import AppLocalVoice

final class VoiceCoordinatorTests: XCTestCase {
    func testCapabilitySnapshotReportsMissingInstallableRecognitionModel() async {
        let input = MinimalSpeechInput()
        await input.setCapabilities(SpeechCapabilities(
            locale: Locale(identifier: "en-US"),
            isSupported: true,
            supportsOnDevice: false,
            reason: "The speech model is not installed yet."
        ))
        await input.setModelInstallationAvailable(true)
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        let snapshot = await coordinator.capabilitySnapshot(
            for: Locale(identifier: "en-US")
        )

        XCTAssertEqual(
            snapshot.recognition.modelReadiness,
            .notInstalled(installationAvailable: true)
        )
        XCTAssertEqual(snapshot.features[.modelInstallation], .available)
    }

    func testVoiceTurnUsesInjectedInputAndOutput() async throws {
        let input = ControlledSpeechInput()
        let output = ControlledSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)

        try await coordinator.startTurn()
        await input.send(TranscriptUpdate(text: "hello", isFinal: false))
        let text = try await coordinator.finishTurn()

        XCTAssertEqual(text, "hello")
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)

        let speaking = Task { try await coordinator.speakNow("world") }
        await output.waitUntilStarted()
        await output.complete(.success(()))
        try await withBoundedTimeout { try await speaking.value }
        let spokenTexts = await output.spoken
        XCTAssertEqual(spokenTexts, ["world"])
    }

    func testAllowModelInstallationReachesInputProvider() async throws {
        let input = ControlledSpeechInput()
        await input.setCapabilities(SpeechCapabilities(
            locale: .current,
            isSupported: true,
            supportsOnDevice: false
        ))
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        try await coordinator.startTurn(configuration: .init(policy: .allowModelInstallation))

        let configuration = await input.lastConfiguration
        let startCount = await input.starts
        XCTAssertEqual(configuration?.policy, .allowModelInstallation)
        XCTAssertEqual(startCount, 1)
        await coordinator.cancelTurn()
    }

    func testInstalledOnlyPolicyRejectsUnavailableModelAndUnwindsInput() async throws {
        let input = ControlledSpeechInput()
        await input.setCapabilities(SpeechCapabilities(
            locale: .current,
            isSupported: true,
            supportsOnDevice: false
        ))
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        do {
            try await coordinator.startTurn()
            XCTFail("Expected installed-only policy failure")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .onDeviceRecognitionUnavailable(.current))
        }

        let startCount = await input.starts
        let cancelCount = await input.cancels
        let isActive = await input.isActive
        let state = await coordinator.state
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(isActive)
        XCTAssertEqual(state, .idle)
        let kinds = try await withBoundedTimeout { try await kindsTask.value }
        let outcomes = kinds.compactMap(\.outcome)
        XCTAssertEqual(outcomes.count, 1)
        guard case .failed(let failure)? = outcomes.first else {
            return XCTFail("Expected a failed terminal outcome, got \(String(describing: outcomes.first))")
        }
        XCTAssertEqual(failure.category, VoiceError.onDeviceRecognitionUnavailable(.current).category)
    }

    func testStreamFailureCancelsInputAndReturnsToIdle() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        try await coordinator.startTurn()
        await input.failStream(VoiceError.audioSessionUnavailable("route lost"))
        await waitForState(.idle, coordinator: coordinator)
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)

        let cancelCount = await input.cancels
        let isActive = await input.isActive
        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(isActive)
        let kinds = try await withBoundedTimeout { try await kindsTask.value }
        let outcomes = kinds.compactMap(\.outcome)
        XCTAssertEqual(outcomes.count, 1)
        guard case .failed(let failure)? = outcomes.first else {
            return XCTFail("Expected a failed terminal outcome, got \(String(describing: outcomes.first))")
        }
        XCTAssertEqual(failure.category, VoiceError.audioSessionUnavailable("route lost").category)
    }

    func testOversizedProviderTranscriptFailsClosedBeforeFinalization() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        try await coordinator.startTurn()
        await input.send(TranscriptUpdate(
            text: String(repeating: "x", count: VoiceTextLimits.maximumUTF16Length + 1),
            isFinal: false
        ))
        await waitForState(.idle, coordinator: coordinator)
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)

        let kinds = try await withBoundedTimeout { try await kindsTask.value }
        let outcomes = kinds.compactMap(\.outcome)
        XCTAssertEqual(outcomes.count, 1)
        guard case .failed(let failure)? = outcomes.first else {
            return XCTFail("Expected a failed terminal outcome, got \(String(describing: outcomes.first))")
        }
        XCTAssertEqual(
            failure.category,
            VoiceError.textTooLong(maximumUTF16Length: VoiceTextLimits.maximumUTF16Length).category
        )
    }

    func testUnexpectedNormalInputStreamCompletionProducesAFailureTerminal() async throws {
        let input = MinimalSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        try await coordinator.startTurn()
        await input.finishStreamNormally()
        await waitForState(.idle, coordinator: coordinator)
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)

        let kinds = try await withBoundedTimeout { try await kindsTask.value }
        let outcomes = kinds.compactMap(\.outcome)
        XCTAssertEqual(outcomes.count, 1)
        guard case .failed(let failure)? = outcomes.first else {
            return XCTFail("Expected a failed terminal outcome, got \(String(describing: outcomes.first))")
        }
        XCTAssertEqual(
            failure.category,
            VoiceError.underlying("Speech input ended before finalization.").category
        )
    }

    func testInterruptionHasItsOwnTerminalReasonWithoutFailureEvent() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        try await coordinator.startTurn()
        await input.failStream(VoiceError.interrupted("phone call"))
        await waitForState(.idle, coordinator: coordinator)
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)

        let kinds = try await withBoundedTimeout { try await kindsTask.value }
        let outcomes = kinds.compactMap(\.outcome)
        XCTAssertEqual(outcomes, [.interrupted(.systemInterruption)])
    }

    func testFinishFailureCancelsInputAndRecoversFromFinalizing() async throws {
        let input = ControlledSpeechInput()
        let finalizationFailure = HarnessFailure(stage: .finalization, message: "finalization failed")
        await input.setFailure(finalizationFailure)
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        try await coordinator.startTurn()
        do {
            _ = try await coordinator.finishTurn()
            XCTFail("Expected finalization failure")
        } catch let error as HarnessFailure {
            XCTAssertEqual(error, finalizationFailure)
        }

        let cancelCount = await input.cancels
        let isActive = await input.isActive
        let state = await coordinator.state
        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(isActive)
        XCTAssertEqual(state, .idle)

        // Recovery is real, not just a state reset: a new turn can start.
        await input.setFailure(nil)
        try await coordinator.startTurn()
        await coordinator.cancelTurn()
    }

    func testConcurrentStartsHaveOneWinnerBeforeAsyncStartupCompletes() async throws {
        let input = ControlledSpeechInput()
        await input.setStartBlocked(true)
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        let first = Task { try await coordinator.startTurn() }
        await input.waitForStartEntry()

        do {
            try await coordinator.startTurn()
            XCTFail("Expected the reserved operation to reject a concurrent start")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .invalidState("A voice operation is already active."))
        }

        await input.setStartBlocked(false)
        try await withBoundedTimeout { _ = try await first.value }
        await coordinator.cancelTurn()
        let startCount = await input.starts
        XCTAssertEqual(startCount, 1)
    }

    func testExternalCancellationSuppressesAStaleProviderStartupError() async throws {
        let input = ControlledSpeechInput()
        await input.setStartBlocked(true)
        await input.setFailure(HarnessFailure(stage: .hostAudioCoexistence, message: "stale provider error"))
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        let starting = Task { try await coordinator.startTurn() }
        await input.waitForStartEntry()
        let cancelling = Task { await coordinator.cancelTurn() }
        await Task.yield()
        await input.setStartBlocked(false)
        await cancelling.value

        do {
            _ = try await withBoundedTimeout { try await starting.value }
            XCTFail("cancelled startup unexpectedly succeeded")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        await waitForState(.idle, coordinator: coordinator)
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    func testConcurrentSpeechIsRejectedAndStopCancelsOnlyTheWinner() async throws {
        let input = ControlledSpeechInput()
        let output = ControlledSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)

        let first = Task { try await coordinator.speakNow("first") }
        await output.waitUntilStarted()

        do {
            try await coordinator.speakNow("second")
            XCTFail("Expected the reserved speech operation to reject a concurrent speak")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .invalidState("A voice operation is already active."))
        }

        await coordinator.stopSpeaking()
        do {
            try await withBoundedTimeout { try await first.value }
            XCTFail("Expected the first speech operation to be cancelled")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        } catch is CancellationError {
            // Task cancellation may win before the coordinator normalizes it.
        }
        await waitForState(.idle, coordinator: coordinator)
        let spokenTexts = await output.spoken
        let state = await coordinator.state
        XCTAssertEqual(spokenTexts, ["first"])
        XCTAssertEqual(state, .idle)
    }

    func testPreCancelledSpeechNeverReentersTheOutputProvider() async throws {
        let input = ControlledSpeechInput()
        let output = ControlledSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)

        let task = Task { try await coordinator.speakNow("should not start") }
        task.cancel()

        do {
            try await withBoundedTimeout { try await task.value }
            XCTFail("pre-cancelled speech unexpectedly succeeded")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        } catch is CancellationError {
            // Task cancellation may win before the coordinator normalizes it.
        }
        let startCount = await output.spoken.count
        let state = await coordinator.state
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(state, .idle)
    }

    func testUnreleasedSpeechResourcesKeepTheCoordinatorFailedUntilCloseRetry() async throws {
        let input = ControlledSpeechInput()
        let output = LateUnreleasedSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)
        let acceptance = try await coordinator.speakImmediately("resource failure")
        do {
            try await withBoundedTimeout { try await coordinator.awaitPlayback(acceptance.playbackID) }
            XCTFail("a provider that retains audio resources must fail the speech turn")
        } catch let error as VoiceError {
            // The canonical immediate-playback result reports unreleased
            // resources as a stopped playback; the typed failure is visible
            // through the coordinator's `.failed` state below.
            XCTAssertEqual(error, .cancelled)
        }
        let result = try await coordinator.waitForSpeechPlayback(acceptance.playbackID)
        XCTAssertEqual(result.outcome, .cancelled(.stopped))

        await waitForState(.failed, coordinator: coordinator)
        let failedState = await coordinator.state
        let closeBeforeRelease = await coordinator.closeAndReport()
        let stillFailedState = await coordinator.state
        XCTAssertEqual(failedState, .failed)
        XCTAssertFalse(closeBeforeRelease)
        XCTAssertEqual(stillFailedState, .failed)

        await output.setReleased(true)
        let closeAfterRelease = await coordinator.closeAndReport()
        let recoveredState = await coordinator.state
        let startCount = await input.starts
        XCTAssertTrue(closeAfterRelease)
        XCTAssertEqual(recoveredState, .idle)
        XCTAssertEqual(startCount, 0)
    }

    func testSuccessfulListeningEmitsOneTerminalReason() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        try await coordinator.startTurn()
        _ = try await coordinator.finishTurn()

        let kinds = try await withBoundedTimeout { try await kindsTask.value }
        XCTAssertEqual(kinds.compactMap(\.outcome), [.completed])
    }

    func testCancellingTheSessionEmitsCancelledTerminalReasonAndIsIdempotent() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        try await coordinator.startTurn()
        await coordinator.cancelTurn()
        await coordinator.cancelTurn()

        let kinds = try await withBoundedTimeout { try await kindsTask.value }
        let cancelCount = await input.cancels
        XCTAssertEqual(kinds.compactMap(\.outcome), [.cancelled])
        XCTAssertEqual(cancelCount, 1)
    }
}

/// A minimal input seam for behavior the shared `ControlledSpeechInput` does
/// not model: reporting an installable recognition model and ending the
/// transcript stream normally without a stop/cancel.
private actor MinimalSpeechInput: SpeechInput {
    private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private var latest = ""
    private var capabilitiesValue = SpeechCapabilities(locale: .current, isSupported: true, supportsOnDevice: true)
    private var modelInstallationIsAvailable = false
    private var isActive = false

    func setCapabilities(_ value: SpeechCapabilities) { capabilitiesValue = value }
    func setModelInstallationAvailable(_ value: Bool) {
        modelInstallationIsAvailable = value
    }

    func capabilities(for locale: Locale) async -> SpeechCapabilities {
        SpeechCapabilities(
            locale: locale,
            isSupported: capabilitiesValue.isSupported,
            supportsOnDevice: capabilitiesValue.supportsOnDevice,
            reason: capabilitiesValue.reason
        )
    }

    func modelInstallationAvailable(for locale: Locale) async -> Bool {
        modelInstallationIsAvailable
    }

    func requestMicrophonePermission() async -> Bool { true }
    func requestAuthorization() async -> VoicePermissionStatus { .authorized }

    func start(configuration: RecognitionConfiguration, input: RecognitionInput, lifecyclePolicy: AudioLifecyclePolicy) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        isActive = true
        return AsyncThrowingStream { continuation in self.continuation = continuation }
    }

    func finishStreamNormally() {
        continuation?.finish()
        continuation = nil
    }

    func stop() async throws -> String {
        isActive = false
        continuation?.finish()
        continuation = nil
        return latest
    }

    func cancel() async {
        guard isActive else { return }
        isActive = false
        continuation?.finish()
        continuation = nil
    }
}

/// Kept private: the shared `ControlledSpeechOutput` does not override
/// `resourcesAreReleased()`, so it cannot model a provider that retains audio
/// resources after its request completes.
private actor LateUnreleasedSpeechOutput: SpeechOutput {
    private var released = true

    func availableVoices(for locale: Locale) async -> [SpeechVoice] { [] }

    func speak(_ text: String, configuration: SpeechConfiguration, lifecyclePolicy: AudioLifecyclePolicy) async throws {
        released = false
    }

    func pause() async {}
    func resume() async {}
    func stop() async {}

    func resourcesAreReleased() async -> Bool { released }

    func setReleased(_ value: Bool) { released = value }
}
