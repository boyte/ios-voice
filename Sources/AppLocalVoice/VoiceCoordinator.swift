import Foundation

/// Internal handoff from the serialized recognition lifecycle to the facade's
/// existing opt-in diagnostic delivery. It contains no speech or host content.
struct RecognitionSessionDiagnosticEmission: Sendable, Equatable {
    let sessionID: RecognitionSessionID
    let phase: VoiceDiagnosticPhase
    let state: VoiceState
    let errorCategory: VoiceErrorCategory?
    let durationNanoseconds: UInt64
}

/// Serializes the public voice lifecycle.
///
/// The coordinator owns the lifecycle truth. Every operation has one identity
/// containing both a UUID and a monotonically increasing generation. Provider
/// callbacks, cleanup completions, and control completions must still own that
/// identity before they can publish an event or mutate state.
actor VoiceCoordinator {
    private static let eventBufferCapacity = 8
    static let maximumEventSubscribers = 8
    private static let defaultCleanupTimeout: Duration = .seconds(2)

    private struct OperationToken: Hashable, Sendable {
        let id: UUID
        let generation: UInt64
    }

    private enum SpeechLane: Sendable, Equatable {
        case queued
        case immediate
    }

    private enum Operation: Equatable {
        case listening(OperationToken)
        case speaking(OperationToken, SpeechLane)
    }

    private struct RecognitionSessionRecord {
        let id: RecognitionSessionID
        let token: OperationToken
        let publicationPolicy: TranscriptPublicationPolicy
        let lifecyclePolicy: AudioLifecyclePolicy
        let maximumRecognitionDuration: Duration?
        var diagnostic: RecognitionSessionDiagnosticRecord?
        var nextEventOrdinal: UInt64
        var nextPreviewRevision: UInt64
        var latestPreview: TranscriptPreview?
    }

    private struct RecognitionSessionDiagnosticRecord {
        let startedAtNanoseconds: UInt64
        let continuation: AsyncStream<RecognitionSessionDiagnosticEmission>.Continuation
        var terminal: RecognitionSessionDiagnosticTerminal?
        var terminalEmitted = false
    }

    private struct RecognitionSessionDiagnosticTerminal {
        let phase: VoiceDiagnosticPhase
        let errorCategory: VoiceErrorCategory?
    }

    private struct ListeningUnwindResult {
        let resourcesReleased: Bool
        let terminalError: VoiceError?
    }

    private let input: any SpeechInput
    private let output: any SpeechOutput
    private let defaultLifecyclePolicy: AudioLifecyclePolicy
    private let cleanupTimeout: Duration
    private let runtimeLease: ProcessVoiceRuntimeLease
    private let runtimeOwnerID = UUID()
    private let stableTranscriptClock: any StableTranscriptClock

    private(set) var state: VoiceState = .idle
    private(set) var recoveryState: VoiceRecoveryState = .ready
    private var operation: Operation?
    private var generation: UInt64 = 0
    // Distinct from an operation token generation. This revision advances for
    // every canonical publication so snapshot capture can detect queue-only
    // mutations that do not start a new voice operation.
    private var runtimeSnapshotGeneration: UInt64 = 0
    private var ownsRuntimeLease = false
    private var preAdmissionInFlight = false
    private var recognitionPreparationInFlight = false

    private var eventContinuations: [UUID: AsyncStream<VoiceEvent>.Continuation] = [:]
    private var eventContinuationOrder: [UUID] = []
    private var recognitionEventDelivery: RecognitionEventDelivery
    private var canonicalEventDelivery: CanonicalVoiceEventDelivery
    private let speechQueue: SpeechQueueEngine
    private var speechQueueTask: Task<Void, Never>?
    private var speechQueueWorkerID: UUID?
    private var queuedPlaybackSupersededByRecognition: Set<SpeechPlaybackID> = []
    private var speechPlaybackWaiters: [
        SpeechPlaybackID: [UUID: CheckedContinuation<SpeechPlaybackResult, Error>]
    ] = [:]
    // Completed attempts remain observable for a fixed, independent window.
    // This is deliberately not coupled to replay history: replay retention is
    // a text-memory budget, while terminal observation is small metadata.
    private static let maximumTerminalPlaybackOutcomes = 256
    private var knownSpeechPlaybackIDs: Set<SpeechPlaybackID> = []
    private var speechPlaybackOutcomes: [SpeechPlaybackID: Result<SpeechPlaybackResult, Error>] = [:]
    private var pendingSpeechPlaybackErrors: [SpeechPlaybackID: Error] = [:]
    private var speechPlaybackResultOrder: [SpeechPlaybackID] = []
    private var nextImmediatePlaybackOrdinal: UInt64 = 0
    private var nextRecoveryEventOrdinal: UInt64 = 0
    private var recognitionSession: RecognitionSessionRecord?
    private var stableTranscriptPublisher: StableTranscriptPublisher?
    private var stableChunkTimerTask: Task<Void, Never>?
    private var stableChunkTimerToken: OperationToken?
    private var recognitionDurationTask: Task<Void, Never>?
    private var recognitionDurationToken: OperationToken?
    private var transcriptTask: Task<Void, Never>?
    private var startupTask: Task<Void, Error>?
    private var startupCancellation: CancellationSignal?
    private var finalizationTask: Task<String, Error>?
    private var lastFinalTranscript: String?
    private var listeningTerminalEmitted = false
    // A release may arrive while the accepted session is still waiting for
    // permission, model readiness, or provider startup. Keep its finalization
    // task independent from the caller that issued the release, so cancelling
    // an observation task cannot turn a short PTT press into a cancellation.
    private var pendingSessionFinalization: (
        id: RecognitionSessionID,
        token: OperationToken,
        task: Task<FinalTranscript, Error>
    )?
    // A bounded terminal cache makes a finish racing startup/finalization
    // observe the actual terminal result rather than an incidental
    // invalid-state error. The capacity/text budget is frozen in
    // ResourceBudgets.md; PTT-03 adds duration-expiry semantics to this same
    // cache.
    private var terminalRecognitionOutcomes: [RecognitionSessionID: Result<FinalTranscript, VoiceError>] = [:]
    private var terminalRecognitionOutcomeOrder: [RecognitionSessionID] = []

    private var invalidatedTokens: Set<OperationToken> = []
    private var activeStartupID: OperationToken?

    // Cleanup is deliberately unstructured. If an Apple framework or a
    // provider refuses cancellation, a structured task group would wait for
    // that child forever when the timeout wins. The task is retained here so a
    // later close can reconcile it without starting a second cleanup race.
    private var listeningCleanupTask: Task<Bool, Never>?
    private var listeningCleanupToken: OperationToken?
    private var listeningCleanupCompletedToken: OperationToken?
    private var listeningCleanupCompletedSuccessfully = false
    private var cleanupTimedOutTokens: Set<OperationToken> = []

    private var speakingStopTask: Task<Void, Never>?
    private var speakingStopToken: OperationToken?
    private var speakingTerminalEmitted = false
    private var admissionEpoch: UInt64 = 0
    private var unresolvedOutputFailureEmitted = false

    private var closeInFlight = false
    private var closeWaiters: [CheckedContinuation<Bool, Never>] = []

    init(
        input: any SpeechInput,
        output: any SpeechOutput,
        cleanupTimeout: Duration = VoiceCoordinator.defaultCleanupTimeout,
        runtimeLease: ProcessVoiceRuntimeLease = ProcessVoiceRuntimeLease(),
        eventSubscriberRegistry: CanonicalEventSubscriberRegistry =
            CanonicalEventSubscriberRegistry(),
        stableTranscriptClock: any StableTranscriptClock = ContinuousStableTranscriptClock(),
        queueConfiguration: SpeechQueueConfiguration = .init(),
        lifecyclePolicy: AudioLifecyclePolicy = .init()
    ) {
        self.input = input
        self.output = output
        defaultLifecyclePolicy = lifecyclePolicy
        self.cleanupTimeout = cleanupTimeout
        self.runtimeLease = runtimeLease
        speechQueue = SpeechQueueEngine(configuration: queueConfiguration)
        recognitionEventDelivery = RecognitionEventDelivery(
            subscriberRegistry: eventSubscriberRegistry
        )
        canonicalEventDelivery = CanonicalVoiceEventDelivery(
            registry: eventSubscriberRegistry
        )
        self.stableTranscriptClock = stableTranscriptClock
    }

    deinit {
        // An idle facade can be discarded without an explicit close. Retain
        // exclusivity while work or cleanup is still active, but never leave
        // an otherwise reusable process lease stranded after its owner dies.
        if ownsRuntimeLease, operation == nil {
            runtimeLease.release(for: runtimeOwnerID)
        }
    }

    /// Returns a bounded newest-value stream. Intermediate snapshots may be
    /// discarded for a stalled consumer; lifecycle terminal events are emitted
    /// only by the operation that still owns the stream. The oldest active
    /// subscription is finished when the subscriber ceiling is reached.
    func events() -> AsyncStream<VoiceEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(Self.eventBufferCapacity)) { continuation in
            if eventContinuations.count >= Self.maximumEventSubscribers,
               let oldest = eventContinuationOrder.first {
                eventContinuationOrder.removeFirst()
                eventContinuations.removeValue(forKey: oldest)?.finish()
            }
            eventContinuations[id] = continuation
            eventContinuationOrder.append(id)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }

    /// Additive, typed recognition-only stream. Events are ordered per session
    /// and durable-buffer overflow terminates only the affected subscriber.
    func recognitionEvents() -> AsyncThrowingStream<RecognitionEvent, Error> {
        recognitionEventDelivery.subscribe { [weak self] id in
            Task { await self?.removeRecognitionEventContinuation(id) }
        }
    }

    /// Canonical throwing stream spanning recognition, speech queue, and
    /// process recovery events. This is the host integration surface; the
    /// recognition-only stream remains as an additive compatibility projection.
    func voiceEvents() async -> VoiceEventStream {
        // Flush queue transitions accepted by an earlier operation before
        // taking the subscription boundary. Existing subscribers receive
        // those transitions; the new subscriber receives their resulting
        // state in its snapshot instead of a stale pre-transition view.
        await publishSpeechQueueEvents()
        // `runtimeSnapshot()` may suspend while it reads the queue. Once it
        // returns, this actor admits the subscription without another await,
        // so no canonical publication can overtake its initial snapshot.
        let initialSnapshot = VoiceEventStreamEvent.snapshot(await runtimeSnapshot())
        let stream = canonicalEventDelivery.subscribe(initialEvent: initialSnapshot) { [weak self] id in
            Task { await self?.removeCanonicalEventContinuation(id) }
        }
        return stream
    }

    /// Accepts text into the provider-neutral speech queue. Acceptance is
    /// independent from playback start, so hosts may enqueue returned chat
    /// text while another item is speaking.
    func enqueueSpeech(
        _ request: SpeechItemRequest,
        policy: SpeechEnqueuePolicy = .append
    ) async throws -> SpeechPlaybackAcceptance {
        let acquiredForQueue = try acquireQueueLeaseIfNeeded()
        do {
            let acceptance = try await speechQueue.enqueue(request, policy: policy)
            knownSpeechPlaybackIDs.insert(acceptance.playbackID)
            if policy == .replaceCurrent || policy == .replaceAll,
               isQueuedSpeaking {
                // Admission is now guaranteed. Stop the provider only after
                // the replacement has been accepted by the queue.
                _ = await stopSpeaking()
            }
            await publishSpeechQueueEvents()
            startQueuedPlaybackIfNeeded()
            return acceptance
        } catch {
            releaseQueueLeaseIfUnused(acquiredForQueue)
            throw error
        }
    }

    func replaySpeech(
        _ itemID: SpeechItemID,
        policy: SpeechEnqueuePolicy = .append
    ) async throws -> SpeechPlaybackAcceptance {
        let acquiredForQueue = try acquireQueueLeaseIfNeeded()
        do {
            let acceptance = try await speechQueue.replay(itemID, policy: policy)
            knownSpeechPlaybackIDs.insert(acceptance.playbackID)
            if policy == .replaceCurrent || policy == .replaceAll,
               isQueuedSpeaking {
                _ = await stopSpeaking()
            }
            await publishSpeechQueueEvents()
            startQueuedPlaybackIfNeeded()
            return acceptance
        } catch {
            releaseQueueLeaseIfUnused(acquiredForQueue)
            throw error
        }
    }

    /// Accepts a direct, non-replayable playback attempt. Immediate work has
    /// the same opaque playback identity/result contract as queued work, but
    /// its item is intentionally never inserted into queue history.
    func speakImmediately(
        _ text: String,
        configuration: SpeechConfiguration = .init()
    ) async throws -> SpeechPlaybackAcceptance {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw VoiceError.invalidSpeechItem("Immediate speech requires non-empty text.")
        }
        guard normalized.utf16.count <= VoiceTextLimits.maximumUTF16Length else {
            throw VoiceError.textTooLong(maximumUTF16Length: VoiceTextLimits.maximumUTF16Length)
        }
        let token = try await reserveAfterResourceAdmission(.speaking(.immediate))
        let itemID = SpeechItemID()
        let playbackID = SpeechPlaybackID()
        let ordinal = nextImmediatePlaybackOrdinal
        nextImmediatePlaybackOrdinal = nextImmediatePlaybackOrdinal == .max
            ? 0 : nextImmediatePlaybackOrdinal + 1
        let acceptance = SpeechPlaybackAcceptance(
            itemID: itemID,
            playbackID: playbackID,
            acceptedEventOrdinal: ordinal
        )
        knownSpeechPlaybackIDs.insert(playbackID)
        speakingTerminalEmitted = false
        transition(to: .speaking, token: token)
        emit(.speechStarted, token: token)
        Task { [weak self] in
            await self?.runImmediatePlayback(
                text: normalized,
                configuration: configuration,
                itemID: itemID,
                playbackID: playbackID,
                token: token,
                acceptanceOrdinal: ordinal
            )
        }
        return acceptance
    }

    func pauseSpeechQueue() async -> SpeechControlResult {
        let result = await speechQueue.pause()
        if isQueuedSpeaking { await output.pause() }
        await publishSpeechQueueEvents()
        return result
    }

    func resumeSpeechQueue() async -> SpeechControlResult {
        let result = await speechQueue.resume()
        if isQueuedSpeaking { await output.resume() }
        await publishSpeechQueueEvents()
        startQueuedPlaybackIfNeeded()
        return result
    }

    func stopSpeechQueue() async -> [SpeechPlaybackResult] {
        let queuedTask = speechQueueTask
        queuedTask?.cancel()
        speechQueueTask = nil
        speechQueueWorkerID = nil
        let results = await speechQueue.stopActive()
        if isQueuedSpeaking { _ = await stopSpeaking() }
        results.forEach { resolveSpeechPlayback($0) }
        if let queuedTask { _ = await queuedTask.value }
        await publishSpeechQueueEvents()
        return results
    }

    /// Stops the active queued playback, terminalizes every pending attempt,
    /// and leaves ordered playback suspended.
    func stopAndClearSpeechQueue() async -> [SpeechPlaybackResult] {
        let queuedTask = speechQueueTask
        queuedTask?.cancel()
        speechQueueTask = nil
        speechQueueWorkerID = nil
        let results = await speechQueue.stopAndClear()
        if isQueuedSpeaking { _ = await stopSpeaking() }
        results.forEach { resolveSpeechPlayback($0) }
        if let queuedTask { _ = await queuedTask.value }
        await publishSpeechQueueEvents()
        return results
    }

    func skipSpeechQueue() async -> SpeechPlaybackResult? {
        let queuedTask = speechQueueTask
        queuedTask?.cancel()
        speechQueueTask = nil
        speechQueueWorkerID = nil
        let result = await speechQueue.skip()
        if isQueuedSpeaking { _ = await stopSpeaking() }
        if let result { resolveSpeechPlayback(result) }
        if let queuedTask { _ = await queuedTask.value }
        await publishSpeechQueueEvents()
        startQueuedPlaybackIfNeeded()
        return result
    }

    func clearPendingSpeechQueue() async -> [SpeechPlaybackResult] {
        let results = await speechQueue.clearPending()
        results.forEach { resolveSpeechPlayback($0) }
        await publishSpeechQueueEvents()
        return results
    }

    func waitForSpeechPlayback(_ playbackID: SpeechPlaybackID) async throws -> SpeechPlaybackResult {
        let waiterID = UUID()
        let result = try await withTaskCancellationHandler(operation: {
            if let outcome = speechPlaybackOutcomes[playbackID] {
                return try outcome.get()
            }
            guard knownSpeechPlaybackIDs.contains(playbackID) else {
                throw VoiceError.invalidState("The playback attempt is unknown or its terminal result has expired.")
            }
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                speechPlaybackWaiters[playbackID, default: [:]][waiterID] = continuation
            }
        }, onCancel: { [weak self] in
            Task { await self?.cancelSpeechPlaybackWaiter(waiterID, playbackID: playbackID) }
        })
        return result
    }

    private func cancelSpeechPlaybackWaiter(_ waiterID: UUID, playbackID: SpeechPlaybackID) {
        guard let continuation = speechPlaybackWaiters[playbackID]?.removeValue(forKey: waiterID) else {
            return
        }
        if speechPlaybackWaiters[playbackID]?.isEmpty == true {
            speechPlaybackWaiters.removeValue(forKey: playbackID)
        }
        continuation.resume(throwing: CancellationError())
    }

    private func resolveSpeechPlayback(_ result: SpeechPlaybackResult, error: Error? = nil) {
        let waiters = speechPlaybackWaiters.removeValue(forKey: result.playbackID)
            .map { Array($0.values) } ?? []
        let outcome: Result<SpeechPlaybackResult, Error> = error.map(Result.failure) ?? .success(result)
        if speechPlaybackOutcomes[result.playbackID] == nil {
            speechPlaybackResultOrder.append(result.playbackID)
        }
        speechPlaybackOutcomes[result.playbackID] = outcome
        while speechPlaybackResultOrder.count > Self.maximumTerminalPlaybackOutcomes {
            let evicted = speechPlaybackResultOrder.removeFirst()
            speechPlaybackOutcomes.removeValue(forKey: evicted)
            knownSpeechPlaybackIDs.remove(evicted)
        }
        // Every concurrent observer receives the same terminal truth; one
        // caller cannot consume an outcome meant for another.
        waiters.forEach { waiter in
            switch outcome {
            case .success(let value): waiter.resume(returning: value)
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    func capabilities(for locale: Locale) async -> SpeechCapabilities {
        await input.capabilities(for: locale)
    }

    func capabilitySnapshot(for locale: Locale) async -> VoiceCapabilitySnapshot {
        async let microphonePermission = input.microphonePermissionStatus()
        async let speechPermission = input.authorizationStatus()
        async let capabilities = input.capabilities(for: locale)
        async let modelInstallationAvailable = input.modelInstallationAvailable(for: locale)
        async let voices = output.availableVoices(for: locale)

        let (microphone, speech, recognitionCapabilities, canInstallModel, installedVoices) = await (
            microphonePermission,
            speechPermission,
            capabilities,
            modelInstallationAvailable,
            voices
        )
        let microphoneStatus: VoicePermissionStatus = microphone
        let speechStatus = Self.permissionStatus(from: speech)
        let recognitionAvailability: VoiceCapabilityAvailability
        let readiness: RecognitionModelReadiness
        if !recognitionCapabilities.isSupported {
            readiness = .unavailable
            recognitionAvailability = .unavailable(
                VoiceError.unsupportedLocale(locale).failure
            )
        } else if recognitionCapabilities.supportsOnDevice {
            readiness = .installed
            recognitionAvailability = .available
        } else if canInstallModel {
            readiness = .notInstalled(installationAvailable: true)
            recognitionAvailability = .unavailable(
                VoiceError.onDeviceRecognitionUnavailable(recognitionCapabilities.locale).failure
            )
        } else {
            readiness = .notInstalled(installationAvailable: false)
            recognitionAvailability = .unavailable(
                VoiceError.onDeviceRecognitionUnavailable(recognitionCapabilities.locale).failure
            )
        }
        let synthesisAvailability: VoiceCapabilityAvailability = installedVoices.isEmpty
            ? .unavailable(VoiceError.speechSynthesisUnavailable("No installed voice for this locale.").failure)
            : .available
        return VoiceCapabilitySnapshot(
            microphonePermission: microphoneStatus,
            speechRecognitionPermission: speechStatus,
            recognition: RecognitionCapability(
                requestedLocale: locale,
                resolvedLocale: recognitionCapabilities.isSupported ? recognitionCapabilities.locale : nil,
                modelReadiness: readiness,
                availability: recognitionAvailability
            ),
            installedVoices: installedVoices,
            features: [
                .speechRecognition: recognitionAvailability,
                .modelInstallation: canInstallModel
                    ? .available
                    : .unavailable(
                        VoiceError.onDeviceRecognitionUnavailable(recognitionCapabilities.locale).failure
                    ),
                .liveTranscriptPreview: recognitionAvailability,
                .stableTranscriptChunks: recognitionAvailability,
                .speechSynthesis: synthesisAvailability,
                .speechQueue: .available,
                .speechPauseResume: .available
            ]
        )
    }

    func prepareRecognition(
        for locale: Locale,
        policy: SpeechModelPolicy,
        progress: RecognitionPreparationProgressHandler? = nil
    ) async throws -> RecognitionPreparationResult {
        guard operation == nil,
              !preAdmissionInFlight,
              !recognitionPreparationInFlight,
              !closeInFlight else {
            throw VoiceError.invalidState("Recognition preparation requires an idle voice service.")
        }
        recognitionPreparationInFlight = true
        defer { recognitionPreparationInFlight = false }
        let installedModel = try await input.prepareRecognition(
            for: locale,
            policy: policy,
            progress: progress
        )
        try Task.checkCancellation()
        return RecognitionPreparationResult(
            capabilitySnapshot: await capabilitySnapshot(for: locale),
            installedModel: installedModel
        )
    }

    func availableVoices(for locale: Locale) async -> [SpeechVoice] {
        await output.availableVoices(for: locale)
    }

    func runtimeSnapshot() async -> VoiceRuntimeSnapshot {
        // Querying the queue crosses an actor boundary. Retry if another
        // coordinator operation ran while suspended so the lifecycle and
        // queue portions describe one logical instant.
        while true {
            let capturedGeneration = runtimeSnapshotGeneration
            let queue = await speechQueue.snapshot()
            guard capturedGeneration == runtimeSnapshotGeneration else { continue }
            let recognition = recognitionSession.flatMap { session -> VoiceRecognitionSnapshot? in
                guard let state = Self.recognitionState(from: self.state) else { return nil }
                return VoiceRecognitionSnapshot(sessionID: session.id, state: state, latestPreview: session.latestPreview)
            }
            return VoiceRuntimeSnapshot(state: state, recoveryState: recoveryState, recognition: recognition, queue: queue, generation: capturedGeneration)
        }
    }

    /// Admission epoch used to bind facade preflight work to the close
    /// boundary. This is an internal coordinator contract.
    func currentAdmissionEpoch() -> UInt64 { admissionEpoch }

    /// Whether a new public operation can reserve the coordinator now.
    ///
    /// This is intentionally separate from `state`: startup and cleanup may
    /// temporarily report `.idle` for source compatibility while still
    /// owning an operation reservation.
    func isAvailableForNewOperation() async -> Bool {
        await preAdmissionErrorForNewOperation() == nil
    }

    /// Read-only facade preflight used before diagnostics claim a speech
    /// request. Authoritative admission is still repeated atomically by
    /// `reserveAfterResourceAdmission`.
    func preAdmissionErrorForNewOperation() async -> VoiceError? {
        guard canReserveOperation, !preAdmissionInFlight else {
            return .invalidState("A voice operation is already active.")
        }
        guard ownsRuntimeLease || runtimeLease.canAcquire(for: runtimeOwnerID) else {
            return .serviceInUse
        }
        let outputReleased = await output.resourcesAreReleased()
        if Task.isCancelled { return .cancelled }
        guard outputReleased else {
            markUnresolvedOutputFailure()
            return Self.speechResourceFailure
        }
        return nil
    }

    func startListening(configuration: RecognitionConfiguration = .init()) async throws {
        let sessionConfiguration = RecognitionSessionConfiguration(
            recognition: configuration,
            publicationPolicy: .previewAndFinal
        )
        let (token, _) = try await admitRecognitionSession(configuration: sessionConfiguration)
        try await runRecognitionStartup(
            configuration: sessionConfiguration.recognition,
            lifecyclePolicy: sessionConfiguration.lifecyclePolicy,
            token: token
        )
    }

    func startSession(
        configuration: RecognitionSessionConfiguration,
        diagnosticContinuation: AsyncStream<RecognitionSessionDiagnosticEmission>.Continuation? = nil
    ) async throws -> RecognitionSessionAcceptance {
        let (token, acceptance) = try await admitRecognitionSession(
            configuration: configuration,
            diagnosticContinuation: diagnosticContinuation
        )
        Task { [weak self] in
            do {
                try await self?.runRecognitionStartup(
                    configuration: configuration.recognition,
                    lifecyclePolicy: configuration.lifecyclePolicy,
                    token: token
                )
            } catch {
                // Startup failures are represented by the session's typed
                // terminal event. The legacy adapter awaits and rethrows.
            }
        }
        return acceptance
    }

    private func admitRecognitionSession(
        configuration: RecognitionSessionConfiguration,
        diagnosticContinuation: AsyncStream<RecognitionSessionDiagnosticEmission>.Continuation? = nil
    ) async throws -> (OperationToken, RecognitionSessionAcceptance) {
        try Self.validateRecognitionDuration(configuration.maximumRecognitionDuration)
        try await giveRecognitionPriorityOverSpeechIfNeeded()
        let token = try await reserveAfterResourceAdmission(.listening)
        let sessionID = RecognitionSessionID()
        activeStartupID = token
        listeningTerminalEmitted = false
        lastFinalTranscript = nil
        stableChunkTimerTask?.cancel()
        stableChunkTimerTask = nil
        stableChunkTimerToken = nil
        recognitionDurationTask?.cancel()
        recognitionDurationTask = nil
        recognitionDurationToken = nil
        if case .stableChunks(let policy) = configuration.publicationPolicy {
            stableTranscriptPublisher = StableTranscriptPublisher(
                sessionID: sessionID,
                policy: policy
            )
        } else {
            stableTranscriptPublisher = nil
        }
        recognitionSession = RecognitionSessionRecord(
            id: sessionID,
            token: token,
            publicationPolicy: configuration.publicationPolicy,
            lifecyclePolicy: configuration.lifecyclePolicy,
            maximumRecognitionDuration: configuration.maximumRecognitionDuration,
            diagnostic: diagnosticContinuation.map {
                RecognitionSessionDiagnosticRecord(
                    startedAtNanoseconds: Self.monotonicNanoseconds,
                    continuation: $0
                )
            },
            nextEventOrdinal: RecognitionEvent.acceptedEventOrdinal,
            nextPreviewRevision: 0,
            latestPreview: nil
        )
        emitRecognition(.accepted, token: token)
        transition(to: .preparing, token: token)
        emitRecognitionDiagnosticStarted(token: token)
        return (token, RecognitionSessionAcceptance(sessionID: sessionID))
    }

    /// Recognition is an input-first interaction. Before admitting a new
    /// turn, stop the active output lane, retain queued work in suspended
    /// order, and only then reserve the microphone. This prevents an input
    /// provider and the synthesizer from overlapping on a process audio
    /// session while preserving chat replies the host queued for later.
    private func giveRecognitionPriorityOverSpeechIfNeeded() async throws {
        guard case .speaking(_, let lane) = operation else { return }

        if lane == .queued {
            // Stop queue advancement first so cancellation of the worker
            // cannot start a following pending attempt during arbitration.
            _ = await speechQueue.suspend()
            if let active = await speechQueue.activeAttempt() {
                queuedPlaybackSupersededByRecognition.insert(active.playbackID)
            }
        }

        guard await stopSpeaking() else {
            throw Self.speechResourceFailure
        }

        if lane == .queued {
            // Let the worker observe the completed output stop and record its
            // terminal queue result before inspecting any still-active attempt.
            let queuedTask = speechQueueTask
            if let queuedTask { await queuedTask.value }
            speechQueueTask = nil
            speechQueueWorkerID = nil
            // The output release above is the transaction boundary. Only
            // after it succeeds may the active queue attempt be terminalized
            // as superseded; pending attempts stay suspended and replayable.
            let results = await speechQueue.stopActive(reason: .supersededByRecognition)
            queuedPlaybackSupersededByRecognition.subtract(results.map(\.playbackID))
            results.forEach { resolveSpeechPlayback($0) }
            await publishSpeechQueueEvents(resolveResults: false)
        }
    }

    private func runRecognitionStartup(
        configuration: RecognitionConfiguration,
        lifecyclePolicy: AudioLifecyclePolicy,
        token: OperationToken
    ) async throws {
        let cancellation = CancellationSignal()
        startupCancellation = cancellation
        let providerTask = Task { [weak self] in
            guard let self else { throw VoiceError.cancelled }
            try await self.startListeningProvider(
                configuration: configuration,
                lifecyclePolicy: lifecyclePolicy,
                token: token
            )
        }
        startupTask = providerTask
        do {
            try await withTaskCancellationHandler(operation: {
                try await Self.awaitProviderStartup(providerTask, cancellation: cancellation)
            }, onCancel: { [weak self] in
                cancellation.signal()
                providerTask.cancel()
                Task { await self?.cancelListening(for: token) }
            })
            completeStartup(token)
            try Task.checkCancellation()
        } catch {
            let cancellationRequested = Task.isCancelled ||
                error is CancellationError ||
                invalidatedTokens.contains(token) ||
                (error as? VoiceError) == .cancelled
            if cancellationRequested {
                cancellation.signal()
                providerTask.cancel()
                retainStartupUntilCompletion(providerTask, token: token)
            } else {
                // A provider error means the startup task has completed.
                completeStartup(token)
            }
            // A cancellation or close may already own the cleanup path. Never
            // let a late provider error publish a second terminal outcome.
            if invalidatedTokens.contains(token) {
                // The cancellation handler may have started the same cleanup
                // on an unstructured task. Join that existing bounded path
                // before returning so the caller never observes cancellation
                // while the coordinator is still visibly preparing.
                if isOwned(token) {
                    _ = await unwindListening(
                        token: token,
                        reason: .cancelled,
                        cancelInput: true,
                        emitFailure: false,
                        joinTranscriptTask: true
                    )
                }
                throw VoiceError.cancelled
            }
            guard isOwned(token) else { throw VoiceError.cancelled }
            _ = await unwindListening(
                token: token,
                reason: terminationReason(for: error),
                cancelInput: true,
                emitFailure: true,
                joinTranscriptTask: true
            )
            if cancellationRequested {
                throw VoiceError.cancelled
            }
            throw normalizedCancellation(error)
        }
    }

    func endSession(id: RecognitionSessionID) async throws -> FinalTranscript {
        if let outcome = terminalRecognitionOutcomes[id] {
            return try outcome.get()
        }
        guard let session = recognitionSession, session.id == id else {
            throw VoiceError.invalidState("The recognition session ID is not active.")
        }
        // A press-to-talk release may arrive before permission/model startup
        // transitions the session to `.listening`. It latches onto this exact
        // accepted session and awaits normal startup/finalization; it is not a
        // cancellation merely because the press was short.
        if activeStartupID == session.token {
            let task: Task<FinalTranscript, Error>
            if let pending = pendingSessionFinalization,
               pending.id == id,
               pending.token == session.token {
                task = pending.task
            } else {
                task = Task { [weak self] in
                    guard let self else { throw VoiceError.cancelled }
                    return try await self.finishPreparedSession(id: id, token: session.token)
                }
                pendingSessionFinalization = (id: id, token: session.token, task: task)
            }
            return try await task.value
        }
        guard session.token == currentListeningToken else {
            throw VoiceError.invalidState("The recognition session ID is not active.")
        }
        let text = try await endListening()
        return FinalTranscript(sessionID: id, text: text)
    }

    /// Finalizes a release that was accepted before provider startup completed.
    /// The task is intentionally independent from the caller that originally
    /// awaited `finishSession`: explicit cancel, close, interruption, or
    /// startup failure owns the terminal outcome, not observer cancellation.
    private func finishPreparedSession(
        id: RecognitionSessionID,
        token: OperationToken
    ) async throws -> FinalTranscript {
        defer {
            if pendingSessionFinalization?.id == id,
               pendingSessionFinalization?.token == token {
                pendingSessionFinalization = nil
            }
        }

        while activeStartupID == token || state == .preparing {
            if let outcome = terminalRecognitionOutcomes[id] {
                return try outcome.get()
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        if let outcome = terminalRecognitionOutcomes[id] {
            return try outcome.get()
        }
        guard let session = recognitionSession,
              session.id == id,
              session.token == token,
              token == currentListeningToken,
              state == .listening else {
            // An explicit cancellation, close, interruption, or startup
            // failure won the documented precedence race. `unwindListening`
            // records its typed terminal result before clearing the session.
            if let outcome = terminalRecognitionOutcomes[id] {
                return try outcome.get()
            }
            throw VoiceError.cancelled
        }
        let text = try await endListening()
        let final = FinalTranscript(sessionID: id, text: text)
        storeTerminalRecognitionOutcome(.success(final), for: id)
        return final
    }

    func cancelSession(id: RecognitionSessionID) async {
        guard let session = recognitionSession,
              session.id == id,
              session.token == currentListeningToken else { return }
        await cancelListening()
    }

    private func startListeningProvider(
        configuration: RecognitionConfiguration,
        lifecyclePolicy: AudioLifecyclePolicy,
        token: OperationToken
    ) async throws {
        guard isCurrent(token) else { throw VoiceError.cancelled }
        guard await input.requestMicrophonePermission() else {
            throw VoiceError.microphonePermissionDenied
        }
        try Task.checkCancellation()
        guard await input.requestAuthorization() == .authorized else {
            throw VoiceError.speechPermissionDenied
        }
        try Task.checkCancellation()

        let capabilities = await input.capabilities(for: configuration.locale)
        try Task.checkCancellation()
        guard capabilities.isSupported else {
            throw VoiceError.unsupportedLocale(configuration.locale)
        }

        let stream = try await input.start(
            configuration: configuration,
            lifecyclePolicy: lifecyclePolicy
        )
        try Task.checkCancellation()
        guard isCurrent(token) else { throw VoiceError.cancelled }

        // The provider is authoritative for model installation. Re-read the
        // readiness snapshot after start so a model installed during startup
        // cannot be rejected using a stale preflight result.
        if configuration.policy == .installedModelsOnly {
            let readiness = await input.capabilities(for: configuration.locale)
            try Task.checkCancellation()
            guard readiness.supportsOnDevice else {
                throw VoiceError.onDeviceRecognitionUnavailable(configuration.locale)
            }
        }
        guard isCurrent(token) else { throw VoiceError.cancelled }

        transition(to: .listening, token: token)
        scheduleRecognitionDurationLimit(token: token)
        transcriptTask?.cancel()
        transcriptTask = Task { [weak self] in
            do {
                for try await update in stream {
                    guard let self else { return }
                    await self.acceptTranscript(update, token: token)
                }
                await self?.handleUnexpectedInputEnd(token: token)
            } catch {
                await self?.handleListeningFailure(error, token: token)
            }
        }
    }

    func endListening(
        completionReason: VoiceTerminationReason = .completed
    ) async throws -> String {
        guard case .listening(let token) = operation, state == .listening, isCurrent(token) else {
            throw VoiceError.invalidState("Voice input is not active.")
        }
        transition(to: .finalizing, token: token)

        do {
            let stopTask = Task { [input] in
                try await input.stop()
            }
            finalizationTask = stopTask
            let text = try await withTaskCancellationHandler(operation: {
                try await stopTask.value
            }, onCancel: { [weak self] in
                stopTask.cancel()
                Task { await self?.cancelListening(for: token) }
            })
            finalizationTask = nil
            guard text.utf16.count <= VoiceTextLimits.maximumUTF16Length else {
                let error = VoiceError.textTooLong(
                    maximumUTF16Length: VoiceTextLimits.maximumUTF16Length
                )
                _ = await unwindListening(
                    token: token,
                    reason: .failed(error),
                    cancelInput: false,
                    emitFailure: true,
                    joinTranscriptTask: true
                )
                throw error
            }
            // `close()` may have invalidated this token while the provider's
            // stop operation was non-cooperative. Once that stop finally
            // returns, its retained finalization dependency is gone. Re-run
            // the bounded cleanup reconciliation here so a close that already
            // observed released resources can finish the lifecycle instead
            // of leaving a permanently failed, reusable coordinator behind.
            finalizeListeningIfReady(token)
            try Task.checkCancellation()
            guard isCurrent(token) else { throw VoiceError.cancelled }

            let unwindResult = await unwindListening(
                token: token,
                reason: completionReason,
                cancelInput: false,
                emitFailure: false,
                joinTranscriptTask: true,
                authoritativeFinalText: text
            )
            if let terminalError = unwindResult.terminalError {
                throw terminalError
            }
            guard unwindResult.resourcesReleased else {
                throw cleanupError(for: token)
            }
            return text
        } catch {
            // Cleanup failures are an outcome of this operation, not a
            // cancellation. `unwindListening` has already emitted its one
            // terminal failure and kept ownership so a later close can retry.
            if let voiceError = error as? VoiceError,
               voiceError == Self.cleanupFailure || voiceError == Self.cleanupTimeoutFailure {
                throw voiceError
            }
            if invalidatedTokens.contains(token) || error is CancellationError {
                if isOwned(token) && !invalidatedTokens.contains(token) {
                    _ = await unwindListening(
                        token: token,
                        reason: .cancelled,
                        cancelInput: true,
                        emitFailure: false,
                        joinTranscriptTask: true
                    )
                }
                throw VoiceError.cancelled
            }
            guard isOwned(token) else { throw normalizedCancellation(error) }
            _ = await unwindListening(
                token: token,
                reason: terminationReason(for: error),
                cancelInput: true,
                emitFailure: true,
                joinTranscriptTask: true
            )
            throw error
        }
    }

    func cancelListening() async {
        guard case .listening(let token) = operation else { return }
        startupCancellation?.signal()
        startupTask?.cancel()
        finalizationTask?.cancel()
        _ = await unwindListening(
            token: token,
            reason: .cancelled,
            cancelInput: true,
            emitFailure: false,
            joinTranscriptTask: true
        )
        if let startup = activeStartupID, startup == token {
            if !(await waitForStartupCompletion(startup)) {
                cleanupTimedOutTokens.insert(token)
                transition(to: .failed, token: token, allowInvalidated: true)
            }
        }
        finalizeListeningIfReady(token)
    }

    private func cancelListening(for token: OperationToken) async {
        guard isOwned(token) else { return }
        startupCancellation?.signal()
        startupTask?.cancel()
        finalizationTask?.cancel()
        _ = await unwindListening(
            token: token,
            reason: .cancelled,
            cancelInput: true,
            emitFailure: false,
            joinTranscriptTask: true
        )
    }

    /// Closes the lifecycle boundary. `true` means the coordinator has
    /// observed all owned cleanup and is reusable. `false` leaves it in
    /// `.failed`; a later close retries reconciliation.
    /// Preserves the original source-compatible close surface. The internal
    /// reporting variant is used by the facade to distinguish a true terminal
    /// cleanup boundary from a bounded cleanup timeout.
    func close() async {
        _ = await closeAndReport()
    }

    @discardableResult
    func closeAndReport() async -> Bool {
        // A model download has no safe wall-clock deadline and owns a system
        // reservation outside the audio lifecycle. The caller that started
        // preparation must cancel/join it before close can mutate lifecycle
        // state; close therefore fails closed rather than racing or waiting
        // without a bound.
        guard !recognitionPreparationInFlight else { return false }
        if closeInFlight {
            return await withCheckedContinuation { continuation in
                closeWaiters.append(continuation)
            }
        }

        closeInFlight = true
        admissionEpoch &+= 1
        emitRecovery(.reconciling)
        let queuedTask = speechQueueTask
        queuedTask?.cancel()
        speechQueueTask = nil
        speechQueueWorkerID = nil
        _ = await speechQueue.stopAndClear(reason: .closeRequested, suspend: false)
        await speechQueue.clearReplayHistory()
        terminalRecognitionOutcomes.removeAll(keepingCapacity: false)
        terminalRecognitionOutcomeOrder.removeAll(keepingCapacity: false)
        await publishSpeechQueueEvents(resolveResults: false)
        let success: Bool
        if ownsRuntimeLease {
            success = await performClose()
            if success {
                runtimeLease.release(for: runtimeOwnerID)
                ownsRuntimeLease = false
                emitRecovery(.ready)
            } else {
                emitRecovery(.blocked(Self.failure(from: Self.cleanupFailure)))
            }
        } else {
            // A facade that never acquired this process runtime cannot stop,
            // clear, or release another facade's work.
            success = true
            emitRecovery(.ready)
        }
        if let queuedTask { _ = await queuedTask.value }
        await publishSpeechQueueEvents()
        closeInFlight = false
        let waiters = closeWaiters
        closeWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume(returning: success) }
        return success
    }

    private func performClose() async -> Bool {
        if case .listening(let token) = operation {
            startupCancellation?.signal()
            startupTask?.cancel()
            finalizationTask?.cancel()
            _ = await unwindListening(
                token: token,
                reason: .cancelled,
                cancelInput: true,
                emitFailure: false,
                joinTranscriptTask: true
            )

            if let startup = activeStartupID, startup == token,
               !(await waitForStartupCompletion(startup)) {
                cleanupTimedOutTokens.insert(token)
                transition(to: .failed, token: token, allowInvalidated: true)
            }
            finalizeListeningIfReady(token)

            // A completed but unsuccessful cleanup is retryable in the same
            // close boundary. A still-running cleanup is left alone; waiting
            // again would only extend a bounded close without adding safety.
            if isOwned(token), listeningCleanupTask == nil,
               listeningCleanupCompletedSuccessfully == false,
               !cleanupTimedOutTokens.contains(token) {
                _ = await unwindListening(
                    token: token,
                    reason: .cancelled,
                    cancelInput: true,
                    emitFailure: false,
                    joinTranscriptTask: true
                )
            }
            finalizeListeningIfReady(token)
        } else if case .speaking(let token, _) = operation {
            _ = await stopSpeakingOperation(token)
        } else if !(await output.resourcesAreReleased()) {
            // A provider may have completed its logical request while a
            // session-restore failure remained outstanding. Give close one
            // explicit retry even though no operation token remains.
            await output.stop()
        }

        let outputReleased = await output.resourcesAreReleased()
        guard operation == nil &&
                activeStartupID == nil &&
                startupTask == nil &&
                finalizationTask == nil &&
                speakingStopTask == nil &&
                listeningCleanupTask == nil else {
            return false
        }
        guard outputReleased else {
            markUnresolvedOutputFailure()
            return false
        }
        if state == .failed {
            transition(to: .idle, allowInvalidated: true)
            unresolvedOutputFailureEmitted = false
        }
        return true
    }

    func speak(
        _ text: String,
        configuration: SpeechConfiguration = .init(),
        admissionEpoch expectedAdmissionEpoch: UInt64? = nil
    ) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        try Task.checkCancellation()
        guard expectedAdmissionEpoch == nil || expectedAdmissionEpoch == admissionEpoch else {
            throw VoiceError.cancelled
        }
        guard canReserveOperation, !preAdmissionInFlight else {
            throw VoiceError.invalidState("A voice operation is already active.")
        }
        // Direct speech deliberately bypasses the ordered queue. This keeps a
        // suspended queue from blocking a host's immediate request and leaves
        // pending queued attempts untouched.
        let token = try await reserveAfterResourceAdmission(
            .speaking(.immediate),
            expectedAdmissionEpoch: expectedAdmissionEpoch
        )
        speakingTerminalEmitted = false
        transition(to: .speaking, token: token)
        emit(.speechStarted, token: token)

        do {
            try await withTaskCancellationHandler(operation: {
                try await output.speak(
                    normalized,
                    configuration: configuration,
                    lifecyclePolicy: defaultLifecyclePolicy
                )
                try Task.checkCancellation()
                guard isCurrent(token) else { throw VoiceError.cancelled }
                guard await output.resourcesAreReleased() else {
                    throw Self.speechResourceFailure
                }
            }, onCancel: { [weak self] in
                Task { await self?.cancelSpeaking(for: token) }
            })
            speakingTerminalEmitted = true
            emit(.speechFinished, token: token)
            transition(to: .idle, token: token, allowInvalidated: true)
            clearSpeakingOperation(token)
            startQueuedPlaybackIfNeeded()
        } catch {
            let normalizedError = normalize(error)
            if normalizedError != .cancelled,
               !isInterruption(normalizedError),
               case .speaking = operation,
               isOwned(token) {
                speakingTerminalEmitted = true
                emit(.failure(normalizedError), token: token, allowInvalidated: true)
                transition(to: .failed, token: token, allowInvalidated: true)
            }
            if isOwned(token) {
                _ = await stopSpeakingOperation(token)
            }
            // Preserve provider errors for the direct facade just as the
            // queued playback-result path does. Cancellation remains a stable
            // library error because it can be produced by task cancellation
            // rather than the provider itself.
            if error is VoiceLifecycleInterruption {
                // Direct `speak` has no public playback-result identity on
                // which to expose a reason. Never leak the provider-private
                // typed signal across the facade boundary.
                throw VoiceError.interrupted("Speech playback was interrupted.")
            }
            throw normalizedError == .cancelled ? VoiceError.cancelled : error
        }
    }

    private func runImmediatePlayback(
        text: String,
        configuration: SpeechConfiguration,
        itemID: SpeechItemID,
        playbackID: SpeechPlaybackID,
        token: OperationToken,
        acceptanceOrdinal: UInt64
    ) async {
        do {
            await output.setProgressHandler { [weak self] range in
                await self?.publishPlaybackProgress(itemID: itemID, playbackID: playbackID, range: range)
            }
            try await output.speak(
                text,
                configuration: configuration,
                lifecyclePolicy: defaultLifecyclePolicy
            )
            await output.setProgressHandler(nil)
            guard isCurrent(token), await output.resourcesAreReleased() else {
                throw VoiceError.cancelled
            }
            let result = SpeechPlaybackResult(
                itemID: itemID,
                playbackID: playbackID,
                terminalEventOrdinal: acceptanceOrdinal,
                outcome: .finished
            )
            resolveSpeechPlayback(result)
            speakingTerminalEmitted = true
            emit(.speechFinished, token: token)
            transition(to: .idle, token: token, allowInvalidated: true)
            clearSpeakingOperation(token)
            startQueuedPlaybackIfNeeded()
        } catch {
            await output.setProgressHandler(nil)
            let normalized = normalize(error)
            let outcome: SpeechPlaybackOutcome
            if normalized == .cancelled {
                outcome = .cancelled(.stopped)
            } else if isInterruption(normalized) {
                outcome = .interrupted(.systemInterruption)
            } else {
                outcome = .failed(Self.failure(from: normalized))
            }
            let result = SpeechPlaybackResult(
                itemID: itemID,
                playbackID: playbackID,
                terminalEventOrdinal: acceptanceOrdinal,
                outcome: outcome
            )
            let terminalError: Error? = {
                switch outcome {
                case .failed: error
                default: nil
                }
            }()
            resolveSpeechPlayback(result, error: terminalError)
            if normalized != .cancelled, !isInterruption(normalized), isOwned(token) {
                speakingTerminalEmitted = true
                emit(.failure(normalized), token: token, allowInvalidated: true)
                transition(to: .failed, token: token, allowInvalidated: true)
            }
            if isOwned(token) { _ = await stopSpeakingOperation(token) }
        }
    }

    @discardableResult
    func stopSpeaking() async -> Bool {
        guard case .speaking(let token, _) = operation else { return true }
        return await stopSpeakingOperation(token)
    }

    private func cancelSpeaking(for token: OperationToken) async {
        guard isOwned(token) else { return }
        _ = await stopSpeakingOperation(token)
    }

    private func stopSpeakingOperation(_ token: OperationToken) async -> Bool {
        guard isOwned(token) else { return state == .idle }

        if speakingStopTask == nil || speakingStopToken != token {
            invalidatedTokens.insert(token)
            let output = self.output
            speakingStopToken = token
            speakingStopTask = Task.detached {
                await output.stop()
            }
        }

        guard let task = speakingStopTask else { return false }
        guard let _ = await Self.boundedValue(task, timeout: cleanupTimeout) else {
            let error = Self.speechCleanupFailure
            if !speakingTerminalEmitted {
                speakingTerminalEmitted = true
                emit(.failure(error), token: token, allowInvalidated: true)
            }
            transition(to: .failed, token: token, allowInvalidated: true)
            return false
        }

        guard await output.resourcesAreReleased() else {
            let error = Self.speechResourceFailure
            if !speakingTerminalEmitted {
                speakingTerminalEmitted = true
                emit(.failure(error), token: token, allowInvalidated: true)
            }
            transition(to: .failed, token: token, allowInvalidated: true)
            return false
        }
        speakingStopTask = nil
        speakingStopToken = nil
        if !speakingTerminalEmitted {
            speakingTerminalEmitted = true
            emit(.speechCancelled, token: token, allowInvalidated: true)
        }
        transition(to: .idle, token: token, allowInvalidated: true)
        clearSpeakingOperation(token)
        return true
    }

    func pauseSpeaking() async {
        guard case .speaking(let token, _) = operation, isCurrent(token) else { return }
        await output.pause()
        guard isCurrent(token) else { return }
    }

    func resumeSpeaking() async {
        guard case .speaking(let token, _) = operation, isCurrent(token) else { return }
        await output.resume()
        guard isCurrent(token) else { return }
    }

    /// Performs every awaited pre-admission resource check before allocating
    /// an operation token. Cancellation is rechecked after the await and once
    /// more immediately before `reserve`.
    private func reserveAfterResourceAdmission(
        _ requested: OperationKind,
        expectedAdmissionEpoch: UInt64? = nil
    ) async throws -> OperationToken {
        do {
            try Task.checkCancellation()
        } catch {
            throw VoiceError.cancelled
        }

        let admissionEpochAtStart = expectedAdmissionEpoch ?? admissionEpoch
        guard expectedAdmissionEpoch == nil || expectedAdmissionEpoch == admissionEpoch else {
            throw VoiceError.cancelled
        }
        guard canReserveOperation, !preAdmissionInFlight else {
            throw VoiceError.invalidState("A voice operation is already active.")
        }

        preAdmissionInFlight = true
        var acquisition: ProcessVoiceRuntimeLease.Acquisition?
        var retainNewLeaseForBlockedResources = false

        do {
            acquisition = try runtimeLease.acquire(for: runtimeOwnerID)
            ownsRuntimeLease = true
            try Task.checkCancellation()
            guard admissionEpochAtStart == admissionEpoch, !closeInFlight else {
                throw VoiceError.cancelled
            }

            let outputReleased = await output.resourcesAreReleased()
            retainNewLeaseForBlockedResources = !outputReleased
            try Task.checkCancellation()
            guard admissionEpochAtStart == admissionEpoch, !closeInFlight else {
                throw VoiceError.cancelled
            }
            guard outputReleased else {
                markUnresolvedOutputFailure()
                throw Self.speechResourceFailure
            }

            try Task.checkCancellation()
            let token = try reserve(requested)
            preAdmissionInFlight = false
            return token
        } catch {
            preAdmissionInFlight = false
            if acquisition == .acquired, !retainNewLeaseForBlockedResources {
                runtimeLease.release(for: runtimeOwnerID)
                ownsRuntimeLease = false
            }
            if error is CancellationError {
                throw VoiceError.cancelled
            }
            throw error
        }
    }

    private var canReserveOperation: Bool {
        operation == nil &&
            activeStartupID == nil &&
            startupTask == nil &&
            finalizationTask == nil &&
            speakingStopTask == nil &&
            listeningCleanupTask == nil &&
            state == .idle &&
            !recognitionPreparationInFlight &&
            !closeInFlight
    }

    private var isQueuedSpeaking: Bool {
        guard case .speaking(_, .queued) = operation else { return false }
        return true
    }

    private func isInterruption(_ error: VoiceError) -> Bool {
        switch error {
        case .interrupted, .audioRouteUnavailable: return true
        default: return false
        }
    }

    private func reserve(_ requested: OperationKind) throws -> OperationToken {
        guard canReserveOperation else {
            throw VoiceError.invalidState("A voice operation is already active.")
        }

        generation &+= 1
        let token = OperationToken(id: UUID(), generation: generation)
        switch requested {
        case .listening:
            operation = .listening(token)
        case .speaking(let lane):
            operation = .speaking(token, lane)
        }
        return token
    }

    private enum OperationKind { case listening, speaking(SpeechLane) }

    @discardableResult
    private func unwindListening(
        token: OperationToken,
        reason: VoiceTerminationReason,
        cancelInput: Bool,
        emitFailure: Bool,
        joinTranscriptTask: Bool,
        authoritativeFinalText: String? = nil
    ) async -> ListeningUnwindResult {
        guard isOwned(token) else {
            return ListeningUnwindResult(
                resourcesReleased: state == .idle && operation == nil,
                terminalError: nil
            )
        }
        invalidatedTokens.insert(token)
        startupTask?.cancel()
        cancelStableChunkTimer(token: token)
        cancelRecognitionDurationLimit(token: token)
        var finalizationCompleted = true
        if let finalization = finalizationTask {
            finalization.cancel()
            // Do not let a cancelled but non-cooperative stop task silently
            // disappear. Retain it as a cleanup dependency until a bounded
            // later close observes that it has actually returned.
            let waiter = Task.detached {
                _ = try? await finalization.value
                return true
            }
            if await Self.boundedValue(waiter, timeout: cleanupTimeout) != nil {
                finalizationTask = nil
            } else {
                finalizationCompleted = false
                cleanupTimedOutTokens.insert(token)
            }
        }

        let cleanupTask: Task<Bool, Never>
        if let existing = listeningCleanupTask, listeningCleanupToken == token {
            cleanupTask = existing
        } else if listeningCleanupCompletedToken == token,
                  listeningCleanupCompletedSuccessfully {
            cleanupTask = Task.detached { true }
        } else {
            if listeningCleanupCompletedToken == token {
                listeningCleanupCompletedToken = nil
                listeningCleanupCompletedSuccessfully = false
            }
            let child = transcriptTask
            transcriptTask = nil
            child?.cancel()
            let input = self.input
            cleanupTask = Task.detached {
                if cancelInput { await input.cancel() }
                if joinTranscriptTask, let child { _ = await child.value }
                return await input.resourcesAreReleased()
            }
            listeningCleanupTask = cleanupTask
            listeningCleanupToken = token
        }

        guard let resourcesReleased = await Self.boundedValue(cleanupTask, timeout: cleanupTimeout) else {
            cleanupTimedOutTokens.insert(token)
            if !listeningTerminalEmitted {
                emit(.failure(Self.cleanupTimeoutFailure), token: token, allowInvalidated: true)
                emit(.listeningFinished(.failed(Self.cleanupTimeoutFailure)), token: token, allowInvalidated: true)
                let outcome = RecognitionOutcome.failed(
                    Self.failure(from: Self.cleanupTimeoutFailure)
                )
                emitRecognition(
                    .outcome(outcome),
                    token: token,
                    allowInvalidated: true
                )
                stageRecognitionDiagnosticTerminal(outcome, token: token)
                listeningTerminalEmitted = true
                lastFinalTranscript = nil
                stableTranscriptPublisher = nil
            }
            transition(to: .failed, token: token, allowInvalidated: true)
            emitRecognitionDiagnosticTerminalIfNeeded(token: token)
            return ListeningUnwindResult(
                resourcesReleased: false,
                terminalError: Self.cleanupTimeoutFailure
            )
        }

        listeningCleanupTask = nil
        listeningCleanupToken = nil
        listeningCleanupCompletedToken = token
        listeningCleanupCompletedSuccessfully = resourcesReleased

        let unresolvedCleanupError = cleanupTimedOutTokens.contains(token)
            ? Self.cleanupTimeoutFailure
            : Self.cleanupFailure
        var finalReason: VoiceTerminationReason = resourcesReleased && finalizationCompleted
            ? reason
            : .failed(unresolvedCleanupError)
        var terminalError: VoiceError?
        if resourcesReleased, finalizationCompleted, let authoritativeFinalText {
            // This is intentionally emitted after the transcript task has
            // been cancelled and joined. The provider's stop result is the
            // authoritative final snapshot, so no late stream callback can
            // appear after it. Exact duplicates remain suppressed.
            do {
                if var publisher = stableTranscriptPublisher {
                    let chunks = try publisher.finalize(text: authoritativeFinalText)
                    stableTranscriptPublisher = publisher
                    emitStableChunks(chunks, token: token, allowInvalidated: true)
                }
                emitTranscript(
                    TranscriptUpdate(text: authoritativeFinalText, isFinal: true),
                    token: token,
                    allowInvalidated: true
                )
                if let session = recognitionSession, session.token == token {
                    emitRecognition(
                        .transcript(.finalTranscript(FinalTranscript(
                            sessionID: session.id,
                            text: authoritativeFinalText
                        ))),
                        token: token,
                        allowInvalidated: true
                    )
                }
            } catch {
                terminalError = .transcriptConsistency
                finalReason = .failed(.transcriptConsistency)
            }
        }
        if !listeningTerminalEmitted {
            if case .failed(let error) = finalReason,
               (emitFailure || terminalError != nil || !resourcesReleased || !finalizationCompleted) {
                emit(.failure(error), token: token, allowInvalidated: true)
            }
            emit(.listeningFinished(finalReason), token: token, allowInvalidated: true)
            let outcome = Self.recognitionOutcome(from: finalReason)
            emitRecognition(
                .outcome(outcome),
                token: token,
                allowInvalidated: true
            )
            stageRecognitionDiagnosticTerminal(outcome, token: token)
            listeningTerminalEmitted = true
        }
        recordTerminalRecognitionOutcome(
            token: token,
            reason: finalReason,
            authoritativeFinalText: authoritativeFinalText,
            terminalError: terminalError
        )
        // No provider callback for this invalidated generation may publish
        // another final snapshot, so release the last full transcript as soon
        // as its terminal event has been emitted.
        lastFinalTranscript = nil
        stableTranscriptPublisher = nil
        if case .failed = finalReason {
            transition(to: .failed, token: token, allowInvalidated: true)
        }
        guard resourcesReleased && finalizationCompleted else {
            transition(to: .failed, token: token, allowInvalidated: true)
            emitRecognitionDiagnosticTerminalIfNeeded(token: token)
            return ListeningUnwindResult(
                resourcesReleased: false,
                terminalError: terminalError
            )
        }

        if activeStartupID == token {
            transition(to: .failed, token: token, allowInvalidated: true)
            return ListeningUnwindResult(
                resourcesReleased: true,
                terminalError: terminalError
            )
        }
        finalizeListeningIfReady(token)
        return ListeningUnwindResult(
            resourcesReleased: true,
            terminalError: terminalError
        )
    }

    private func handleUnexpectedInputEnd(token: OperationToken) async {
        guard isCurrent(token), state == .listening else { return }
        await handleListeningFailure(
            VoiceError.underlying("Speech input ended before finalization."),
            token: token
        )
    }

    private func handleListeningFailure(_ error: Error, token: OperationToken) async {
        guard isCurrent(token) else { return }
        _ = await unwindListening(
            token: token,
            reason: terminationReason(for: error),
            cancelInput: true,
            emitFailure: true,
            joinTranscriptTask: false
        )
    }

    private func acceptTranscript(_ update: TranscriptUpdate, token: OperationToken) async {
        guard isCurrent(token) else { return }
        guard update.text.utf16.count <= VoiceTextLimits.maximumUTF16Length else {
            await handleListeningFailure(
                VoiceError.textTooLong(maximumUTF16Length: VoiceTextLimits.maximumUTF16Length),
                token: token
            )
            return
        }
        if update.isFinal, lastFinalTranscript == update.text {
            return
        }

        var stableChunks: [StableTranscriptChunk] = []
        if var publisher = stableTranscriptPublisher {
            do {
                stableChunks = try publisher.observe(
                    text: update.text,
                    at: stableTranscriptClock.now
                )
                stableTranscriptPublisher = publisher
            } catch {
                await handleListeningFailure(VoiceError.transcriptConsistency, token: token)
                return
            }
        }
        if update.isFinal { lastFinalTranscript = update.text }
        emitRecognitionPreview(update.text, token: token)
        emitStableChunks(stableChunks, token: token)
        scheduleStableChunkTimer(token: token)
        emit(.transcript(update), token: token)
    }

    private func emitTranscript(
        _ update: TranscriptUpdate,
        token: OperationToken,
        allowInvalidated: Bool = false
    ) {
        guard isOwned(token), allowInvalidated || isCurrent(token) else { return }
        if update.isFinal, lastFinalTranscript == update.text {
            return
        }
        if update.isFinal { lastFinalTranscript = update.text }
        emit(.transcript(update), token: token, allowInvalidated: allowInvalidated)
    }

    private func finalizeListeningIfReady(_ token: OperationToken) {
        guard isOwned(token), activeStartupID != token,
              finalizationTask == nil,
              listeningCleanupCompletedToken == token,
              listeningCleanupCompletedSuccessfully else { return }
        if state != .idle {
            transition(to: .idle, token: token, allowInvalidated: true)
        }
        operation = nil
        lastFinalTranscript = nil
        emitRecognitionDiagnosticTerminalIfNeeded(token: token)
        if recognitionSession?.token == token {
            recognitionSession = nil
        }
        cancelStableChunkTimer(token: token)
        cancelRecognitionDurationLimit(token: token)
        stableTranscriptPublisher = nil
        invalidatedTokens.remove(token)
        listeningCleanupCompletedToken = nil
        listeningCleanupCompletedSuccessfully = false
        cleanupTimedOutTokens.remove(token)
        startQueuedPlaybackIfNeeded()
    }

    private func recordTerminalRecognitionOutcome(
        token: OperationToken,
        reason: VoiceTerminationReason,
        authoritativeFinalText: String?,
        terminalError: VoiceError?
    ) {
        guard let session = recognitionSession, session.token == token else { return }
        if let terminalError {
            storeTerminalRecognitionOutcome(.failure(terminalError), for: session.id)
            return
        }
        switch reason {
        case .completed:
            guard let authoritativeFinalText else {
                storeTerminalRecognitionOutcome(.failure(.cancelled), for: session.id)
                return
            }
            storeTerminalRecognitionOutcome(.success(FinalTranscript(
                sessionID: session.id,
                text: authoritativeFinalText
            )), for: session.id)
        case .durationLimitReached:
            guard let authoritativeFinalText else {
                storeTerminalRecognitionOutcome(.failure(.cancelled), for: session.id)
                return
            }
            storeTerminalRecognitionOutcome(.success(FinalTranscript(
                sessionID: session.id,
                text: authoritativeFinalText
            )), for: session.id)
        case .cancelled:
            storeTerminalRecognitionOutcome(.failure(.cancelled), for: session.id)
        case .interrupted(let interruption):
            storeTerminalRecognitionOutcome(.failure(
                .interrupted(String(describing: interruption))
            ), for: session.id)
        case .failed(let error):
            storeTerminalRecognitionOutcome(.failure(error), for: session.id)
        }
    }

    private func storeTerminalRecognitionOutcome(
        _ outcome: Result<FinalTranscript, VoiceError>,
        for id: RecognitionSessionID
    ) {
        terminalRecognitionOutcomes[id] = outcome
        terminalRecognitionOutcomeOrder.removeAll { $0 == id }
        terminalRecognitionOutcomeOrder.append(id)
        while terminalRecognitionOutcomeOrder.count > 16 {
            let evicted = terminalRecognitionOutcomeOrder.removeFirst()
            terminalRecognitionOutcomes.removeValue(forKey: evicted)
        }
    }

    private func clearSpeakingOperation(_ token: OperationToken) {
        guard isOwned(token) else { return }
        operation = nil
        invalidatedTokens.remove(token)
        speakingTerminalEmitted = false
    }

    private func transition(
        to newState: VoiceState,
        token: OperationToken? = nil,
        allowInvalidated: Bool = false
    ) {
        if let token {
            guard isOwned(token), allowInvalidated || isCurrent(token) else { return }
        }
        guard state != newState else { return }
        state = newState
        emit(.stateChanged(newState), token: token, allowInvalidated: allowInvalidated)
        if let token, let recognitionState = Self.recognitionState(from: newState) {
            emitRecognition(
                .stateChanged(recognitionState),
                token: token,
                allowInvalidated: allowInvalidated
            )
        }
    }

    private func emit(
        _ event: VoiceEvent,
        token: OperationToken? = nil,
        allowInvalidated: Bool = false
    ) {
        if let token {
            guard isOwned(token), allowInvalidated || isCurrent(token) else { return }
        }
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func normalize(_ error: Error) -> VoiceError {
        if error is CancellationError { return .cancelled }
        return error as? VoiceError ?? .underlying("Voice operation failed.")
    }

    private func normalizedCancellation(_ error: Error) -> Error {
        error is CancellationError ? VoiceError.cancelled : error
    }

    private func terminationReason(for error: Error) -> VoiceTerminationReason {
        if let interruption = error as? VoiceLifecycleInterruption {
            return .interrupted(interruption.reason)
        }
        switch normalize(error) {
        case .interrupted:
            return .interrupted(.systemInterruption)
        case .cancelled:
            return .cancelled
        default:
            return .failed(normalize(error))
        }
    }

    private func cleanupError(for token: OperationToken) -> VoiceError {
        cleanupTimedOutTokens.contains(token) ? Self.cleanupTimeoutFailure : Self.cleanupFailure
    }

    private func isOwned(_ token: OperationToken) -> Bool {
        switch operation {
        case .listening(let current): return current == token
        case .speaking(let current, _): return current == token
        case nil: return false
        }
    }

    private func isCurrent(_ token: OperationToken) -> Bool {
        isOwned(token) && !invalidatedTokens.contains(token)
    }

    private func completeStartup(_ token: OperationToken) {
        guard activeStartupID == token else { return }
        activeStartupID = nil
        startupTask = nil
        startupCancellation = nil
        finalizeListeningIfReady(token)
    }

    private func retainStartupUntilCompletion(
        _ task: Task<Void, Error>,
        token: OperationToken
    ) {
        Task.detached { [weak self] in
            _ = try? await task.value
            await self?.completeStartup(token)
        }
    }

    private func waitForStartupCompletion(_ token: OperationToken) async -> Bool {
        guard activeStartupID == token else { return true }

        // Polling at a coarse bounded cadence avoids retaining a continuation
        // forever when a provider ignores cancellation. The actor is yielded
        // during each sleep, so a cooperative startup can still clear the
        // marker and finish normally.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: cleanupTimeout)
        while activeStartupID == token {
            guard clock.now < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return true
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
        eventContinuationOrder.removeAll { $0 == id }
    }

    private func removeRecognitionEventContinuation(_ id: UUID) {
        recognitionEventDelivery.removeSubscription(id: id)
    }

    private func removeCanonicalEventContinuation(_ id: UUID) {
        canonicalEventDelivery.removeSubscription(id)
    }

    private func emitRecognitionPreview(_ text: String, token: OperationToken) {
        guard var session = recognitionSession, session.token == token else { return }
        switch session.publicationPolicy {
        case .finalOnly:
            return
        case .previewAndFinal, .stableChunks:
            let preview = TranscriptPreview(
                sessionID: session.id,
                revision: session.nextPreviewRevision,
                text: text
            )
            session.nextPreviewRevision &+= 1
            session.latestPreview = preview
            recognitionSession = session
            emitRecognition(.transcript(.preview(preview)), token: token)
        }
    }

    private func emitStableChunks(
        _ chunks: [StableTranscriptChunk],
        token: OperationToken,
        allowInvalidated: Bool = false
    ) {
        for chunk in chunks {
            emitRecognition(
                .transcript(.stableChunk(chunk)),
                token: token,
                allowInvalidated: allowInvalidated
            )
        }
    }

    private func scheduleStableChunkTimer(token: OperationToken) {
        stableChunkTimerTask?.cancel()
        stableChunkTimerTask = nil
        stableChunkTimerToken = nil

        guard isCurrent(token),
              stableTranscriptPublisher != nil else {
            return
        }

        let clock = stableTranscriptClock
        stableChunkTimerToken = token
        stableChunkTimerTask = Task { [weak self] in
            do {
                guard let self else { return }
                guard let delay = await self.stableChunkDelay(for: token, at: clock.now) else {
                    return
                }
                if delay > .zero {
                    try await clock.sleep(for: delay)
                } else {
                    await Task.yield()
                }
                try Task.checkCancellation()
                await self.stableChunkTimerFired(token: token)
            } catch {
                // Cancellation means the snapshot changed or the session
                // reached a terminal boundary.
            }
        }
    }

    private func stableChunkDelay(for token: OperationToken, at now: Duration) -> Duration? {
        guard isCurrent(token), let publisher = stableTranscriptPublisher else { return nil }
        return publisher.nextMaturityDelay(at: now)
    }

    private func stableChunkTimerFired(token: OperationToken) async {
        guard stableChunkTimerToken == token, isCurrent(token),
              var publisher = stableTranscriptPublisher else { return }
        stableChunkTimerTask = nil
        stableChunkTimerToken = nil

        do {
            let chunks = try publisher.drainMaturedChunks(at: stableTranscriptClock.now)
            stableTranscriptPublisher = publisher
            emitStableChunks(chunks, token: token)
            scheduleStableChunkTimer(token: token)
        } catch {
            await handleListeningFailure(VoiceError.transcriptConsistency, token: token)
        }
    }

    private func cancelStableChunkTimer(token: OperationToken) {
        guard stableChunkTimerToken == nil || stableChunkTimerToken == token else { return }
        stableChunkTimerTask?.cancel()
        stableChunkTimerTask = nil
        stableChunkTimerToken = nil
    }

    private func scheduleRecognitionDurationLimit(token: OperationToken) {
        recognitionDurationTask?.cancel()
        recognitionDurationTask = nil
        recognitionDurationToken = nil
        guard let session = recognitionSession, session.token == token,
              let duration = session.maximumRecognitionDuration else { return }
        recognitionDurationToken = token
        recognitionDurationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            await self?.recognitionDurationExpired(token: token)
        }
    }

    private func cancelRecognitionDurationLimit(token: OperationToken) {
        guard recognitionDurationToken == nil || recognitionDurationToken == token else { return }
        recognitionDurationTask?.cancel()
        recognitionDurationTask = nil
        recognitionDurationToken = nil
    }

    private func recognitionDurationExpired(token: OperationToken) async {
        guard isCurrent(token), state == .listening else { return }
        _ = try? await endListening(completionReason: .durationLimitReached)
    }

    private func emitRecognition(
        _ kind: RecognitionEventKind,
        token: OperationToken,
        allowInvalidated: Bool = false
    ) {
        guard isOwned(token), allowInvalidated || isCurrent(token),
              var session = recognitionSession, session.token == token else { return }
        let event = RecognitionEvent(
            sessionID: session.id,
            eventOrdinal: session.nextEventOrdinal,
            kind: kind
        )
        session.nextEventOrdinal &+= 1
        recognitionSession = session

        recognitionEventDelivery.publish(event)
        publishCanonical(.recognition(event))
    }

    private func emitRecognitionDiagnosticStarted(token: OperationToken) {
        guard let session = recognitionSession,
              session.token == token,
              let diagnostic = session.diagnostic else { return }
        diagnostic.continuation.yield(RecognitionSessionDiagnosticEmission(
            sessionID: session.id,
            phase: .started,
            state: state,
            errorCategory: nil,
            durationNanoseconds: Self.elapsed(since: diagnostic.startedAtNanoseconds)
        ))
    }

    private func stageRecognitionDiagnosticTerminal(
        _ outcome: RecognitionOutcome,
        token: OperationToken
    ) {
        guard var session = recognitionSession,
              session.token == token,
              var diagnostic = session.diagnostic,
              diagnostic.terminal == nil,
              !diagnostic.terminalEmitted else { return }
        diagnostic.terminal = Self.diagnosticTerminal(from: outcome)
        session.diagnostic = diagnostic
        recognitionSession = session
    }

    private func emitRecognitionDiagnosticTerminalIfNeeded(token: OperationToken) {
        guard var session = recognitionSession,
              session.token == token,
              var diagnostic = session.diagnostic,
              let terminal = diagnostic.terminal,
              !diagnostic.terminalEmitted else { return }
        diagnostic.terminalEmitted = true
        session.diagnostic = diagnostic
        recognitionSession = session
        diagnostic.continuation.yield(RecognitionSessionDiagnosticEmission(
            sessionID: session.id,
            phase: terminal.phase,
            state: state,
            errorCategory: terminal.errorCategory,
            durationNanoseconds: Self.elapsed(since: diagnostic.startedAtNanoseconds)
        ))
        diagnostic.continuation.finish()
    }

    private static func diagnosticTerminal(
        from outcome: RecognitionOutcome
    ) -> RecognitionSessionDiagnosticTerminal {
        switch outcome {
        case .completed, .durationLimitReached:
            return RecognitionSessionDiagnosticTerminal(
                phase: .completed,
                errorCategory: nil
            )
        case .cancelled:
            return RecognitionSessionDiagnosticTerminal(
                phase: .cancelled,
                errorCategory: .cancelled
            )
        case .interrupted:
            return RecognitionSessionDiagnosticTerminal(
                phase: .failed,
                errorCategory: .interrupted
            )
        case .failed(let failure):
            return RecognitionSessionDiagnosticTerminal(
                phase: .failed,
                errorCategory: failure.category
            )
        }
    }

    private static var monotonicNanoseconds: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func elapsed(since start: UInt64) -> UInt64 {
        let now = monotonicNanoseconds
        return now >= start ? now - start : 0
    }

    private func publishSpeechQueueEvents(resolveResults: Bool = true) async {
        let events = await speechQueue.drainEvents()
        for event in events {
            publishCanonical(.speechQueue(event))
        }
        if resolveResults {
            let results = await speechQueue.drainResults()
            for result in results {
                resolveSpeechPlayback(
                    result,
                    error: pendingSpeechPlaybackErrors.removeValue(forKey: result.playbackID)
                )
            }
        }
    }

    private func publishPlaybackProgress(
        itemID: SpeechItemID,
        playbackID: SpeechPlaybackID,
        range: Range<Int>
    ) {
        guard knownSpeechPlaybackIDs.contains(playbackID),
              range.lowerBound >= 0,
              range.upperBound >= range.lowerBound else { return }
        publishCanonical(.speechProgress(SpeechPlaybackProgress(
            itemID: itemID,
            playbackID: playbackID,
            utf16Range: range
        )))
    }

    private func emitRecovery(_ kind: VoiceRecoveryEventKind) {
        recoveryState = kind.recoveryState
        let event = nextRecoveryEvent(for: recoveryState)
        publishCanonical(.recovery(event))
    }

    private func publishCanonical(_ event: VoiceEventStreamEvent) {
        runtimeSnapshotGeneration &+= 1
        canonicalEventDelivery.publish(event)
    }

    private func nextRecoveryEvent(for state: VoiceRecoveryState) -> VoiceRecoveryEvent {
        let event = VoiceRecoveryEvent(
            eventOrdinal: nextRecoveryEventOrdinal,
            kind: VoiceRecoveryEventKind(recoveryState: state)
        )
        nextRecoveryEventOrdinal = nextRecoveryEventOrdinal == .max
            ? 0
            : nextRecoveryEventOrdinal + 1
        return event
    }

    private func acquireQueueLeaseIfNeeded() throws -> Bool {
        guard !ownsRuntimeLease else { return false }
        _ = try runtimeLease.acquire(for: runtimeOwnerID)
        ownsRuntimeLease = true
        return true
    }

    private func releaseQueueLeaseIfUnused(_ acquired: Bool) {
        guard acquired else { return }
        runtimeLease.release(for: runtimeOwnerID)
        ownsRuntimeLease = false
    }

    private func startQueuedPlaybackIfNeeded() {
        guard speechQueueTask == nil, operation == nil, state == .idle, !closeInFlight else { return }
        let workerID = UUID()
        speechQueueWorkerID = workerID
        speechQueueTask = Task { [weak self] in
            guard let self else { return }
            await self.runNextQueuedPlayback(workerID: workerID)
        }
    }

    private func runNextQueuedPlayback(workerID: UUID) async {
        defer {
            if speechQueueWorkerID == workerID {
                speechQueueTask = nil
                speechQueueWorkerID = nil
            }
        }
        guard let attempt = await speechQueue.nextAttempt() else { return }
        await publishSpeechQueueEvents()
        guard await speechQueue.isCurrent(attempt.playbackID) else {
            if await speechQueue.pendingCount() > 0 {
                if speechQueueWorkerID == workerID {
                    speechQueueTask = nil
                    speechQueueWorkerID = nil
                }
                startQueuedPlaybackIfNeeded()
            }
            return
        }
        var workerToken: OperationToken?
        do {
            let token = try await reserveAfterResourceAdmission(.speaking(.queued))
            workerToken = token
            guard await speechQueue.isCurrent(attempt.playbackID) else {
                speakingTerminalEmitted = true
                _ = await stopSpeakingOperation(token)
                return
            }
            speakingTerminalEmitted = false
            transition(to: .speaking, token: token)
            emit(.speechStarted, token: token)
            try await withTaskCancellationHandler(operation: {
                await output.setProgressHandler { [weak self] range in
                    await self?.publishPlaybackProgress(
                        itemID: attempt.item.id,
                        playbackID: attempt.playbackID,
                        range: range
                    )
                }
                try await output.speak(
                    attempt.item.text,
                    configuration: attempt.item.configuration,
                    lifecyclePolicy: defaultLifecyclePolicy
                )
                await output.setProgressHandler(nil)
            }, onCancel: { [weak self] in
                Task { await self?.cancelSpeaking(for: token) }
            })
            try Task.checkCancellation()
            guard isCurrent(token) else { throw VoiceError.cancelled }
            guard await output.resourcesAreReleased() else {
                throw Self.speechResourceFailure
            }
            let outcome: SpeechPlaybackOutcome = .finished
            _ = await speechQueue.finish(playbackID: attempt.playbackID, outcome: outcome)
            await publishSpeechQueueEvents(resolveResults: false)
            speakingTerminalEmitted = true
            emit(.speechFinished, token: token)
            transition(to: .idle, token: token, allowInvalidated: true)
            clearSpeakingOperation(token)
            await publishSpeechQueueEvents()
        } catch {
            await output.setProgressHandler(nil)
            let outcome: SpeechPlaybackOutcome
            let normalized = normalize(error)
            let lifecycleInterruption = error as? VoiceLifecycleInterruption
            let interrupted: Bool = {
                if lifecycleInterruption != nil { return true }
                switch normalized {
                case .interrupted, .audioRouteUnavailable: return true
                default: return false
                }
            }()
            let supersededByRecognition = queuedPlaybackSupersededByRecognition.remove(attempt.playbackID) != nil
            if supersededByRecognition {
                outcome = .cancelled(.supersededByRecognition)
            } else if normalized == .cancelled {
                outcome = .cancelled(.stopped)
            } else if interrupted {
                outcome = .interrupted(lifecycleInterruption?.reason ?? .systemInterruption)
            } else {
                outcome = .failed(Self.failure(from: normalized))
            }
            // Expected stop/supersession/interruption paths expose their
            // typed playback outcome. Only a genuine provider failure makes
            // an observer's result wait throw the underlying error.
            if !supersededByRecognition, normalized != .cancelled, !interrupted {
                pendingSpeechPlaybackErrors[attempt.playbackID] = error
            }
            if normalized != .cancelled, !interrupted,
               case .speaking(let speakingToken, .queued) = operation,
               speakingToken == workerToken {
                speakingTerminalEmitted = true
                emit(.failure(normalized), token: speakingToken, allowInvalidated: true)
                transition(to: .failed, token: speakingToken, allowInvalidated: true)
            }
            // Any provider/lifecycle error stops ordered advancement. The
            // accepted pending attempts remain available for an explicit
            // resume after the host has handled the failure.
            _ = await speechQueue.suspend()
            _ = await speechQueue.finish(playbackID: attempt.playbackID, outcome: outcome)
            await publishSpeechQueueEvents(resolveResults: false)
            if case .speaking(let speakingToken, .queued) = operation,
               speakingToken == workerToken {
                _ = await stopSpeaking()
            }
            await publishSpeechQueueEvents()
        }
        if await speechQueue.pendingCount() > 0,
           await speechQueue.isRunning(),
           operation == nil, state == .idle, !closeInFlight {
            if speechQueueWorkerID == workerID {
                speechQueueTask = nil
                speechQueueWorkerID = nil
            }
            startQueuedPlaybackIfNeeded()
        }
    }

    private var currentListeningToken: OperationToken? {
        guard case .listening(let token) = operation else { return nil }
        return token
    }

    private static func recognitionState(from state: VoiceState) -> RecognitionSessionState? {
        switch state {
        case .preparing: .preparing
        case .listening: .listening
        case .finalizing: .finalizing
        case .idle, .speaking, .failed: nil
        }
    }

    private static func permissionStatus(from authorization: SpeechAuthorization) -> VoicePermissionStatus {
        switch authorization {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        }
    }

    private static func recognitionOutcome(
        from reason: VoiceTerminationReason
    ) -> RecognitionOutcome {
        switch reason {
        case .completed:
            .completed
        case .durationLimitReached:
            .durationLimitReached
        case .cancelled:
            .cancelled
        case .interrupted(let reason):
            .interrupted(reason)
        case .failed(let error):
            .failed(failure(from: error))
        }
    }

    private static func validateRecognitionDuration(_ duration: Duration?) throws {
        guard let duration else { return }
        guard duration >= RecognitionSessionConfiguration.minimumMaximumRecognitionDuration,
              duration <= RecognitionSessionConfiguration.maximumMaximumRecognitionDuration else {
            throw VoiceError.invalidRecognitionConfiguration(
                "Maximum recognition duration must be between 1 and 600 seconds, or nil."
            )
        }
    }

    private static func failure(from error: VoiceError) -> VoiceFailure {
        VoiceFailure(
            category: error.category,
            recommendedAction: error.recommendedRecoveryAction
        )
    }

    private func markUnresolvedOutputFailure() {
        if !unresolvedOutputFailureEmitted {
            emit(.failure(Self.speechResourceFailure))
            unresolvedOutputFailureEmitted = true
        }
        transition(to: .failed)
    }

    private static let cleanupFailure = VoiceError.audioSessionUnavailable(
        "The microphone cleanup is still in progress; retry close() before starting another turn."
    )
    private static let cleanupTimeoutFailure = VoiceError.audioSessionUnavailable(
        "The microphone cleanup did not complete before the recovery deadline."
    )
    private static let speechCleanupFailure = VoiceError.speechSynthesisUnavailable(
        "Speech cleanup did not complete before the recovery deadline."
    )
    private static let speechResourceFailure = VoiceError.speechSynthesisUnavailable(
        "Speech audio resources were not released; retry close() before starting another turn."
    )

    private static func boundedValue<Value: Sendable>(
        _ task: Task<Value, Never>,
        timeout: Duration
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            BoundedTaskRace(task: task, timeout: timeout).start(continuation)
        }
    }

    private static func awaitProviderStartup(
        _ task: Task<Void, Error>,
        cancellation: CancellationSignal
    ) async throws {
        try Task.checkCancellation()
        try await ProviderStartupRace(provider: task, cancellation: cancellation).wait()
    }
}

/// A cancellation-aware one-shot signal used to bound observation of an
/// unstructured provider startup task without dropping ownership of the task.
private final class CancellationSignal: @unchecked Sendable {
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
private final class ProviderStartupRace: @unchecked Sendable {
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
private final class BoundedTaskRace<Value: Sendable>: @unchecked Sendable {
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
