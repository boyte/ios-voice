import AVFAudio
import Speech
import UIKit
import XCTest
@testable import AppLocalVoice

final class AppleSpeechInputSeamTests: XCTestCase {
    func testProviderReadinessAndCaptureShareOneTranscriberConstructionSite() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/AppLocalVoice/AppleSpeechInput.swift")
        let source = String(decoding: try Data(contentsOf: sourceURL), as: UTF8.self)

        XCTAssertEqual(
            source.components(separatedBy: "SpeechTranscriber(").count - 1,
            1,
            "The shared factory must remain the sole SpeechTranscriber construction site."
        )

        let capabilities = try sourceSlice(
            source,
            from: "    func capabilities(for locale: Locale)",
            to: "    func modelInstallationAvailable(for locale: Locale)"
        )
        let preparation = try sourceSlice(
            source,
            from: "    func prepareRecognition(for locale: Locale",
            to: "    func start(configuration: RecognitionConfiguration)"
        )
        let capture = try sourceSlice(
            source,
            from: "    func start(\n        configuration: RecognitionConfiguration,",
            to: "    func stop() async throws -> String"
        )

        for path in [capabilities, preparation, capture] {
            XCTAssertTrue(
                path.contains("makeLiveRecognitionTranscriber(locale:"),
                "Capability, preparation, and capture paths must use the shared live module factory."
            )
        }
    }

    func testLiveRecognitionPresetMatchesCaptureConfiguration() {
        var expected = SpeechTranscriber.Preset.progressiveTranscription
        expected.attributeOptions.insert(.audioTimeRange)

        XCTAssertEqual(liveRecognitionTranscriberPreset(), expected)
    }

    func testOnlyExactInstalledModuleStatusIsReady() {
        XCTAssertFalse(recognitionModuleIsInstalled(.unsupported))
        XCTAssertFalse(recognitionModuleIsInstalled(.supported))
        XCTAssertFalse(recognitionModuleIsInstalled(.downloading))
        XCTAssertTrue(recognitionModuleIsInstalled(.installed))
    }

    func testModelProgressIsContentFreeClampedAndIndeterminateWithoutTotal() {
        let indeterminate = Progress(totalUnitCount: 0)
        XCTAssertEqual(modelDownloadProgress(from: indeterminate), .indeterminate)

        let bounded = Progress(totalUnitCount: 100)
        bounded.completedUnitCount = 150
        XCTAssertEqual(modelDownloadProgress(from: bounded), .fractionCompleted(1))
    }

    func testModelInstallationFailurePreservesOnlyProviderDomainAndCode() {
        let underlying = NSError(
            domain: "com.apple.Speech.AssetError",
            code: 47,
            userInfo: [NSLocalizedDescriptionKey: "private provider detail"]
        )

        let failure = recognitionModelInstallationFailure(
            locale: Locale(identifier: "en-US"),
            underlying: underlying
        )

        guard case .recognitionModelInstallationFailed(let locale, let providerError) = failure else {
            XCTFail("Expected typed model-installation failure")
            return
        }
        XCTAssertEqual(locale.identifier, "en-US")
        XCTAssertEqual(
            providerError,
            VoiceProviderErrorCode(domain: "com.apple.Speech.AssetError", code: 47)
        )
        XCTAssertFalse(failure.localizedDescription.contains("private provider detail"))
    }

    func testDownloadingPreparationWaitsInsteadOfRequestingOrFailingAgain() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppLocalVoice/AppleSpeechInput.swift")
        let source = String(decoding: try Data(contentsOf: sourceURL), as: UTF8.self)
        let preparation = try sourceSlice(
            source,
            from: "    func prepareRecognition(\n        for locale: Locale,",
            to: "    func start(configuration: RecognitionConfiguration)"
        )

        XCTAssertTrue(preparation.contains("if status == .downloading"))
        XCTAssertTrue(preparation.contains("try await awaitInstalledModel("))
        XCTAssertFalse(preparation.contains("postDownloadStatusReconciliationAttempts"))
        XCTAssertFalse(
            preparation.contains("status == .downloading {\n                try await installModelIfNeeded")
        )
    }

    func testInitialUnsupportedStatusCannotEnterAnInstallationRequestPath() async {
        for path in RecognitionPreparationTestPath.allCases {
            let recorder = AssetRuntimeRecorder()
            let runtime = makePreparationRuntime(
                recorder: recorder,
                status: { .unsupported },
                request: { nil }
            )
            let input = makeInput(preparationRuntime: runtime)

            do {
                try await runRecognitionPreparation(path, input: input)
                XCTFail("unsupported status must fail on \(path)")
            } catch let error as VoiceError {
                XCTAssertEqual(error.category, .onDeviceRecognitionUnavailable)
            } catch {
                XCTFail("unexpected error on \(path): \(error)")
            }

            let snapshot = recorder.snapshot()
            XCTAssertEqual(snapshot.requests, 0, "path: \(path)")
            XCTAssertEqual(snapshot.releases, 0, "path: \(path)")
        }
    }

    func testRequestAndDownloadErrorsPreserveProviderDomainAndCodeOnBothPreparationPaths() async {
        let expected = VoiceProviderErrorCode(domain: "com.apple.Speech.AssetError", code: 47)

        for path in RecognitionPreparationTestPath.allCases {
            for phase in ProviderFailurePhase.allCases {
                let recorder = AssetRuntimeRecorder()
                let runtime = makePreparationRuntime(
                    recorder: recorder,
                    status: { .supported },
                    request: {
                        if phase == .request {
                            throw NSError(domain: expected.domain, code: expected.code)
                        }
                        return RecognitionAssetInstallationRequest(
                            downloadProgress: { .indeterminate },
                            downloadAndInstall: {
                                throw NSError(domain: expected.domain, code: expected.code)
                            }
                        )
                    }
                )
                let input = makeInput(preparationRuntime: runtime)

                do {
                    try await runRecognitionPreparation(path, input: input)
                    XCTFail("provider \(phase) failure must fail on \(path)")
                } catch let error as VoiceError {
                    guard case .recognitionModelInstallationFailed(_, let providerError) = error else {
                        XCTFail("expected typed provider failure, got \(error)")
                        continue
                    }
                    XCTAssertEqual(providerError, expected, "path: \(path), phase: \(phase)")
                } catch {
                    XCTFail("unexpected error on \(path): \(error)")
                }
            }
        }
    }

    @MainActor
    func testDownloadingStatusWaitsUntilInstalledWithoutFalseFailure() async throws {
        let statuses = ModelStatusSequence([.downloading, .downloading, .installed])
        var phases: [RecognitionPreparationPhase] = []

        try await awaitRecognitionModelInstalled(
            locale: Locale(identifier: "en-US"),
            pollInterval: .milliseconds(1),
            status: { await statuses.next() },
            downloadProgress: { .indeterminate },
            progress: { phases.append($0) }
        )

        XCTAssertEqual(phases, [
            .downloadingModel(.indeterminate),
            .downloadingModel(.indeterminate),
            .modelInstalled
        ])
    }

    @MainActor
    func testDownloadingStatusWaitIsCancellableWithoutTerminalFailure() async throws {
        let statuses = ModelStatusSequence([.downloading])
        let task = Task {
            try await awaitRecognitionModelInstalled(
                locale: Locale(identifier: "en-US"),
                pollInterval: .seconds(60),
                status: { await statuses.next() },
                downloadProgress: { .indeterminate },
                progress: nil
            )
        }
        await statuses.waitForRead()
        task.cancel()

        do {
            try await task.value
            XCTFail("Cancellation must end the model-status wait")
        } catch is CancellationError {
            // Expected: cancellation is not rewritten as an installation failure.
        }
    }

    @MainActor
    func testSuccessfulOwnedDownloadWaitsThroughSupportedStatusUntilInstalled() async throws {
        let statuses = ModelStatusSequence([.supported, .supported, .installed])
        var phases: [RecognitionPreparationPhase] = []

        try await awaitRecognitionModelInstalled(
            locale: Locale(identifier: "en-US"),
            pollInterval: .milliseconds(1),
            status: { await statuses.next() },
            downloadProgress: { .fractionCompleted(1) },
            progress: { phases.append($0) }
        )

        XCTAssertEqual(phases, [
            .downloadingModel(.fractionCompleted(1)),
            .downloadingModel(.fractionCompleted(1)),
            .modelInstalled
        ])
    }

    @MainActor
    func testJoinedDownloadWaitsThroughSupportedStatusUntilInstalled() async throws {
        let statuses = ModelStatusSequence([.downloading, .supported, .supported, .installed])
        var phases: [RecognitionPreparationPhase] = []

        try await awaitRecognitionModelInstalled(
            locale: Locale(identifier: "en-US"),
            pollInterval: .milliseconds(1),
            status: { await statuses.next() },
            downloadProgress: { .indeterminate },
            progress: { phases.append($0) }
        )

        XCTAssertEqual(phases, [
            .downloadingModel(.indeterminate),
            .downloadingModel(.indeterminate),
            .downloadingModel(.indeterminate),
            .modelInstalled
        ])
    }

    @MainActor
    func testReconciliationToleratesMixedDownloadingAndSupportedStates() async throws {
        let statuses = ModelStatusSequence([
            .downloading, .supported, .downloading, .supported, .installed
        ])
        var phases: [RecognitionPreparationPhase] = []

        try await awaitRecognitionModelInstalled(
            locale: Locale(identifier: "en-US"),
            pollInterval: .milliseconds(1),
            status: { await statuses.next() },
            downloadProgress: { .fractionCompleted(1) },
            progress: { phases.append($0) }
        )

        XCTAssertEqual(phases, [
            .downloadingModel(.fractionCompleted(1)),
            .downloadingModel(.fractionCompleted(1)),
            .downloadingModel(.fractionCompleted(1)),
            .downloadingModel(.fractionCompleted(1)),
            .modelInstalled
        ])
    }

    @MainActor
    func testReconciliationCanOutliveFormerThirtySecondAttemptBudget() async throws {
        let statuses = ModelStatusSequence(
            Array(repeating: .supported, count: 125) + [.installed]
        )

        try await awaitRecognitionModelInstalled(
            locale: Locale(identifier: "en-US"),
            pollInterval: .milliseconds(1),
            status: { await statuses.next() },
            downloadProgress: { .indeterminate },
            progress: nil
        )
    }

    @MainActor
    func testSupportedStatusWaitIsCancellableWithoutTerminalFailure() async throws {
        let statuses = ModelStatusSequence([.supported])
        let task = Task {
            try await awaitRecognitionModelInstalled(
                locale: Locale(identifier: "en-US"),
                pollInterval: .seconds(60),
                status: { await statuses.next() },
                downloadProgress: { .fractionCompleted(1) },
                progress: nil
            )
        }
        await statuses.waitForRead()
        task.cancel()

        do {
            try await task.value
            XCTFail("A supported finalization wait must remain cancellable")
        } catch is CancellationError {
            // Expected: slow inventory publication is not an install failure.
        }
    }

    @MainActor
    func testUnsupportedStatusFailsAsOnDeviceUnavailable() async throws {
        let statuses = ModelStatusSequence([.unsupported])

        do {
            try await awaitRecognitionModelInstalled(
                locale: Locale(identifier: "en-US"),
                pollInterval: .milliseconds(1),
                status: { await statuses.next() },
                downloadProgress: { .fractionCompleted(1) },
                progress: nil
            )
            XCTFail("An authoritative unsupported status must fail")
        } catch let error as VoiceError {
            XCTAssertEqual(error.category, .onDeviceRecognitionUnavailable)
        }
    }

    func testCancelledRequestHandoffReleasesReservationWithoutStartingDownload() async throws {
        let gate = HandoffTestGate()
        let recorder = HandoffRecorder()
        let task = Task {
            await gate.wait()
            try await handOffReservedAssetRequest(
                release: { await recorder.recordRelease() },
                start: { await recorder.recordStart() }
            )
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()

        do {
            try await task.value
            XCTFail("A cancelled handoff must not start the download")
        } catch is CancellationError {
            // Expected.
        }
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.releases, 1)
        XCTAssertEqual(snapshot.starts, 0)
    }

    func testModelReservationPersistsWhenProviderResultWinsGate() async {
        let recorder = HandoffRecorder()

        let gate = ModelInstallationResultGate()
        let didPublish = gate.finish(.success(()))
        await releaseModelReservationIfResultDidNotPublish(didPublish) {
            await recorder.recordRelease()
        }
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.releases, 0)
    }

    func testProviderSuccessThenSupportedReconciliationCancellationRetainsReservation() async {
        for path in RecognitionPreparationTestPath.allCases {
            let recorder = AssetRuntimeRecorder()
            let statuses = ModelStatusSequence([.supported])
            let runtime = makePreparationRuntime(
                recorder: recorder,
                status: { await statuses.next() },
                request: {
                    RecognitionAssetInstallationRequest(
                        downloadProgress: { .fractionCompleted(1) },
                        downloadAndInstall: {}
                    )
                }
            )
            let input = makeInput(preparationRuntime: runtime)
            let task = Task { try await runRecognitionPreparation(path, input: input) }
            await statuses.waitForReads(2)
            task.cancel()

            do {
                try await task.value
                XCTFail("supported reconciliation must remain cancellable on \(path)")
            } catch let error as VoiceError {
                XCTAssertEqual(error, .cancelled)
            } catch {
                XCTFail("unexpected error on \(path): \(error)")
            }

            XCTAssertEqual(recorder.snapshot().releases, 0, "path: \(path)")
        }
    }

    func testCancellationBeforeProviderResultReleasesReservationExactlyOnce() async {
        for path in RecognitionPreparationTestPath.allCases {
            let recorder = AssetRuntimeRecorder()
            let provider = SuspendedProviderResult()
            let runtime = makePreparationRuntime(
                recorder: recorder,
                status: { .supported },
                request: {
                    RecognitionAssetInstallationRequest(
                        downloadProgress: { .indeterminate },
                        downloadAndInstall: { await provider.wait() }
                    )
                }
            )
            let input = makeInput(preparationRuntime: runtime)
            let task = Task { try await runRecognitionPreparation(path, input: input) }
            await provider.waitUntilEntered()
            task.cancel()

            do {
                try await task.value
                XCTFail("caller cancellation must win on \(path)")
            } catch let error as VoiceError {
                XCTAssertEqual(error, .cancelled)
            } catch {
                XCTFail("unexpected error on \(path): \(error)")
            }

            await provider.complete()
            await recorder.waitForReleases(1)
            XCTAssertEqual(recorder.snapshot().releases, 1, "path: \(path)")
        }
    }

    func testModelReservationReleasesWhenCancellationWinsResultGate() async {
        let recorder = HandoffRecorder()
        let gate = ModelInstallationResultGate()

        XCTAssertTrue(gate.finish(.failure(CancellationError())))
        let didPublish = gate.finish(.success(()))
        await releaseModelReservationIfResultDidNotPublish(didPublish) {
            await recorder.recordRelease()
        }
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.releases, 1)
    }

    func testFailedTapRemovalPreservesOwnershipForALaterCleanupAttempt() {
        var installed = true
        var attempts = 0

        XCTAssertFalse(removeTapOwnership(isInstalled: &installed, remove: {
            attempts += 1
            return false
        }))
        XCTAssertTrue(installed)

        XCTAssertTrue(removeTapOwnership(isInstalled: &installed, remove: {
            attempts += 1
            return true
        }))
        XCTAssertFalse(installed)
        XCTAssertEqual(attempts, 2)
    }

    func testNotificationCenterSeamRegistersEveryInputFailureNotification() async {
        let center = RecordingAudioNotificationCenter()
        _ = AppleSpeechInput(
            audioSession: AudioSessionController(),
            engineSafety: RecordingInputSafety(),
            notificationCenter: center
        )

        // Observer installation is scheduled from the actor initializer. A
        // single yield is not a reliable synchronization primitive under the
        // full XCTest runner, so wait only within a small deterministic bound.
        for _ in 0..<32 where center.addCount < 5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(center.names, [
            AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification,
            UIApplication.didEnterBackgroundNotification,
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification
        ])
        XCTAssertEqual(center.addCount, 5)
    }

    func testAnalyzerFailureDriverCanBeConstructedWithoutAppleAnalyzer() async throws {
        let failure = TestAnalyzerFailure.failed
        let driver = FailingSpeechAnalyzerDriver(error: failure)
        let sequence = AsyncStream<AnalyzerInput> { continuation in continuation.finish() }

        do {
            _ = try await driver.analyzeSequence(sequence)
            XCTFail("expected injected analyzer failure")
        } catch let error as TestAnalyzerFailure {
            XCTAssertEqual(error, failure)
        }
    }

    func testEmptyAnalyzerInputUsesOrderlyEndOfInputFinalization() async throws {
        let driver = RecordingSpeechAnalyzerFinalizationDriver()

        try await finalizeAnalyzerInput(lastSample: nil, analyzer: driver)

        let calls = driver.recordedCalls()
        XCTAssertEqual(calls, [.throughEndOfInput])
    }

    func testProductionAnalysisUsesEmptyInputWorkerCancellationBoundary() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppLocalVoice/AppleSpeechInput.swift")
        let source = String(decoding: try Data(contentsOf: sourceURL), as: UTF8.self)
        let analysis = try sourceSlice(
            source,
            from: "        let results = AsyncThrowingStream<TranscriptUpdate, Error>(",
            to: "        let node = audioEngine.inputNode"
        )
        let workerBoundary = try sourceSlice(
            source,
            from: "enum SpeechAnalysisWorkerResult: Sendable",
            to: "final class DefaultAudioEngineSafety"
        )

        XCTAssertTrue(analysis.contains("runSpeechAnalysisWorkers"))
        XCTAssertTrue(workerBoundary.contains("group.cancelAll()"))
    }

    func testEmptyAnalysisCancelsAndJoinsOpenResultWorkerAndCanRunAgain() async throws {
        let recorder = AnalysisWorkerRecorder()

        for expectedRuns in 1...2 {
            let startGate = AnalysisWorkerStartGate()
            try await withBoundedTimeout(.milliseconds(250)) {
                try await runSpeechAnalysisWorkers(
                    consumeResults: {
                        recorder.resultWorkerStarted()
                        await startGate.open()
                        defer { recorder.resultWorkerExited() }
                        do {
                            try await Task.sleep(for: .seconds(60))
                        } catch {
                            if Task.isCancelled { recorder.resultWorkerCancelled() }
                            throw error
                        }
                    },
                    analyzeAndFinalize: {
                        await startGate.waitUntilOpen()
                        recorder.emptyAnalyzerFinalized()
                        return nil
                    }
                )
            }

            let snapshot = recorder.snapshot()
            XCTAssertEqual(snapshot.started, expectedRuns)
            XCTAssertEqual(snapshot.cancelled, expectedRuns)
            XCTAssertEqual(snapshot.exited, expectedRuns)
            XCTAssertEqual(snapshot.active, 0)
            XCTAssertEqual(snapshot.emptyFinalizations, expectedRuns)
        }
    }

    func testSampledAnalyzerInputFinalizesThroughLastSample() async throws {
        let driver = RecordingSpeechAnalyzerFinalizationDriver()
        let sample = CMTime(value: 42, timescale: 1_000)

        try await finalizeAnalyzerInput(lastSample: sample, analyzer: driver)

        let calls = driver.recordedCalls()
        XCTAssertEqual(calls, [.throughSample(sample)])
    }

    func testMediaServicesLossAndResetAreBothTerminalInvalidationActions() {
        for notificationName in [
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification,
        ] {
            XCTAssertEqual(
                audioNotificationAction(for: Notification(name: notificationName)),
                .mediaServicesInvalidated,
                "notification \(notificationName) must fail closed"
            )
        }
    }

    func testInputInterruptionAndInvalidRouteAreTerminalWhileInterruptionEndIsIgnored() {
        let began = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        let ended = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )
        let route = Notification(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )

        XCTAssertEqual(audioNotificationAction(for: began), .interruptionBegan)
        XCTAssertNil(audioNotificationAction(for: ended))
        XCTAssertEqual(audioNotificationAction(for: route), .routeChanged)
    }

    func testDeallocationRemovesAllNotificationObservers() async {
        let center = RecordingAudioNotificationCenter()
        weak var deallocatedInput: AppleSpeechInput?
        do {
            let input = AppleSpeechInput(
                audioSession: AudioSessionController(),
                engineSafety: RecordingInputSafety(),
                notificationCenter: center
            )
            deallocatedInput = input
            for _ in 0..<32 where center.addCount < 5 {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        for _ in 0..<32 where deallocatedInput != nil {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNil(deallocatedInput)
        XCTAssertEqual(center.removeCount, 5)
    }

    private func makeInput(
        preparationRuntime: RecognitionPreparationRuntime
    ) -> AppleSpeechInput {
        AppleSpeechInput(
            audioSession: AudioSessionController(),
            engineSafety: RecordingInputSafety(),
            notificationCenter: RecordingAudioNotificationCenter(),
            preparationRuntime: preparationRuntime
        )
    }

}

private enum RecognitionPreparationTestPath: String, CaseIterable, Sendable {
    case explicit
    case admittedStart
}

private enum ProviderFailurePhase: String, CaseIterable, Sendable {
    case request
    case download
}

private func runRecognitionPreparation(
    _ path: RecognitionPreparationTestPath,
    input: AppleSpeechInput
) async throws {
    switch path {
    case .explicit:
        _ = try await input.prepareRecognition(
            for: Locale(identifier: "en-US"),
            policy: .allowModelInstallation
        )
    case .admittedStart:
        _ = try await input.start(
            configuration: RecognitionConfiguration(
                locale: Locale(identifier: "en-US"),
                policy: .allowModelInstallation
            )
        )
    }
}

private func makePreparationRuntime(
    recorder: AssetRuntimeRecorder,
    status: @escaping @Sendable () async -> RecognitionModelAssetStatus,
    request: @escaping @Sendable () async throws -> RecognitionAssetInstallationRequest?
) -> RecognitionPreparationRuntime {
    RecognitionPreparationRuntime(
        requestMicrophonePermission: { true },
        supportedLocale: { $0 },
        transcriberIsAvailable: { true },
        assetStatus: { _ in
            recorder.recordStatusRead()
            return await status()
        },
        assetInstallationRequest: { _ in
            recorder.recordRequest()
            return try await request()
        },
        releaseReservation: { _ in
            recorder.recordRelease()
        }
    )
}

private final class AssetRuntimeRecorder: @unchecked Sendable {
    struct Snapshot {
        let statusReads: Int
        let requests: Int
        let releases: Int
    }

    private let condition = NSCondition()
    private var statusReads = 0
    private var requests = 0
    private var releases = 0

    func recordStatusRead() {
        condition.withLock {
            statusReads += 1
            condition.broadcast()
        }
    }

    func recordRequest() {
        condition.withLock { requests += 1 }
    }

    func recordRelease() {
        condition.withLock {
            releases += 1
            condition.broadcast()
        }
    }

    func snapshot() -> Snapshot {
        condition.withLock {
            Snapshot(statusReads: statusReads, requests: requests, releases: releases)
        }
    }

    func waitForReleases(_ count: Int) async {
        while snapshot().releases < count {
            await Task.yield()
        }
    }
}

private actor SuspendedProviderResult {
    private var entered = false
    private var resultContinuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resultContinuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func complete() {
        resultContinuation?.resume()
        resultContinuation = nil
    }
}

private enum SourceTopologyError: Error {
    case missingBoundary(String)
}

private actor ModelStatusSequence {
    private let values: [RecognitionModelAssetStatus]
    private var index = 0
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ values: [RecognitionModelAssetStatus]) { self.values = values }

    func next() -> RecognitionModelAssetStatus {
        index += 1
        let waiters = readWaiters
        readWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return values[min(index - 1, values.count - 1)]
    }

    func waitForRead() async {
        if index > 0 { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func waitForReads(_ count: Int) async {
        while index < count {
            await withCheckedContinuation { readWaiters.append($0) }
        }
    }
}

private actor HandoffTestGate {
    private var entered = false
    private var openContinuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { openContinuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        openContinuation?.resume()
        openContinuation = nil
    }
}

private actor HandoffRecorder {
    private var releases = 0
    private var starts = 0

    func recordRelease() { releases += 1 }
    func recordStart() { starts += 1 }
    func snapshot() -> (releases: Int, starts: Int) { (releases, starts) }
}

private func sourceSlice(_ source: String, from start: String, to end: String) throws -> Substring {
    guard let startRange = source.range(of: start) else {
        throw SourceTopologyError.missingBoundary(start)
    }
    guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        throw SourceTopologyError.missingBoundary(end)
    }
    return source[startRange.lowerBound..<endRange.lowerBound]
}

private final class RecordingAudioNotificationCenter: @unchecked Sendable, AudioNotificationCenter {
    private(set) var names: [Notification.Name?] = []
    private(set) var addCount = 0
    private(set) var removeCount = 0

    func addObserver(forName name: Notification.Name?, object: Any?, queue: OperationQueue?, using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        addCount += 1
        names.append(name)
        return NSObject()
    }

    func removeObserver(_ observer: Any) { removeCount += 1 }
}

private final class RecordingInputSafety: AudioEngineSafety {
    func installTap(on node: AVAudioInputNode, bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) -> Bool { true }
    func prepare(_ engine: AVAudioEngine) -> Bool { true }
    func start(_ engine: AVAudioEngine) -> Bool { true }
    func removeTap(on node: AVAudioInputNode, bus: AVAudioNodeBus) -> Bool { true }
    func outputFormat(on node: AVAudioInputNode, bus: AVAudioNodeBus) -> AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
    }
}

private enum TestAnalyzerFailure: Error, Equatable { case failed }

private final class FailingSpeechAnalyzerDriver: @unchecked Sendable, SpeechAnalyzerDriver {
    let error: TestAnalyzerFailure
    init(error: TestAnalyzerFailure) { self.error = error }

    func analyzeSequence(_ sequence: AsyncStream<AnalyzerInput>) async throws -> CMTime? { throw error }
    func finalizeAndFinish(through sample: CMTime) async throws {}
    func finalizeAndFinishThroughEndOfInput() async throws {}
    func cancelAndFinishNow() async {}
}

private final class RecordingSpeechAnalyzerFinalizationDriver: @unchecked Sendable, SpeechAnalyzerDriver {
    enum Call: Equatable {
        case throughSample(CMTime)
        case throughEndOfInput
        case cancelled
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func analyzeSequence(_ sequence: AsyncStream<AnalyzerInput>) async throws -> CMTime? {
        _ = sequence
        return nil
    }

    func finalizeAndFinish(through sample: CMTime) async throws {
        lock.withLock { calls.append(.throughSample(sample)) }
    }

    func finalizeAndFinishThroughEndOfInput() async throws {
        lock.withLock { calls.append(.throughEndOfInput) }
    }

    func cancelAndFinishNow() async {
        lock.withLock { calls.append(.cancelled) }
    }

    func recordedCalls() -> [Call] {
        lock.withLock { calls }
    }
}

private actor AnalysisWorkerStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class AnalysisWorkerRecorder: @unchecked Sendable {
    struct Snapshot {
        let started: Int
        let cancelled: Int
        let exited: Int
        let active: Int
        let emptyFinalizations: Int
    }

    private let lock = NSLock()
    private var started = 0
    private var cancelled = 0
    private var exited = 0
    private var active = 0
    private var emptyFinalizations = 0

    func resultWorkerStarted() {
        lock.withLock {
            started += 1
            active += 1
        }
    }

    func resultWorkerCancelled() {
        lock.withLock { cancelled += 1 }
    }

    func resultWorkerExited() {
        lock.withLock {
            exited += 1
            active -= 1
        }
    }

    func emptyAnalyzerFinalized() {
        lock.withLock { emptyFinalizations += 1 }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                started: started,
                cancelled: cancelled,
                exited: exited,
                active: active,
                emptyFinalizations: emptyFinalizations
            )
        }
    }
}
