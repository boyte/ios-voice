import XCTest
@testable import AppLocalVoice

final class AudioSessionControllerTests: XCTestCase {
    func testNestedLeasesActivateOnceAndReleaseOnlyAfterTheFinalExit() async throws {
        let driver = TestAudioSessionDriver()
        let controller = AudioSessionController(driver: driver)

        try await controller.enter()
        try await controller.enter()
        XCTAssertEqual(driver.configureCalls, 1)
        XCTAssertEqual(driver.activationCalls, 1)
        XCTAssertEqual(driver.deactivationCalls, 0)

        try await controller.exit()
        XCTAssertEqual(driver.deactivationCalls, 0)
        try await controller.exit()
        XCTAssertEqual(driver.deactivationCalls, 1)
        XCTAssertEqual(driver.restoreCalls, 1)
        XCTAssertEqual(driver.activeBalance, 0)
    }

    func testFinalReleaseDeactivatesExactlyOnceBeforeRestoring() async throws {
        let driver = TestAudioSessionDriver()
        let controller = AudioSessionController(driver: driver)

        try await controller.enter()
        try await controller.exit()

        XCTAssertEqual(driver.deactivationCalls, 1)
        XCTAssertEqual(driver.restoreCalls, 1)
        XCTAssertEqual(driver.transitionEvents, [.deactivate, .restore])
    }

    func testExitIsIdempotentAfterAllLeasesAreReleased() async throws {
        let driver = TestAudioSessionDriver()
        let controller = AudioSessionController(driver: driver)

        try await controller.exit()
        try await controller.enter()
        try await controller.exit()
        try await controller.exit()
        try await controller.exit()

        XCTAssertEqual(driver.activationCalls, 1)
        XCTAssertEqual(driver.deactivationCalls, 1)
        XCTAssertEqual(driver.restoreCalls, 1)
        XCTAssertEqual(driver.activeBalance, 0)
    }

    func testActivationFailureDoesNotLeaveAStuckLease() async throws {
        let driver = TestAudioSessionDriver()
        let controller = AudioSessionController(driver: driver)
        driver.activationError = TestAudioSessionError.activation

        do {
            try await controller.enter()
            XCTFail("activation should fail")
        } catch let error as TestAudioSessionError {
            XCTAssertEqual(error, .activation)
        }

        driver.activationError = nil
        try await controller.enter()
        try await controller.exit()

        XCTAssertEqual(driver.activationCalls, 2)
        // The failed activation is reconciled before the retry. Normal exit
        // restores the host configuration without blindly deactivating it.
        XCTAssertEqual(driver.deactivationCalls, 2)
        XCTAssertEqual(driver.restoreCalls, 2)
        XCTAssertEqual(driver.activeBalance, 0)
    }

    func testActivationFailureAfterPartialSystemMutationIsReconciledBeforeRetry() async throws {
        let driver = TestAudioSessionDriver()
        let controller = AudioSessionController(driver: driver)
        driver.activationError = TestAudioSessionError.activation
        driver.mutateBeforeActivationFailure = true

        do {
            try await controller.enter()
            XCTFail("activation should fail")
        } catch let error as TestAudioSessionError {
            XCTAssertEqual(error, .activation)
        }
        XCTAssertEqual(driver.activeBalance, 1, "the fake models an ambiguous partial activation")

        driver.activationError = nil
        driver.mutateBeforeActivationFailure = false
        try await controller.enter()
        try await controller.exit()

        XCTAssertEqual(driver.deactivationCalls, 2)
        XCTAssertEqual(driver.restoreCalls, 2)
        XCTAssertEqual(driver.activeBalance, 0)
    }

    func testRestorationFailureClosesTheLeaseAndAllowsRecovery() async throws {
        let driver = TestAudioSessionDriver()
        let controller = AudioSessionController(driver: driver)

        try await controller.enter()
        driver.restoreError = TestAudioSessionError.restoration
        do {
            try await controller.exit()
            XCTFail("restoration should fail")
        } catch let error as TestAudioSessionError {
            XCTAssertEqual(error, .restoration)
        }

        driver.restoreError = nil
        try await controller.enter()
        try await controller.exit()

        XCTAssertEqual(driver.activationCalls, 2)
        // The next enter explicitly reconciles the rejected final restore.
        XCTAssertEqual(driver.deactivationCalls, 3)
        XCTAssertEqual(driver.restoreCalls, 3)
        XCTAssertEqual(driver.activeBalance, 0)
    }

