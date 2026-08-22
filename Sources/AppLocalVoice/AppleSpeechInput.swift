import AVFAudio
import CoreMedia
import Foundation
import Speech
import UIKit
import AppLocalVoiceAudioEngineSafe

/// SpeechAnalyzer-backed microphone input for iOS 26 and later.
actor AppleSpeechInput: SpeechInput {
    /// Audio input is bounded as well as transcript output.  If the analyzer
    /// cannot keep up, dropping audio would silently corrupt recognition, so a
    /// full input buffer fails the turn and runs the normal cleanup path.
    private static let analyzerInputBufferCapacity = 32
    // Transcript updates are full snapshots. Keep this newest-value buffer
    // intentionally small so a stalled consumer cannot retain many copies of
    // a large valid transcript at once.
    private static let transcriptBufferCapacity = 4
    private static let cleanupTimeout: Duration = .seconds(5)
    private static let maximumCompletedAudioFileBytes = 128 * 1_024 * 1_024
    /// Asset downloads have no safe wall-clock deadline: Apple may legitimately
    /// remain in `.downloading` for a long time. Keep reconciliation bounded to
    /// one task and one latest progress value, poll at a fixed cadence, and let
    /// explicit caller cancellation end the wait.
    private static let modelStatusPollInterval: Duration = .milliseconds(250)
    /// `downloadAndInstall()` does not promise that AssetInventory has already
    /// published `.installed` when the async call returns; Apple may continue
    /// finalizing or retrying the system asset after progress reaches 100%.
    /// There is no safe wall-clock deadline, so preparation remains explicitly
    /// cancellable while `.supported` or `.downloading` and fails only for a
    /// provider error or an authoritative `.unsupported` status.
    private static let audioSessionReleaseFailure = VoiceError.audioSessionUnavailable(
        "The microphone audio session could not be restored; retry close() before starting another turn."
    )

    /// SAFETY: this container never escapes `AppleSpeechInput`. Tokens are
    /// written only on the actor, and notification closures capture the actor
    /// weakly. Nonisolated deinit is the only off-actor reader and cannot race
    /// actor work because any such work would still retain the actor.
    private final class ObserverTokens: @unchecked Sendable {
        var interruption: NSObjectProtocol?
        var route: NSObjectProtocol?
        var background: NSObjectProtocol?
        var mediaServicesLost: NSObjectProtocol?
        var mediaServicesReset: NSObjectProtocol?
    }

    /// SAFETY: `lock` protects the one-shot result and waiter. The continuation
    /// is removed while locked and resumed only after unlocking.
    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?

        func wait() async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func finish(_ result: Bool) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    /// SAFETY: `lock` protects the one-shot result and waiter. The continuation
    /// is removed while locked and resumed only after unlocking.
    private final class InstallRequestGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<RecognitionAssetInstallationRequest?, Error>?
        private var continuation: CheckedContinuation<Result<RecognitionAssetInstallationRequest?, Error>, Never>?

        func wait() async -> Result<RecognitionAssetInstallationRequest?, Error> {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        @discardableResult
        func finish(_ result: Result<RecognitionAssetInstallationRequest?, Error>) -> Bool {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return false
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
            return true
        }
    }

    private let audioSession: AudioSessionController
    // AVAudioEngine is not reusable after media-services reset and is often
    // left in a failed-start state after a route transition. Keep it mutable
    // so every generation can receive a fresh graph.
    private var audioEngine = AVAudioEngine()
    private let engineSafety: any AudioEngineSafety
    private let analyzerFactory: @Sendable (SpeechTranscriber) -> any SpeechAnalyzerDriver
    private let notificationCenter: any AudioNotificationCenter
    private let preparationRuntime: RecognitionPreparationRuntime
    private var analyzer: (any SpeechAnalyzerDriver)?
    private var analyzerCancellationTask: Task<Void, Never>?
    private var modelPreparationTask: Task<Void, Never>?
    private var modelPreparationID: UUID?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsContinuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var converter: LocalAnalyzerInputConverter?
    private var transcript = ""
    private var transcriptAssembler = TranscriptAssembler()
    private var tapInstalled = false
    private var isCapturing = false
    /// Whether the active generation owns live microphone capture. Completed
    /// file recognition intentionally ignores route and interruption events:
    /// it owns neither an audio-session lease nor a capture graph.
    private var isMicrophoneInput = false
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var sessionLeaseHeld = false
    private var sessionReleaseFailed = false
    private var analysisError: Error?
    private var terminalError: VoiceError?
    private var frameRing: AudioFrameRing?
    private var framePumpTask: Task<Void, Never>?
    private var analysisTaskGeneration: UInt64?
    private let observers = ObserverTokens()
    private var observersRegistered = false

    init(audioSession: AudioSessionController) {
        self.audioSession = audioSession
        engineSafety = DefaultAudioEngineSafety()
        analyzerFactory = { DefaultSpeechAnalyzerDriver(SpeechAnalyzer(modules: [$0])) }
        notificationCenter = DefaultAudioNotificationCenter()
        preparationRuntime = .live
    }

    init(audioSession: AudioSessionController, engineSafety: any AudioEngineSafety,
         analyzerFactory: @escaping @Sendable (SpeechTranscriber) -> any SpeechAnalyzerDriver = { DefaultSpeechAnalyzerDriver(SpeechAnalyzer(modules: [$0])) },
         notificationCenter: any AudioNotificationCenter = DefaultAudioNotificationCenter(),
         preparationRuntime: RecognitionPreparationRuntime = .live) {
        self.audioSession = audioSession
        self.engineSafety = engineSafety
        self.analyzerFactory = analyzerFactory
        self.notificationCenter = notificationCenter
        self.preparationRuntime = preparationRuntime
    }

    private func registerObservers() {
        guard !observersRegistered else { return }
        observers.interruption = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification) == .interruptionBegan else { return }
            Task { await self?.handleSystemInterruption() }
        }
        observers.route = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification) == .routeChanged else { return }
            Task { await self?.handleRouteChange() }
        }
        observers.background = notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification) == .applicationBackgrounded else { return }
            Task { await self?.handleApplicationBackground() }
        }
        observers.mediaServicesLost = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification) == .mediaServicesInvalidated else { return }
            Task { await self?.interrupt(
                "The audio media services were lost.",
                reason: .mediaServicesReset,
                abandonInvalidatedEngine: true
            ) }
        }
        observers.mediaServicesReset = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification) == .mediaServicesInvalidated else { return }
            Task { await self?.interrupt(
                "The audio media services were reset.",
                reason: .mediaServicesReset,
                abandonInvalidatedEngine: true
            ) }
        }
        observersRegistered = true
    }

    deinit {
        if let interruption = observers.interruption { notificationCenter.removeObserver(interruption) }
        if let route = observers.route { notificationCenter.removeObserver(route) }
        if let background = observers.background { notificationCenter.removeObserver(background) }
        if let mediaServicesLost = observers.mediaServicesLost { notificationCenter.removeObserver(mediaServicesLost) }
        if let mediaServicesReset = observers.mediaServicesReset { notificationCenter.removeObserver(mediaServicesReset) }
    }

    func capabilities(for locale: Locale) async -> SpeechCapabilities {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return SpeechCapabilities(locale: locale, isSupported: false, supportsOnDevice: false, reason: "This locale is not supported by SpeechTranscriber.")
        }
        guard SpeechTranscriber.isAvailable else {
            return SpeechCapabilities(locale: supported, isSupported: true, supportsOnDevice: false, reason: "SpeechTranscriber is unavailable on this device.")
        }
        let transcriber = makeLiveRecognitionTranscriber(locale: supported)
        let status = await AssetInventory.status(forModules: [transcriber])
        let installed = recognitionModuleIsInstalled(status)
        return SpeechCapabilities(
            locale: supported,
            isSupported: true,
            supportsOnDevice: installed,
            reason: installed ? nil : "The speech model is not installed yet."
        )
    }

    func modelInstallationAvailable(for locale: Locale) async -> Bool {
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            return false
        }
        return SpeechTranscriber.isAvailable
    }

    func authorizationStatus() async -> VoicePermissionStatus {
        // SpeechAnalyzer's local transcriber path has no separate speech
        // authorization prompt; this query stays side-effect-free.
        .authorized
    }

    func microphonePermissionStatus() async -> VoicePermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .notDetermined
        case .denied: return .denied
        case .granted: return .authorized
        @unknown default: return .restricted
        }
    }

    func requestAuthorization() async -> VoicePermissionStatus {
        // SpeechAnalyzer transcriber modules are local and do not use the
        // legacy SFSpeechRecognizer authorization path.
        .authorized
    }

    func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func prepareRecognition(
        for locale: Locale,
        policy: SpeechModelPolicy,
        progress: RecognitionPreparationProgressHandler?
    ) async throws -> Bool {
        // Preparation deliberately stays outside the capture generation: it
        // may prompt or install an opted-in asset, but it never allocates a
        // microphone/audio-session lease or an accepted session identity.
        await progress?(.checkingReadiness)
        guard activeGeneration == nil, await resourcesAreReleased(), !tapInstalled else {
            throw VoiceError.invalidState("Recognition preparation cannot run while capture cleanup is active.")
        }
        guard await preparationRuntime.requestMicrophonePermission() else {
            throw VoiceError.microphonePermissionDenied
        }
        try Task.checkCancellation()
        guard await requestAuthorization() == .authorized else {
            throw VoiceError.speechPermissionDenied
        }
        try Task.checkCancellation()
        guard let supported = await preparationRuntime.supportedLocale(locale) else {
            throw VoiceError.unsupportedLocale(locale)
        }
        guard preparationRuntime.transcriberIsAvailable() else {
            throw VoiceError.onDeviceRecognitionUnavailable(supported)
        }
        let transcriber = makeLiveRecognitionTranscriber(locale: supported)
        let status = await preparationRuntime.assetStatus(transcriber)
        guard status != .unsupported else {
            throw VoiceError.onDeviceRecognitionUnavailable(supported)
        }
        guard status != .installed else { return false }
        guard policy == .allowModelInstallation else {
            throw VoiceError.onDeviceRecognitionUnavailable(supported)
        }
        do {
            if status == .downloading {
                try await awaitInstalledModel(
                    transcriber: transcriber,
                    locale: supported,
                    requestProgress: nil,
                    progress: progress
                )
            } else {
                return try await installModelIfNeeded(
                    transcriber: transcriber,
                    locale: supported,
                    progress: progress
                )
            }
            return false
        } catch is CancellationError {
            throw VoiceError.cancelled
        } catch let error as VoiceError {
            throw error
        } catch {
            throw recognitionModelInstallationFailure(locale: supported, underlying: error)
        }
    }

    func start(
        configuration: RecognitionConfiguration,
        input: RecognitionInput,
        lifecyclePolicy: AudioLifecyclePolicy
    ) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        if input == .microphone {
            registerObservers()
        }
        await cancel()
        try Task.checkCancellation()
        // `cancel()` is bounded. A framework task, analyzer, ring, or tap can
        // still be owned after that boundary if Apple ignored cancellation;
        // do not begin a new generation alongside those resources.
        guard await resourcesAreReleased() else {
            throw VoiceError.audioSessionUnavailable("The previous microphone generation has not released its resources.")
        }
        // A failed tap removal is deliberately retained as ownership. Do not
        // start a second generation until a later cleanup attempt proves that
        // the old tap is gone.
        guard !tapInstalled else {
            throw VoiceError.audioSessionUnavailable("The previous microphone tap could not be removed.")
        }
        // A failed start, media-services reset, or route transition can leave
        // AVAudioEngine's internal graph unusable even after its tap is gone.
        // Recreate it before touching the new generation.
        if input == .microphone {
            audioEngine = AVAudioEngine()
        }
        generation &+= 1
        let currentGeneration = generation
        activeGeneration = currentGeneration
        isMicrophoneInput = input == .microphone
        if input == .microphone {
            guard await preparationRuntime.requestMicrophonePermission() else {
                activeGeneration = nil
                isMicrophoneInput = false
                throw VoiceError.microphonePermissionDenied
            }
        }
        try ensureCurrent(currentGeneration)
        guard let locale = await preparationRuntime.supportedLocale(configuration.locale) else {
            activeGeneration = nil
            throw VoiceError.unsupportedLocale(configuration.locale)
        }
        try ensureCurrent(currentGeneration)

        // `.transcription` is optimized for a completed recording. The live
        // stream needs the iOS 26 progressive preset so partial snapshots are
        // emitted while the analyzer is still receiving audio. Preserve the
        // preset's options and explicitly retain per-run audio timing.
        let transcriber = makeLiveRecognitionTranscriber(locale: locale)
        guard preparationRuntime.transcriberIsAvailable() else {
            activeGeneration = nil
            throw VoiceError.onDeviceRecognitionUnavailable(locale)
        }
        let assetStatus = await preparationRuntime.assetStatus(transcriber)
        try ensureCurrent(currentGeneration)
        if assetStatus == .unsupported {
            activeGeneration = nil
            throw VoiceError.onDeviceRecognitionUnavailable(locale)
        }
        if configuration.policy == .installedModelsOnly,
           assetStatus != .installed {
            activeGeneration = nil
            throw VoiceError.onDeviceRecognitionUnavailable(locale)
        }
        do {
            try ensureCurrent(currentGeneration)
            if assetStatus != .installed {
                guard configuration.policy == .allowModelInstallation else {
                    activeGeneration = nil
                    throw VoiceError.onDeviceRecognitionUnavailable(locale)
                }
                _ = try await installModelIfNeeded(
                    transcriber: transcriber,
                    locale: locale,
                    progress: nil,
                    generation: currentGeneration
                )
            }
        } catch {
            activeGeneration = nil
            if error is CancellationError || Task.isCancelled { throw VoiceError.cancelled }
            if let error = error as? VoiceError { throw error }
            throw recognitionModelInstallationFailure(locale: locale, underlying: error)
        }

        if input == .microphone {
            do {
                try await audioSession.enter(role: .listening, lifecyclePolicy: lifecyclePolicy)
                sessionLeaseHeld = true
                sessionReleaseFailed = false
            } catch {
                activeGeneration = nil
                isMicrophoneInput = false
                // enter can fail after partially changing the singleton. The
                // broker retains a reconciliation marker in that case; retry the
                // owner boundary before returning the startup error.
                _ = await releaseAudioSessionIfNeeded(retryEvenWithoutLease: true)
                throw VoiceError.audioSessionUnavailable("Unable to activate the microphone audio session.")
            }
        }
        do {
            try ensureCurrent(currentGeneration)
        } catch {
            await cleanupAfterFailedStart(generation: currentGeneration)
            throw VoiceError.cancelled
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            await cleanupAfterFailedStart(generation: currentGeneration)
            throw VoiceError.audioSessionUnavailable("Speech recognition returned no compatible audio format.")
        }
        do { try ensureCurrent(currentGeneration) } catch {
            await cleanupAfterFailedStart(generation: currentGeneration)
            throw VoiceError.cancelled
        }
        guard analyzerFormat.sampleRate > 0, analyzerFormat.channelCount > 0 else {
            await cleanupAfterFailedStart(generation: currentGeneration)
            throw VoiceError.audioSessionUnavailable("Speech recognition returned an invalid analyzer audio format.")
        }

        let (sequence, builder) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingOldest(Self.analyzerInputBufferCapacity)
        )
        let analyzer = analyzerFactory(transcriber)
        self.analyzer = analyzer
        self.inputBuilder = builder
        self.converter = LocalAnalyzerInputConverter(targetFormat: analyzerFormat)
        self.transcript = ""
        self.transcriptAssembler = TranscriptAssembler()
        self.analysisError = nil
        self.terminalError = nil

        let results = AsyncThrowingStream<TranscriptUpdate, Error>(
            bufferingPolicy: .bufferingNewest(Self.transcriptBufferCapacity)
        ) { continuation in
            self.resultsContinuation = continuation
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await runSpeechAnalysisWorkers(
                        consumeResults: {
                            for try await result in transcriber.results {
                                guard await self.isCurrent(currentGeneration) else { return }
                                let update = try await self.assembleTranscript(
                                    result: AppleSpeechTranscriptMapper.map(result),
                                    isFinal: result.isFinal,
                                    generation: currentGeneration
                                )
                                if let update { continuation.yield(update) }
                            }
                        },
                        analyzeAndFinalize: {
                            let lastSample = try await analyzer.analyzeSequence(sequence)
                            guard await self.isCurrent(currentGeneration) else {
                                throw VoiceError.cancelled
                            }
                            // A zero-sample rapid release is still an orderly
                            // end of input. The worker helper cancels and joins
                            // Apple's result sequence after finalization when
                            // that sequence does not terminate by itself.
                            try await finalizeAnalyzerInput(
                                lastSample: lastSample,
                                analyzer: analyzer
                            )
                            return lastSample
                        }
                    )
                    continuation.finish()
                    await self.clearResultsContinuation(currentGeneration)
                    await self.completeAnalysisTask(currentGeneration)
                } catch is CancellationError {
                    continuation.finish(throwing: VoiceError.cancelled)
                    await self.clearResultsContinuation(currentGeneration)
                    await self.completeAnalysisTask(currentGeneration)
                } catch {
                    continuation.finish(throwing: error)
                    await self.clearResultsContinuation(currentGeneration)
                    await self.handleAnalysisFailure(error, generation: currentGeneration)
                    await self.completeAnalysisTask(currentGeneration)
                }
            }
            self.analysisTask = task
            self.analysisTaskGeneration = currentGeneration
        }

        if case .audioFile(let file) = input {
            isCapturing = true
            framePumpTask = Task { [weak self] in
                await self?.pumpCompletedAudioFile(file, generation: currentGeneration)
            }
            return results
        }

        let node = audioEngine.inputNode
        guard let hardwareFormat = engineSafety.outputFormat(on: node, bus: 0) else {
            await cleanupAfterFailedStart(generation: currentGeneration)
            throw VoiceError.audioSessionUnavailable("Unable to query the microphone audio format.")
        }
        do { try ensureCurrent(currentGeneration) } catch {
            await cleanupAfterFailedStart(generation: currentGeneration)
            throw VoiceError.cancelled
        }
        do {
            try validateHardwareAudioFormat(hardwareFormat)
        } catch {
            await cleanupAfterFailedStart(generation: currentGeneration)
            throw error
        }
        let frameRing: AudioFrameRing
        do {
            frameRing = try AudioFrameRing(
                format: hardwareFormat,
                capacity: Self.analyzerInputBufferCapacity
            )
        } catch {
            await cleanupAfterFailedStart(generation: currentGeneration)
            throw error
        }
        self.frameRing = frameRing

        guard engineSafety.installTap(
            on: node,
            bus: 0,
            bufferSize: 1024,
            format: nil,
            block: { buffer, time in
                // The SDK available to this target does not expose the newer
                // read-only tap API. Copy immediately into a bounded owned
                // ring; never retain or send Apple's mutable tap buffer.
                _ = frameRing.push(buffer, time: time)
            }
        ) else {
            await cleanupAfterFailedStart(generation: currentGeneration)
            throw VoiceError.audioSessionUnavailable("Unable to access the microphone.")
        }
        // Record ownership immediately. The generation check below can fail
        // during startup; cleanup must still know that a tap exists.
        tapInstalled = true
        do { try ensureCurrent(currentGeneration) } catch {
            await cleanupAfterFailedStart(generation: currentGeneration)
            throw VoiceError.cancelled
        }
        isCapturing = true
        framePumpTask = Task { [weak self] in
            await self?.pumpFrames(frameRing, generation: currentGeneration)
        }

        guard engineSafety.prepare(audioEngine) else {
            await cleanupAfterFailedStart(generation: currentGeneration)
            throw VoiceError.audioSessionUnavailable("Unable to prepare the microphone.")
        }
        guard engineSafety.start(audioEngine) else {
            await cleanupAfterFailedStart(generation: currentGeneration)
            throw VoiceError.audioSessionUnavailable("Unable to start the microphone.")
        }
        return results
    }

    func stop() async throws -> String {
        defer { clearTranscriptState() }

        guard isCapturing, let currentGeneration = activeGeneration else {
            if let terminalError {
                self.terminalError = nil
                throw terminalError
            }
            if !(await resourcesAreReleased()) {
                await cleanupInactiveResources()
                guard await resourcesAreReleased() else {
                    throw Self.audioSessionReleaseFailure
                }
            }
            return transcript
        }

        audioEngine.stop()
        guard removeTapOwnership(isInstalled: &tapInstalled, remove: {
            engineSafety.removeTap(on: audioEngine.inputNode, bus: 0)
        }) else {
            throw VoiceError.audioSessionUnavailable("Unable to remove the microphone tap.")
        }
        frameRing?.stopAccepting()

        // The legacy tap has stopped producing new frames. A single bounded
        // pump drains every owned slot before the converter is flushed.
        if let pump = framePumpTask,
           !(await awaitTaskBounded(pump, timeout: Self.cleanupTimeout)) {
            await cancelGeneration(
                currentGeneration,
                terminalError: .audioSessionUnavailable("Microphone audio cleanup exceeded the recovery deadline.")
            )
            throw VoiceError.audioSessionUnavailable("Microphone audio cleanup exceeded the recovery deadline.")
        }
        framePumpTask = nil
        frameRing = nil
        isCapturing = false
        isMicrophoneInput = false
        audioEngine = AVAudioEngine()

        do {
            try Task.checkCancellation()
            guard activeGeneration == currentGeneration else { throw VoiceError.cancelled }
        } catch {
            await cancelGeneration(currentGeneration, terminalError: .cancelled)
            throw VoiceError.cancelled
        }

        // Flush converted frames before ending the sequence. Finishing first
        // can drop the final partial utterance.
        do {
            if let converter {
                for input in try converter.flush() {
                    guard let inputBuilder,
                          case .enqueued = inputBuilder.yield(input) else {
                        throw VoiceError.audioSessionUnavailable(
                            "Speech analyzer input could not accept final microphone audio."
                        )
                    }
                }
            }
        } catch {
            await cancelGeneration(
                currentGeneration,
                terminalError: .audioSessionUnavailable("Unable to finalize microphone audio.")
            )
            throw VoiceError.audioSessionUnavailable("Unable to finalize microphone audio.")
        }
        inputBuilder?.finish()
        inputBuilder = nil
        resultsContinuation = nil
        converter = nil

        if let analysis = analysisTask,
           !(await awaitTaskBounded(analysis, timeout: Self.cleanupTimeout)) {
            await cancelGeneration(
                currentGeneration,
                awaitAnalysisTask: false,
                terminalError: .audioSessionUnavailable("Speech analysis cleanup exceeded the recovery deadline.")
            )
            throw VoiceError.audioSessionUnavailable("Speech analysis cleanup exceeded the recovery deadline.")
        }
        analysisTask = nil
        analysisTaskGeneration = nil
        analyzer = nil
        guard activeGeneration == currentGeneration else {
            let error = terminalError ?? .cancelled
            terminalError = nil
            guard await releaseAudioSessionIfNeeded() else {
                throw Self.audioSessionReleaseFailure
            }
            throw error
        }
        activeGeneration = nil
        if let analysisError {
            self.analysisError = nil
            guard await releaseAudioSessionIfNeeded() else {
                terminalError = nil
                throw Self.audioSessionReleaseFailure
            }
            terminalError = nil
            throw analysisError
        }
        self.analysisError = nil
        guard await releaseAudioSessionIfNeeded() else {
            throw Self.audioSessionReleaseFailure
        }
        removeObservers()
        terminalError = nil
        return transcript
    }

    func cancel() async {
        guard let currentGeneration = activeGeneration else {
            await cleanupInactiveResources()
            return
        }
        await cancelGeneration(currentGeneration, terminalError: .cancelled)
    }

    func resourcesAreReleased() async -> Bool {
        activeGeneration == nil && !tapInstalled && analysisTask == nil && analyzer == nil &&
            analyzerCancellationTask == nil &&
            modelPreparationTask == nil &&
            framePumpTask == nil && frameRing == nil && !sessionLeaseHeld && !sessionReleaseFailed
    }

    private func cancelGeneration(
        _ currentGeneration: UInt64,
        awaitAnalysisTask: Bool = true,
        awaitFramePump: Bool = true,
        terminalError: VoiceError? = nil,
        abandonInvalidatedEngine: Bool = false
    ) async {
        guard activeGeneration == currentGeneration else { return }
        if self.terminalError == nil { self.terminalError = terminalError }
        generation &+= 1
        activeGeneration = nil
        // A cancelled or interrupted generation has no authoritative text to
        // return. Drop it immediately so a later non-cooperative cleanup task
        // cannot retain the completed transcript.
        clearTranscriptState()
        isCapturing = false
        isMicrophoneInput = false
        audioEngine.stop()
        var removed = removeTapOwnership(isInstalled: &tapInstalled, remove: {
            engineSafety.removeTap(on: audioEngine.inputNode, bus: 0)
        })
        frameRing?.stopAccepting()
        framePumpTask?.cancel()
        if awaitFramePump, let pump = framePumpTask,
           await awaitTaskBounded(pump, timeout: Self.cleanupTimeout) {
            framePumpTask = nil
        } else if !awaitFramePump {
            // The pump calls this method on overflow. It cannot await its own
            // task, but it has already stopped accepting new callback data.
            framePumpTask = nil
        }

        inputBuilder?.finish()
        inputBuilder = nil
        resultsContinuation = nil
        converter = nil
        analysisTask?.cancel()
        _ = await cancelAnalyzerBounded()
        if awaitAnalysisTask, let analysis = analysisTask,
           await awaitTaskBounded(analysis, timeout: Self.cleanupTimeout) {
            analysisTask = nil
            analysisTaskGeneration = nil
            analyzer = nil
        }
        _ = await cancelModelPreparationBounded()

        if abandonInvalidatedEngine, !removed {
            // After a media-server reset the old engine/tap is no longer a
            // trustworthy retry boundary. Abandon the invalidated graph and
            // recreate it; retaining a dead tap would permanently block the
            // next generation even though no usable callback can remain.
            tapInstalled = false
            removed = true
        }

        if removed && framePumpTask == nil {
            frameRing = nil
            audioEngine = AVAudioEngine()
        }
        // If removal was rejected, the tap is still owned by this adapter;
        // retaining the session lease prevents another subsystem from
        // deactivating audio underneath that callback. The next cleanup path
        // retries removal before it can acquire a new generation.
        if !tapInstalled && analysisTask == nil && analyzer == nil &&
           analyzerCancellationTask == nil && framePumpTask == nil {
            _ = await releaseAudioSessionIfNeeded()
            removeObservers()
        }
    }

    private func cleanupInactiveResources() async {
        clearTranscriptState()
        audioEngine.stop()
        let removed = removeTapOwnership(isInstalled: &tapInstalled, remove: {
            engineSafety.removeTap(on: audioEngine.inputNode, bus: 0)
        })
        frameRing?.stopAccepting()
        framePumpTask?.cancel()
        if let pump = framePumpTask,
           await awaitTaskBounded(pump, timeout: Self.cleanupTimeout) {
            framePumpTask = nil
        }
        inputBuilder?.finish()
        inputBuilder = nil
        resultsContinuation = nil
        converter = nil
        analysisTask?.cancel()
        _ = await cancelAnalyzerBounded()
        if let analysis = analysisTask,
           await awaitTaskBounded(analysis, timeout: Self.cleanupTimeout) {
            analysisTask = nil
            analysisTaskGeneration = nil
            analyzer = nil
        }
        _ = await cancelModelPreparationBounded()
        isCapturing = false
        isMicrophoneInput = false
        activeGeneration = nil
        analysisError = nil
        if removed && framePumpTask == nil {
            frameRing = nil
            audioEngine = AVAudioEngine()
        }
        if !tapInstalled && analysisTask == nil && analyzer == nil &&
           analyzerCancellationTask == nil && framePumpTask == nil {
            _ = await releaseAudioSessionIfNeeded()
        }
        removeObservers()
    }

    private func removeObservers() {
        guard observersRegistered else { return }
        if let interruption = observers.interruption { notificationCenter.removeObserver(interruption) }
        if let route = observers.route { notificationCenter.removeObserver(route) }
        if let background = observers.background { notificationCenter.removeObserver(background) }
        if let mediaServicesLost = observers.mediaServicesLost { notificationCenter.removeObserver(mediaServicesLost) }
        if let mediaServicesReset = observers.mediaServicesReset { notificationCenter.removeObserver(mediaServicesReset) }
        observers.interruption = nil
        observers.route = nil
        observers.background = nil
        observers.mediaServicesLost = nil
        observers.mediaServicesReset = nil
        observersRegistered = false
    }

    private func cleanupAfterFailedStart(generation currentGeneration: UInt64) async {
        await cancelGeneration(currentGeneration)
    }

    private func releaseAudioSessionIfNeeded(retryEvenWithoutLease: Bool = false) async -> Bool {
        guard retryEvenWithoutLease || sessionLeaseHeld || sessionReleaseFailed else { return true }
        do {
            try await audioSession.exit()
            sessionLeaseHeld = false
            sessionReleaseFailed = false
            return true
        } catch {
            // AudioSessionBroker removes the logical lease before a final
            // restore attempt. A later exit is therefore a safe reconciliation
            // retry, not a second release of the same lease.
            sessionLeaseHeld = false
            sessionReleaseFailed = true
            return false
        }
    }

    private func awaitTaskBounded(_ task: Task<Void, Never>, timeout: Duration) async -> Bool {
        let gate = CompletionGate()
        let waiter: Task<Void, Never> = Task {
            await task.value
            gate.finish(true)
        }
        let timer: Task<Void, Never> = Task {
            do {
                try await Task.sleep(for: timeout)
                gate.finish(false)
            } catch {
                // The timer is cancelled when the task wins the race.
            }
        }
        let result = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            gate.finish(false)
        }
        timer.cancel()
        waiter.cancel()
        return result
    }

    /// Bounds the Apple analyzer's cancellation boundary as well as the task
    /// that consumes its results. A misbehaving framework call must leave the
    /// provider in a failed/retryable state, never suspend close forever.
    private func cancelAnalyzerBounded() async -> Bool {
        if let existing = analyzerCancellationTask {
            let result = await awaitTaskBounded(existing, timeout: Self.cleanupTimeout)
            if result {
                analyzerCancellationTask = nil
                analyzer = nil
            }
            return result
        }

        guard let analyzer else { return true }
        let cancellationTask: Task<Void, Never> = Task {
            await analyzer.cancelAndFinishNow()
        }
        analyzerCancellationTask = cancellationTask
        let result = await awaitTaskBounded(cancellationTask, timeout: Self.cleanupTimeout)
        if result {
            analyzerCancellationTask = nil
            self.analyzer = nil
        }
        return result
    }

    /// Retains the system-managed model request/download worker until its
    /// underlying call has returned. Cancelling the observing task alone does
    /// not prove that AssetInventory has stopped touching its reservation.
    private func trackModelPreparation(_ worker: Task<Void, Never>) -> UUID {
        let id = UUID()
        modelPreparationID = id
        modelPreparationTask = worker
        Task.detached { [weak self] in
            await worker.value
            await self?.finishModelPreparation(id)
        }
        return id
    }

    private func finishModelPreparation(_ id: UUID) {
        guard modelPreparationID == id else { return }
        modelPreparationID = nil
        modelPreparationTask = nil
    }

    private func cancelModelPreparationBounded() async -> Bool {
        guard let worker = modelPreparationTask else { return true }
        worker.cancel()
        guard await awaitTaskBounded(worker, timeout: Self.cleanupTimeout) else {
            return false
        }
        if let id = modelPreparationID {
            finishModelPreparation(id)
        }
        return true
    }

    private func installModelIfNeeded(
        transcriber: SpeechTranscriber,
        locale: Locale,
        progress: RecognitionPreparationProgressHandler?,
        generation currentGeneration: UInt64? = nil
    ) async throws -> Bool {
        if let currentGeneration { try ensureCurrent(currentGeneration) }
        guard let request = try await assetInstallationRequestBounded(
            supporting: transcriber,
            locale: locale
        ) else {
            try await awaitInstalledModel(
                transcriber: transcriber,
                locale: locale,
                requestProgress: nil,
                progress: progress,
                generation: currentGeneration
            )
            return false
        }

        var installationStarted = false
        do {
            if let currentGeneration { try ensureCurrent(currentGeneration) }
            // Ownership is now either released by the handoff's pre-start
            // cancellation path or transferred to the worker synchronously
            // when `start` is invoked.
            installationStarted = true
            try await handOffReservedAssetRequest(
                release: { [preparationRuntime] in
                    await preparationRuntime.releaseReservation(locale)
                },
                start: { [self] in
                    try await awaitInstallOrCancellation(
                        request,
                        locale: locale,
                        progress: progress
                    )
                }
            )
            if let currentGeneration { try ensureCurrent(currentGeneration) }
            try await awaitInstalledModel(
                transcriber: transcriber,
                locale: locale,
                requestProgress: request.downloadProgress,
                progress: progress,
                generation: currentGeneration
            )
            return true
        } catch {
            // Once the installation worker starts, the result gate decides
            // whether its reservation remains subscribed or is released. Only
            // cancellation before worker creation leaves release in this scope.
            if !installationStarted {
                await preparationRuntime.releaseReservation(locale)
            }
            throw error
        }
    }

    private func awaitInstallOrCancellation(
        _ request: RecognitionAssetInstallationRequest,
        locale: Locale,
        progress: RecognitionPreparationProgressHandler?
    ) async throws {
        let gate = ModelInstallationResultGate()
        let preparationRuntime = self.preparationRuntime
        let progressWorker = Task {
            while !Task.isCancelled {
                await progress?(.downloadingModel(request.downloadProgress()))
                do {
                    try await Task.sleep(for: Self.modelStatusPollInterval)
                } catch {
                    return
                }
            }
        }
        let worker: Task<Void, Never> = Task.detached(priority: .utility) {
            let result: Result<Void, Error>
            do {
                try await request.downloadAndInstall()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            // `assetInstallationRequest` reserves the locale as the app's
            // durable subscription. Retain it when this provider result wins,
            // including an initial provider failure because Apple may retry.
            // Release only when caller cancellation already won the same gate.
            let didPublish = gate.finish(result)
            await releaseModelReservationIfResultDidNotPublish(didPublish) {
                await preparationRuntime.releaseReservation(locale)
            }
        }
        _ = trackModelPreparation(worker)

        let result = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            // The Speech framework may continue a system-managed download
            // after cancellation, but the caller must regain control now.
            worker.cancel()
            gate.finish(.failure(CancellationError()))
        }
        worker.cancel()
        progressWorker.cancel()
        await progressWorker.value
        try result.get()
    }

    private func awaitInstalledModel(
        transcriber: SpeechTranscriber,
        locale: Locale,
        requestProgress: (@Sendable () -> RecognitionModelDownloadProgress)?,
        progress: RecognitionPreparationProgressHandler?,
        generation currentGeneration: UInt64? = nil
    ) async throws {
        try await awaitRecognitionModelInstalled(
            locale: locale,
            pollInterval: Self.modelStatusPollInterval,
            status: { [self] in
                if let currentGeneration { try await ensureCurrent(currentGeneration) }
                let status = await preparationRuntime.assetStatus(transcriber)
                if let currentGeneration { try await ensureCurrent(currentGeneration) }
                return status
            },
            downloadProgress: {
                requestProgress?() ?? .indeterminate
            },
            progress: progress
        )
    }

    private func assetInstallationRequestBounded(
        supporting transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws -> RecognitionAssetInstallationRequest? {
        let gate = InstallRequestGate()
        let preparationRuntime = self.preparationRuntime
        let worker = Task.detached(priority: .utility) {
            do {
                let request = try await preparationRuntime.assetInstallationRequest(transcriber)
                if !gate.finish(.success(request)), request != nil {
                    // The caller timed out or was cancelled after the system
                    // reserved this locale. Release the late result rather
                    // than leaking a reservation that the caller can no
                    // longer observe.
                    await preparationRuntime.releaseReservation(locale)
                }
            } catch {
                _ = gate.finish(.failure(error))
            }
        }
        _ = trackModelPreparation(worker)
        let timer = Task {
            do {
                try await Task.sleep(for: Self.cleanupTimeout)
                _ = gate.finish(.failure(
                    VoiceError.audioSessionUnavailable(
                        "Speech model preparation did not complete before the recovery deadline."
                    )
                ))
            } catch {
                // The request side won the race.
            }
        }
        let result = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            worker.cancel()
            _ = gate.finish(.failure(CancellationError()))
        }
        timer.cancel()
        worker.cancel()
        return try result.get()
    }

    private func pumpFrames(_ ring: AudioFrameRing, generation currentGeneration: UInt64) async {
        while !Task.isCancelled {
            if ring.hasOverflowed {
                await cancelGeneration(
                    currentGeneration,
                    awaitFramePump: false,
                    terminalError: .audioSessionUnavailable("Microphone audio handoff exceeded its bounded capacity.")
                )
                return
            }

            var processedFrame = false
            while let frame = ring.pop() {
                processedFrame = true
                defer { frame.release() }
                guard let buffer = frame.makePCMBuffer() else {
                    await cancelGeneration(
                        currentGeneration,
                        awaitFramePump: false,
                        terminalError: .audioSessionUnavailable("Unable to copy microphone audio safely.")
                    )
                    return
                }
                let captured = LocalAnalyzerInputConverter.CapturedAudioFrame(
                    buffer: buffer,
                    sampleTime: frame.sampleTime,
                    sampleRate: frame.sampleRate,
                    isSampleTimeValid: frame.isSampleTimeValid
                )
                await convertAndYield(captured, generation: currentGeneration)
                guard activeGeneration == currentGeneration else { return }
            }

            if !ring.isAccepting && ring.isDrained { return }
            guard activeGeneration == currentGeneration else { return }
            if !processedFrame {
                do {
                    try await Task.sleep(for: .milliseconds(2))
                } catch {
                    return
                }
            }
        }
    }

    /// Reads a completed recording in bounded PCM blocks on the provider
    /// actor. The continuation stays open after this task returns so the host
    /// retains the existing explicit `finishSession` boundary for analyzer
    /// finalization and terminal transcript delivery.
    private func pumpCompletedAudioFile(
        _ file: RecognitionAudioFile,
        generation currentGeneration: UInt64
    ) async {
        do {
            let values = try file.url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey
            ])
            guard values.isRegularFile == true,
                  let byteCount = values.fileSize,
                  byteCount > 0,
                  byteCount <= Self.maximumCompletedAudioFileBytes else {
                throw VoiceError.invalidRecognitionConfiguration(
                    "Completed audio input is not a supported local file."
                )
            }
            let audioFile = try AVAudioFile(forReading: file.url)
            let format = audioFile.processingFormat
            guard format.sampleRate.isFinite, format.sampleRate > 0,
                  format.channelCount > 0,
                  audioFile.length > 0 else {
                throw VoiceError.invalidRecognitionConfiguration(
                    "Completed audio input is empty or has an invalid format."
                )
            }
            let maximumFrames = try maximumFileFrames(
                for: file.maximumDuration,
                sampleRate: format.sampleRate
            )
            guard audioFile.length <= maximumFrames else {
                throw VoiceError.invalidRecognitionConfiguration(
                    "Completed audio input exceeds its configured duration limit."
                )
            }

            var sampleTime: AVAudioFramePosition = 0
            while audioFile.framePosition < audioFile.length {
                try ensureCurrent(currentGeneration)
                let remaining = audioFile.length - audioFile.framePosition
                let capacity = AVAudioFrameCount(min(Int64(4_096), remaining))
                guard capacity > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                    throw VoiceError.audioSessionUnavailable("Unable to allocate completed audio input.")
                }
                try audioFile.read(into: buffer, frameCount: capacity)
                guard buffer.frameLength > 0 else {
                    throw VoiceError.invalidRecognitionConfiguration(
                        "Completed audio input could not be decoded."
                    )
                }
                let frame = LocalAnalyzerInputConverter.CapturedAudioFrame(
                    buffer: buffer,
                    sampleTime: sampleTime,
                    sampleRate: format.sampleRate
                )
                await convertAndYield(frame, generation: currentGeneration)
                guard activeGeneration == currentGeneration else { return }
                let (nextSampleTime, overflow) = sampleTime.addingReportingOverflow(
                    AVAudioFramePosition(buffer.frameLength)
                )
                guard !overflow else {
                    throw VoiceError.invalidRecognitionConfiguration(
                        "Completed audio input has an invalid timeline."
                    )
                }
                sampleTime = nextSampleTime
            }
        } catch is CancellationError {
            return
        } catch let error as VoiceError {
            await cancelGeneration(
                currentGeneration,
                awaitFramePump: false,
                terminalError: error
            )
        } catch {
            await cancelGeneration(
                currentGeneration,
                awaitFramePump: false,
                terminalError: .invalidRecognitionConfiguration(
                    "Completed audio input could not be opened or decoded."
                )
            )
        }
    }

    private func maximumFileFrames(
        for duration: Duration,
        sampleRate: Double
    ) throws -> AVAudioFramePosition {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let frames = seconds * sampleRate
        guard seconds.isFinite, seconds > 0, frames.isFinite,
              frames > 0, frames <= Double(Int64.max) else {
            throw VoiceError.invalidRecognitionConfiguration(
                "Completed audio input has an invalid duration limit."
            )
        }
        return AVAudioFramePosition(frames.rounded(.down))
    }

    private func isCurrent(_ currentGeneration: UInt64) -> Bool {
        activeGeneration == currentGeneration
    }

    private func ensureCurrent(_ currentGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard activeGeneration == currentGeneration else { throw VoiceError.cancelled }
    }

    private func convertAndYield(_ frame: LocalAnalyzerInputConverter.CapturedAudioFrame, generation currentGeneration: UInt64) async {
        // `isCapturing` is intentionally not checked here: stop() first stops
        // the tap and then drains already-owned frames before finalization.
        guard activeGeneration == currentGeneration, let converter else { return }
        do {
            for input in try converter.convert(frame) {
                guard activeGeneration == currentGeneration else { return }
                guard let inputBuilder else { return }
                guard case .enqueued = inputBuilder.yield(input) else {
                    // Backpressure is a correctness boundary for audio. Do
                    // not continue with a hole in the sample stream; cancel
                    // this generation so the host receives a deterministic
                    // terminal outcome and can start a fresh turn.
                    await cancelGeneration(
                        currentGeneration,
                        terminalError: .audioSessionUnavailable("Speech analyzer input could not accept microphone audio.")
                    )
                    return
                }
            }
        } catch {
            let terminal = (error as? VoiceError)
                ?? .audioSessionUnavailable("Unable to convert microphone audio.")
            await cancelGeneration(currentGeneration, terminalError: terminal)
        }
    }

    private func assembleTranscript(
        result: TranscriptAssemblerResult,
        isFinal: Bool,
        generation currentGeneration: UInt64
    ) throws -> TranscriptUpdate? {
        guard activeGeneration == currentGeneration else { return nil }
        let update: TranscriptUpdate
        do {
            update = try transcriptAssembler.consume(
                TranscriptAssemblerResult(
                    range: result.range,
                    segments: result.segments,
                    isFinal: isFinal
                )
            )
        } catch TranscriptAssemblerError.textLimitExceeded {
            throw VoiceError.textTooLong(maximumUTF16Length: VoiceTextLimits.maximumUTF16Length)
        }
        transcript = update.text
        return update
    }

    private func clearTranscriptState() {
        transcript = ""
        // Assign a fresh assembler instead of clearing its backing array with
        // keepingCapacity: true. A completed or cancelled turn must release
        // its large fragment storage before the service is reused.
        transcriptAssembler = TranscriptAssembler()
    }

    private func handleSystemInterruption() async {
        guard activeGeneration != nil, isMicrophoneInput else { return }
        await interrupt("The audio session was interrupted.", reason: .systemInterruption)
    }

    private func handleApplicationBackground() async {
        guard activeGeneration != nil, isMicrophoneInput else { return }
        await interrupt("The application entered the background.", reason: .appBackground)
    }

    private func handleRouteChange() async {
        guard activeGeneration != nil, isMicrophoneInput else { return }
        await interrupt("The audio route changed.", reason: .routeChange)
    }

    private func interrupt(
        _ message: String,
        reason: VoiceInterruptionReason = .systemInterruption,
        abandonInvalidatedEngine: Bool = false
    ) async {
        guard let currentGeneration = activeGeneration else { return }
        terminalError = .interrupted(message)
        resultsContinuation?.finish(throwing: VoiceLifecycleInterruption(reason: reason))
        await cancelGeneration(
            currentGeneration,
            abandonInvalidatedEngine: abandonInvalidatedEngine
        )
    }

    private func clearResultsContinuation(_ currentGeneration: UInt64) {
        guard activeGeneration == currentGeneration else { return }
        resultsContinuation = nil
    }

    private func completeAnalysisTask(_ currentGeneration: UInt64) async {
        guard analysisTaskGeneration == currentGeneration else { return }
        analysisTask = nil
        analysisTaskGeneration = nil
        guard activeGeneration == nil,
              !tapInstalled,
              analyzer == nil,
              analyzerCancellationTask == nil,
              framePumpTask == nil else { return }
        frameRing = nil
        audioEngine = AVAudioEngine()
        _ = await releaseAudioSessionIfNeeded()
    }

    private func handleAnalysisFailure(_ error: Error, generation currentGeneration: UInt64) async {
        guard isCurrent(currentGeneration) else { return }
        terminalError = (error as? VoiceError) ?? .underlying("Speech analysis failed.")
        analysisError = error
        // This method is called by analysisTask itself. Never await that task
        // from inside its own failure path.
        await cancelGeneration(currentGeneration, awaitAnalysisTask: false)
    }
}