    func testReconciliationNeverOverwritesAHostChangeAfterFailedRelease() async throws {
        let driver = TestAudioSessionDriver()
        let controller = AudioSessionController(driver: driver)

        try await controller.enter()
        driver.restoreError = TestAudioSessionError.restoration
        do {
            try await controller.exit()
            XCTFail("restoration should fail")
        } catch let error as TestAudioSessionError {
            XCTAssertEqual(error, .restoration)
        }
        let deactivationCalls = driver.deactivationCalls
        let restoreCalls = driver.restoreCalls

        driver.restoreError = nil
        driver.mutateAsHost()
        do {
            try await controller.enter()
            XCTFail("a newer host session must block stale reconciliation")
        } catch let error as VoiceError {
            XCTAssertEqual(error.category, .audioSessionUnavailable)
        }

        XCTAssertEqual(driver.deactivationCalls, deactivationCalls)
        XCTAssertEqual(driver.restoreCalls, restoreCalls)
        XCTAssertEqual(driver.snapshot().category, "host.changed")
        XCTAssertEqual(driver.snapshot().mode, "moviePlayback")
    }

    func testFailedReconciliationDoesNotAcquireANewLeaseUntilItSucceeds() async throws {
        let driver = TestAudioSessionDriver()
        let controller = AudioSessionController(driver: driver)

        try await controller.enter()
        driver.restoreError = TestAudioSessionError.restoration
        do {
            try await controller.exit()
            XCTFail("restoration should fail")
        } catch let error as TestAudioSessionError {
            XCTAssertEqual(error, .restoration)
        }

        driver.restoreError = nil
        driver.deactivationError = TestAudioSessionError.deactivation
        // The first retry is reconciliation, not a new activation. It fails
        // deterministically and leaves the controller recoverable.
        do {
            try await controller.enter()
            XCTFail("reconciliation should fail")
        } catch let error as TestAudioSessionError {
            XCTAssertEqual(error, .deactivation)
        }
        XCTAssertEqual(driver.activationCalls, 1)
        XCTAssertEqual(driver.deactivationCalls, 2)

        driver.deactivationError = nil
        try await controller.enter()
        try await controller.exit()

        XCTAssertEqual(driver.activationCalls, 2)
        XCTAssertEqual(driver.deactivationCalls, 4)
        XCTAssertEqual(driver.restoreCalls, 3)
        XCTAssertEqual(driver.activeBalance, 0)
    }

    func testRepeatedExitRetriesPendingReconciliation() async throws {
        let driver = TestAudioSessionDriver()
        let controller = AudioSessionController(driver: driver)

        try await controller.enter()
        driver.restoreError = TestAudioSessionError.restoration
        do {
            try await controller.exit()
            XCTFail("restoration should fail")
        } catch let error as TestAudioSessionError {
            XCTAssertEqual(error, .restoration)
        }

        // A repeated exit is still idempotent at the logical lease boundary,
        // but it must retry the unresolved system restore instead of silently
        // reporting a clean session.
        do {
            try await controller.exit()
            XCTFail("the pending reconciliation should still fail")
        } catch let error as TestAudioSessionError {
            XCTAssertEqual(error, .restoration)
        }
        XCTAssertEqual(driver.deactivationCalls, 2)

        driver.restoreError = nil
        driver.deactivationError = nil
        try await controller.enter()
        try await controller.exit()
        XCTAssertEqual(driver.deactivationCalls, 4)
        XCTAssertEqual(driver.restoreCalls, 4)
        XCTAssertEqual(driver.activeBalance, 0)
    }

    func testIndependentControllersShareOneProcessBroker() async throws {
        let driver = TestAudioSessionDriver()
        let broker = AudioSessionBroker(driver: driver)
        let first = AudioSessionController(broker: broker)
        let second = AudioSessionController(broker: broker)

        try await first.enter(role: .speaking)
        try await second.enter(role: .speaking)
        try await first.exit()
        XCTAssertEqual(driver.activationCalls, 1)
        XCTAssertEqual(driver.restoreCalls, 0)

        try await second.exit()
        XCTAssertEqual(driver.restoreCalls, 1)
        XCTAssertEqual(driver.activeBalance, 0)
    }

    func testDeallocationReleasesEveryNestedLeaseForTheOwner() async throws {
        let driver = TestAudioSessionDriver()
        let broker = AudioSessionBroker(driver: driver)
        weak var deallocatedController: AudioSessionController?

        do {
            let controller = AudioSessionController(broker: broker)
            deallocatedController = controller
            try await controller.enter(role: .speaking)
            try await controller.enter(role: .speaking)
        }

        XCTAssertNil(deallocatedController)
        XCTAssertEqual(driver.restoreCalls, 1)
        XCTAssertEqual(driver.activeBalance, 0)

        let replacement = AudioSessionController(broker: broker)
        try await replacement.enter(role: .speaking)
        try await replacement.exit()
        XCTAssertEqual(driver.activationCalls, 2)
        XCTAssertEqual(driver.restoreCalls, 2)
    }

    func testASecondControllerCannotBeReleasedByAnotherOwnerAfterAnExtraExit() async throws {
        let driver = TestAudioSessionDriver()
        let broker = AudioSessionBroker(driver: driver)
        let first = AudioSessionController(broker: broker)
        let second = AudioSessionController(broker: broker)

        try await first.enter(role: .speaking)
        try await second.enter(role: .speaking)
        try await first.exit()
        try await first.exit()

        XCTAssertEqual(driver.restoreCalls, 0)
        XCTAssertEqual(driver.activeBalance, 1)

        try await second.exit()
        XCTAssertEqual(driver.restoreCalls, 1)
        XCTAssertEqual(driver.activeBalance, 0)
    }

    func testConfigurationFailureDoesNotAttemptActivationOrLeakLease() async throws {
        let driver = TestAudioSessionDriver()
        let controller = AudioSessionController(driver: driver)
        driver.configurationError = TestAudioSessionError.configuration

        do {
            try await controller.enter()
            XCTFail("configuration should fail")
        } catch let error as TestAudioSessionError {
            XCTAssertEqual(error, .configuration)
        }

        XCTAssertEqual(driver.activationCalls, 0)
        XCTAssertEqual(driver.deactivationCalls, 0)
        XCTAssertEqual(driver.activeBalance, 0)
    }

    func testOtherAudioStateIsReadThroughTheDriver() async {
        let driver = TestAudioSessionDriver()
        let controller = AudioSessionController(driver: driver)

        let initiallyPlaying = await controller.isOtherAudioPlaying()
        XCTAssertFalse(initiallyPlaying)
        driver.otherAudioPlaying = true
        let currentlyPlaying = await controller.isOtherAudioPlaying()
        XCTAssertTrue(currentlyPlaying)
    }

    func testLifecycleRejectPolicyRejectsCompetingAudioBeforeChangingTheSession() async {
        let driver = TestAudioSessionDriver()
        driver.otherAudioPlaying = true
        let controller = AudioSessionController(driver: driver)

        do {
            try await controller.enter(
                role: .listening,
                lifecyclePolicy: .init(externalAudio: .reject)
            )
            XCTFail("the reject policy must preserve an active external source")
        } catch let error as VoiceError {
            XCTAssertEqual(
                error,
                .audioSessionUnavailable(
                    "Another audio source is active and the lifecycle policy rejects external audio."
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(driver.configureCalls, 0)
        XCTAssertEqual(driver.activationCalls, 0)
        XCTAssertEqual(driver.activeBalance, 0)
    }

    func testLifecycleExternalAudioPolicyIsForwardedToTheDriver() async throws {
        let driver = TestAudioSessionDriver()
        driver.otherAudioPlaying = true
        let controller = AudioSessionController(driver: driver)
        let policy = AudioLifecyclePolicy(externalAudio: .mix)

        try await controller.enter(role: .listening, lifecyclePolicy: policy)

        XCTAssertEqual(driver.configuredRole, .listening)
        XCTAssertEqual(driver.configuredExternalAudio, .mix)
        XCTAssertEqual(driver.configuredWithOtherAudio, true)
        try await controller.exit()
    }

    func testCoordinatorForwardsStoredLifecyclePolicyThroughTheInputSeam() async throws {
        let input = LifecycleCapturingSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let policy = AudioLifecyclePolicy(
            externalAudio: .interrupt,
            routeChange: .stopAndRequireRestart
        )

        _ = try await coordinator.startSession(configuration: .init(lifecyclePolicy: policy))
        await input.waitUntilStarted()

        let receivedPolicy = await input.receivedLifecyclePolicy
        XCTAssertEqual(receivedPolicy, policy)
        await coordinator.cancelListening()
    }

    func testLegacySpeechInputRejectsCustomLifecyclePolicyInsteadOfIgnoringIt() async {
        let input = LegacyLifecycleSpeechInput()

        do {
            _ = try await input.start(
                configuration: .init(),
                lifecyclePolicy: .init(externalAudio: .mix)
            )
            XCTFail("legacy providers must reject unsupported lifecycle policies")
        } catch let error as VoiceError {
            XCTAssertEqual(
                error,
                .invalidRecognitionConfiguration(
                    "This speech input provider does not support a non-default audio lifecycle policy."
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReentrantBrokerMutationIsRejectedWithoutDoubleActivation() throws {
        let driver = TestAudioSessionDriver()
        let broker = AudioSessionBroker(driver: driver)
        let owner = UUID()
        driver.onConfigure = {
            do {
                try broker.enter(owner: UUID(), role: .speaking)
                XCTFail("A nested broker transition must be rejected")
            } catch {
                XCTAssertEqual((error as? VoiceError)?.category, .audioSessionUnavailable)
            }
        }

        try broker.enter(owner: owner, role: .speaking)
        try broker.exit(owner: owner)

        XCTAssertEqual(driver.activationCalls, 1)
        XCTAssertEqual(driver.restoreCalls, 1)
    }

    func testHostMutationIsNeverOverwrittenByStaleVoiceSnapshot() async throws {
        let driver = TestAudioSessionDriver()
        let controller = AudioSessionController(driver: driver)
        try await controller.enter()
        driver.mutateAsHost()

        do {
            try await controller.exit()
            XCTFail("Host ownership conflict should remain visible")
        } catch let error as VoiceError {
            XCTAssertEqual(error.category, .audioSessionUnavailable)
        }

        XCTAssertEqual(driver.restoreCalls, 0)
        XCTAssertEqual(driver.snapshot().category, "host.changed")
    }

    func testPreferenceDriftPreservesNewerValuesWhileRestoringManagedConfiguration() async throws {
        let driver = TestAudioSessionDriver()
        let controller = AudioSessionController(driver: driver)
        try await controller.enter()
        driver.mutatePreferences(
            sampleRate: 48_000,
            bufferDuration: 0.012,
            inputUID: "runtime-input"
        )

        try await controller.exit()

        XCTAssertEqual(driver.deactivationCalls, 1)
        XCTAssertEqual(driver.restoreCalls, 1)
        XCTAssertEqual(driver.snapshot().category, "host.original")
        XCTAssertEqual(driver.snapshot().mode, "default")
        XCTAssertEqual(driver.snapshot().preferredSampleRate, 48_000)
        XCTAssertEqual(driver.snapshot().preferredIOBufferDuration, 0.012)
        XCTAssertEqual(driver.snapshot().preferredInputUID, "runtime-input")
        XCTAssertEqual(driver.activeBalance, 0)
    }

    func testUnchangedManagedPreferencesRestoreTheOriginalHostValues() async throws {
        let driver = TestAudioSessionDriver()
        driver.setHostPreferences(
            sampleRate: 44_100,
            bufferDuration: 0.006,
            inputUID: "host-input"
        )
        let controller = AudioSessionController(driver: driver)

        try await controller.enter()
        try await controller.exit()

        XCTAssertEqual(driver.snapshot().preferredSampleRate, 44_100)
        XCTAssertEqual(driver.snapshot().preferredIOBufferDuration, 0.006)
        XCTAssertEqual(driver.snapshot().preferredInputUID, "host-input")
    }
}

private enum TestAudioSessionError: Error, Equatable {
    case configuration
    case activation
    case deactivation
    case restoration
}

private enum TestAudioSessionTransition: Equatable {
    case deactivate
    case restore
}

private final class TestAudioSessionDriver: @unchecked Sendable, AudioSessionDriver {
    var otherAudioPlaying = false
    var configurationError: TestAudioSessionError?
    var activationError: TestAudioSessionError?
    var deactivationError: TestAudioSessionError?
    var mutateBeforeActivationFailure = false

    private(set) var configureCalls = 0
    private(set) var activationCalls = 0
    private(set) var deactivationCalls = 0
    private(set) var restoreCalls = 0
    private(set) var activeBalance = 0
    private(set) var transitionEvents: [TestAudioSessionTransition] = []
    private(set) var configuredRole: AudioSessionRole?
    private(set) var configuredExternalAudio: ExternalAudioPolicy?
    private(set) var configuredWithOtherAudio: Bool?
    var restoreError: TestAudioSessionError?
    var onConfigure: (() -> Void)?
    private var currentSnapshot = AudioSessionSnapshot(
        category: "host.original",
        mode: "default",
        routeSharingPolicy: 0,
        categoryOptions: 0,
        preferredSampleRate: 0,
        preferredIOBufferDuration: 0,
        preferredInputUID: nil
    )

    func configureForVoice() throws {
        configureCalls += 1
        currentSnapshot = AudioSessionSnapshot(
            category: "voice",
            mode: "voicePrompt",
            routeSharingPolicy: 0,
            categoryOptions: 0,
            preferredSampleRate: 0,
            preferredIOBufferDuration: 0,
            preferredInputUID: nil
        )
        onConfigure?()
        if let configurationError { throw configurationError }
    }

    func configure(
        for role: AudioSessionRole,
        externalAudio: ExternalAudioPolicy,
        isOtherAudioPlaying: Bool
    ) throws {
        configuredRole = role
        configuredExternalAudio = externalAudio
        configuredWithOtherAudio = isOtherAudioPlaying
        try configureForVoice()
    }

    func setActive(_ active: Bool) throws {
        if active {
            activationCalls += 1
            if mutateBeforeActivationFailure { activeBalance = 1 }
            if let activationError { throw activationError }
            // AVAudioSession activation is idempotent at the system boundary:
            // a retry after a rejected deactivation does not represent a
            // second physical activation lease.
            if activeBalance == 0 { activeBalance = 1 }
        } else {
            deactivationCalls += 1
            transitionEvents.append(.deactivate)
            if let deactivationError { throw deactivationError }
            // The real AVAudioSession accepts deactivation when the session
            // is already inactive; model that idempotent boundary explicitly.
            activeBalance = max(0, activeBalance - 1)
        }
    }

    func snapshot() -> AudioSessionSnapshot { currentSnapshot }

    func restore(_ snapshot: AudioSessionSnapshot) throws {
        restoreCalls += 1
        transitionEvents.append(.restore)
        if let restoreError { throw restoreError }
        currentSnapshot = snapshot
        activeBalance = 0
    }

    func mutateAsHost() {
        currentSnapshot = AudioSessionSnapshot(
            category: "host.changed",
            mode: "moviePlayback",
            routeSharingPolicy: 0,
            categoryOptions: 0,
            preferredSampleRate: 48_000,
            preferredIOBufferDuration: 0.01,
            preferredInputUID: nil
        )
    }

    func mutatePreferences(
        sampleRate: Double,
        bufferDuration: Double,
        inputUID: String?
    ) {
        currentSnapshot = AudioSessionSnapshot(
            category: currentSnapshot.category,
            mode: currentSnapshot.mode,
            routeSharingPolicy: currentSnapshot.routeSharingPolicy,
            categoryOptions: currentSnapshot.categoryOptions,
            preferredSampleRate: sampleRate,
            preferredIOBufferDuration: bufferDuration,
            preferredInputUID: inputUID
        )
    }

    func setHostPreferences(
        sampleRate: Double,
        bufferDuration: Double,
        inputUID: String?
    ) {
        mutatePreferences(
            sampleRate: sampleRate,
            bufferDuration: bufferDuration,
            inputUID: inputUID
        )
    }

    var isOtherAudioPlaying: Bool { otherAudioPlaying }
}

private actor LifecycleCapturingSpeechInput: SpeechInput {
    private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var receivedLifecyclePolicy: AudioLifecyclePolicy?

    func capabilities(for locale: Locale) async -> SpeechCapabilities {
        SpeechCapabilities(locale: locale, isSupported: true, supportsOnDevice: true)
    }

    func requestAuthorization() async -> SpeechAuthorization { .authorized }
    func requestMicrophonePermission() async -> Bool { true }

    func start(configuration: RecognitionConfiguration) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        try await start(configuration: configuration, lifecyclePolicy: .init())
    }

    func start(
        configuration: RecognitionConfiguration,
        lifecyclePolicy: AudioLifecyclePolicy
    ) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        receivedLifecyclePolicy = lifecyclePolicy
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func stop() async throws -> String {
        continuation?.finish()
        continuation = nil
        return ""
    }

    func cancel() async {
        continuation?.finish()
        continuation = nil
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private actor LegacyLifecycleSpeechInput: SpeechInput {
    func capabilities(for locale: Locale) async -> SpeechCapabilities {
        SpeechCapabilities(locale: locale, isSupported: true, supportsOnDevice: true)
    }

    func requestAuthorization() async -> SpeechAuthorization { .authorized }
    func requestMicrophonePermission() async -> Bool { true }

    func start(configuration: RecognitionConfiguration) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stop() async throws -> String { "" }
    func cancel() async {}
}
