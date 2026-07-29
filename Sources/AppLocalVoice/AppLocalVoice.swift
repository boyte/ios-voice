import Foundation
import AVFAudio

/// The default Apple-native local speech layer for iPhone and iPad applications.
///
/// `AppLocalVoice` owns one serialized speech lifecycle. It converts microphone
/// input to transcript snapshots and text to spoken audio; it does not own a
/// chat client, endpoint, conversation, persistence layer, or user interface.
/// The default implementation uses Apple's on-device speech APIs and has no
/// runtime network dependency.
///
/// A recognition turn has two explicit calls so the host controls the end of
/// user speech:
///
/// ```swift
/// let voice = AppLocalVoice()
/// do {
///     try await voice.startListening()
///     let text = try await voice.finishListening()
///     try await voice.speak(text)
///     await voice.close()
/// } catch {
///     await voice.close()
///     throw error
/// }
/// ```
///
/// The package deliberately does not provide a `transcribe()` method that
/// starts and ends a turn by itself. There is no reliable, platform-neutral
/// definition of “the user has finished speaking”; automatic silence
/// detection would make lifecycle behavior less deterministic. Apps that have
/// their own push-to-talk, turn detector, or endpoint policy should call
/// `startListening(configuration:)` and `finishListening()` explicitly.
@MainActor
public final class AppLocalVoice {
    private static let maximumDiagnosticSubscribers = 8
    private static let diagnosticBufferCapacity = 32
    private let coordinator: VoiceCoordinator
    private let diagnosticsSink: VoiceDiagnosticsSink?
    private var diagnosticContinuations: [UUID: AsyncStream<VoiceDiagnostic>.Continuation] = [:]
    private var diagnosticContinuationOrder: [UUID] = []

    deinit {
        // `close()` is the authoritative, observable lifecycle boundary, but
        // a discarded active facade must not permanently strand the
        // process-wide runtime lease. Retain the coordinator only long enough
        // to execute its existing bounded cleanup/reconciliation path; that
        // path releases the lease solely after input/output resources prove
        // released, and otherwise preserves the typed blocked barrier.
        let coordinator = coordinator
        Task { _ = await coordinator.closeAndReport() }
    }
    private var listeningDiagnostic: (id: UUID, start: UInt64)?
    private var listeningStartID: UUID?
    private var listeningStartCancellationRequested = false
    private var speakingDiagnostic: (id: UUID, start: UInt64)?
    private var lifecycleEpoch: UInt64 = 0

    /// Creates a voice service with Apple's local speech providers.
    ///
    /// Pass a diagnostics sink only when the host explicitly wants to retain
    /// privacy-safe lifecycle metadata. The library never logs or persists
    /// diagnostics, and each record excludes transcript and speech text.
    ///
    /// The package keeps provider construction and test seams internal so the
    /// normal application surface remains one small service type.
    public init(
        queueConfiguration: SpeechQueueConfiguration = .init(),
        lifecyclePolicy: AudioLifecyclePolicy = .init(),
        diagnostics: VoiceDiagnosticsSink? = nil
    ) {
        let audioSession = AudioSessionController()
        self.diagnosticsSink = diagnostics
        coordinator = VoiceCoordinator(
            input: AppleSpeechInput(audioSession: audioSession),
            output: AppleSpeechOutput(audioSession: audioSession),
            runtimeLease: .shared,
            eventSubscriberRegistry: .shared,
            queueConfiguration: queueConfiguration,
            lifecyclePolicy: lifecyclePolicy
        )
    }

    init(
        input: (any SpeechInput)? = nil,
        output: (any SpeechOutput)? = nil,
        diagnostics: VoiceDiagnosticsSink? = nil,
        runtimeLease: ProcessVoiceRuntimeLease = ProcessVoiceRuntimeLease(),
        eventSubscriberRegistry: CanonicalEventSubscriberRegistry =
            CanonicalEventSubscriberRegistry(),
        stableTranscriptClock: any StableTranscriptClock = ContinuousStableTranscriptClock(),
        queueConfiguration: SpeechQueueConfiguration = .init(),
        lifecyclePolicy: AudioLifecyclePolicy = .init()
    ) {
        let audioSession = AudioSessionController()
        self.diagnosticsSink = diagnostics
        coordinator = VoiceCoordinator(
            input: input ?? AppleSpeechInput(audioSession: audioSession),
            output: output ?? AppleSpeechOutput(audioSession: audioSession),
            runtimeLease: runtimeLease,
            eventSubscriberRegistry: eventSubscriberRegistry,
            stableTranscriptClock: stableTranscriptClock,
            queueConfiguration: queueConfiguration,
            lifecyclePolicy: lifecyclePolicy
        )
    }

    /// Returns a stream of transcript, state, speech, and failure events.
    ///
    /// Subscribe before starting a turn. The stream remains valid until the
    /// consumer cancels iteration. Hosts must cancel stream iteration before
    /// releasing the service; deallocation is not an asynchronous lifecycle
    /// cleanup guarantee.
    /// Events are snapshots and are delivered by the serialized lifecycle;
    /// they do not contain audio or network data. A provider may mark a
    /// transcript snapshot final before the host calls `finishListening()`;
    /// the listening terminal event and returned string remain authoritative
    /// for the end of the turn. The stream has a bounded newest-value buffer:
    /// a stalled consumer may miss intermediate transcript snapshots, while
    /// the final snapshot and terminal lifecycle events are retained by the
    /// documented buffer contract. At most eight event subscriptions are
    /// retained; creating another subscription finishes the oldest one.
    public func events() async -> AsyncStream<VoiceEvent> { await coordinator.events() }

    /// Returns the additive recognition-session event stream.
    ///
    /// Every admitted session begins with `.accepted` at ordinal zero. The
    /// ninth process-wide observer fails with
    /// `VoiceError.eventSubscriberLimitReached(maximum:active:)`. An admitted
    /// stream that falls behind its 32-event durable buffer terminates with
    /// `VoiceError.eventDeliveryOverflow(capacity:firstUndelivered:)`. Preview
    /// and state snapshots use separate coalesced slots.
    public func recognitionEvents() async -> AsyncThrowingStream<RecognitionEvent, Error> {
        await coordinator.recognitionEvents()
    }

    /// Returns the canonical backend-agnostic stream for recognition, speech
    /// queue/playback, and process recovery events. The legacy `events()` and
    /// additive `recognitionEvents()` projections remain available.
    public func voiceEvents() async -> VoiceEventStream {
        await coordinator.voiceEvents()
    }

    /// The coordinator's authoritative process recovery snapshot. This is
    /// independent from operation state: `.failed` may still be recoverable,
    /// while `.blocked` means cleanup must be retried before new audio work.
    public var recoveryState: VoiceRecoveryState {
        get async { await coordinator.recoveryState }
    }

    /// Returns finite current voice state for UI reconciliation after an event gap.
    public func runtimeSnapshot() async -> VoiceRuntimeSnapshot {
        await coordinator.runtimeSnapshot()
    }

    /// Reports whether the requested locale can use Apple's on-device recognizer.
    public func capabilities(for locale: Locale = .current) async -> SpeechCapabilities {
        await coordinator.capabilities(for: locale)
    }

    /// Returns the side-effect-free readiness snapshot for a locale.
    ///
    /// This method never prompts for permission, installs a recognition
    /// model, starts audio, or acquires the process runtime lease. Its values
    /// are a point-in-time preflight only; a later start can still fail if the
    /// device, permission, route, or installed assets change.
    public func capabilitySnapshot(for locale: Locale = .current) async -> VoiceCapabilitySnapshot {
        await coordinator.capabilitySnapshot(for: locale)
    }

    /// Requests recognition permissions and optionally installs a missing local model.
    ///
    /// This intentionally does not create a session, acquire the process
    /// runtime, configure an audio session, or open microphone capture.
    public func prepareRecognition(
        for locale: Locale = .current,
        policy: SpeechModelPolicy = .installedModelsOnly,
        progress: RecognitionPreparationProgressHandler? = nil
    ) async throws -> RecognitionPreparationResult {
        try await coordinator.prepareRecognition(
            for: locale,
            policy: policy,
            progress: progress
        )
    }

    /// Returns a bounded, privacy-safe diagnostic stream.
    ///
    /// Diagnostics are always opt-in at the consumer boundary: simply never
    /// call this method if the host does not need them. The oldest active
    /// diagnostic stream is finished when eight subscriptions are retained.
    /// This stream is advisory and must not be used to drive application state.
    public func diagnostics() -> VoiceDiagnosticsStream {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(Self.diagnosticBufferCapacity)) { continuation in
            if diagnosticContinuations.count >= Self.maximumDiagnosticSubscribers,
               let oldest = diagnosticContinuationOrder.first {
                diagnosticContinuationOrder.removeFirst()
                diagnosticContinuations.removeValue(forKey: oldest)?.finish()
            }
            diagnosticContinuations[id] = continuation
            diagnosticContinuationOrder.append(id)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.removeDiagnosticContinuation(id) }
            }
        }
    }

    /// Lists the Apple voices currently available for the requested locale.
    ///
    /// Voice availability is device- and OS-dependent. The returned `id` is
    /// the value accepted by `SpeechConfiguration.voiceIdentifier`.
    public func availableVoices(for locale: Locale = .current) async -> [SpeechVoice] {
        await coordinator.availableVoices(for: locale)
    }

    /// Requests permission and starts a new microphone recognition turn.
    ///
    /// The operation remains active until `finishListening()`,
    /// `cancelListening()`, interruption, or failure. Starting another
    /// operation before the current one reaches a terminal state throws
    /// `VoiceError.invalidState`.
    public func startListening(configuration: RecognitionConfiguration = .init()) async throws {
        // Reserve the facade's startup slot before the first await. The
        // coordinator remains the lifecycle authority, but this synchronous
        // guard ensures a second main-actor caller cannot win the diagnostic
        // race while the first provider startup is still suspended.
        guard listeningStartID == nil else {
            throw VoiceError.invalidState("A voice operation is already active.")
        }
        let operationID = UUID()
        let start = Self.monotonicNanoseconds
        let operationEpoch = lifecycleEpoch
        let ownsStartMarker = true
        listeningStartID = operationID
        do {
            try await coordinator.startListening(configuration: configuration)
            let startedState = await coordinator.state
            guard ownsStartMarker,
                  listeningStartID == operationID,
                  !listeningStartCancellationRequested,
                  operationEpoch == lifecycleEpoch,
                  startedState == .listening else {
                // Leave the cancellation marker for the catch path to consume;
                // clearing it here would make the provider's cancellation
                // cleanup error look like an unrelated startup failure.
                await coordinator.cancelListening()
                throw VoiceError.cancelled
            }
            listeningStartID = nil
            listeningDiagnostic = (operationID, start)
            emit(
                operationID: operationID,
                operation: .listening,
                phase: .started,
                state: startedState,
                durationNanoseconds: Self.elapsed(since: start)
            )
        } catch {
            let startupCancellationWasRequested = ownsStartMarker &&
                (listeningStartCancellationRequested || listeningStartID != operationID)
            if ownsStartMarker, listeningStartID == operationID {
                listeningStartID = nil
                listeningStartCancellationRequested = false
            }
            let wasCancelled = startupCancellationWasRequested ||
                error is CancellationError ||
                (error as? VoiceError) == .cancelled
            if ownsStartMarker {
                emit(
                    operationID: operationID,
                    operation: .listening,
                    phase: wasCancelled ? .cancelled : .failed,
                    state: await coordinator.state,
                    error: error,
                    errorCategory: wasCancelled ? .cancelled : nil,
                    durationNanoseconds: Self.elapsed(since: start)
                )
            }
            throw error
        }
    }

    /// Admits a host-identified recognition session without waiting for Apple
    /// provider preparation to finish.
    ///
    /// Pre-admission rejection throws without creating a session identity.
    /// Once returned, startup failures are delivered as a typed terminal event
    /// for the accepted session. The legacy `startListening` call continues to
    /// await provider startup and throw its startup error.
    public func startSession(
        configuration: RecognitionSessionConfiguration = .init()
    ) async throws -> RecognitionSessionAcceptance {
        guard diagnosticsSink != nil || !diagnosticContinuations.isEmpty else {
            return try await coordinator.startSession(configuration: configuration)
        }

        // Canonical sessions can fail or terminate without another facade call,
        // so lifecycle truth is forwarded from the coordinator. This private
        // two-record stream preserves accepted-before-terminal order without
        // consuming a public event-subscriber slot or invoking host code from
        // inside the coordinator actor.
        let (stream, continuation) = AsyncStream.makeStream(
            of: RecognitionSessionDiagnosticEmission.self,
            bufferingPolicy: .bufferingOldest(2)
        )
        let delivery = Task { @MainActor [weak self] in
            for await emission in stream {
                guard let self else { return }
                emit(
                    operationID: emission.sessionID.rawValue,
                    operation: .listening,
                    phase: emission.phase,
                    state: emission.state,
                    errorCategory: emission.errorCategory,
                    durationNanoseconds: emission.durationNanoseconds
                )
            }
        }
        do {
            return try await coordinator.startSession(
                configuration: configuration,
                diagnosticContinuation: continuation
            )
        } catch {
            continuation.finish()
            delivery.cancel()
            throw error
        }
    }

    /// Stops microphone capture, finalizes the current turn, and returns the
    /// final transcript snapshot.
    public func finishListening() async throws -> String {
        // A canonical session may be finalized through this compatibility call.
        // Its coordinator-owned diagnostic already has the session UUID and
        // terminal truth; do not fabricate a second, uncorrelated operation.
        guard let record = listeningDiagnostic else {
            return try await coordinator.endListening()
        }
        let stateBeforeFinish = await coordinator.state
        let ownsActiveTurn = stateBeforeFinish == .listening || stateBeforeFinish == .finalizing
        do {
            let text = try await coordinator.endListening()
            listeningDiagnostic = nil
            emit(
                operationID: record.0,
                operation: .listening,
                phase: .completed,
                state: await coordinator.state,
                durationNanoseconds: Self.elapsed(since: record.1)
            )
            return text
        } catch {
            listeningDiagnostic = nil
            if ownsActiveTurn {
                emit(
                    operationID: record.0,
                    operation: .listening,
                    phase: .failed,
                    state: await coordinator.state,
                    error: error,
                    durationNanoseconds: Self.elapsed(since: record.1)
                )
            }
            throw error
        }
    }

    /// Finalizes only the matching active recognition session.
    ///
    /// A stale or unknown identity is rejected before provider state changes.
    public func finishSession(id: RecognitionSessionID) async throws -> FinalTranscript {
        try await coordinator.endSession(id: id)
    }

    /// Cancels microphone capture without returning a final transcript.
    /// Repeated calls are safe.
    public func cancelListening() async {
        guard let record = listeningDiagnostic else {
            if listeningStartID != nil {
                listeningStartCancellationRequested = true
            }
            await coordinator.cancelListening()
            return
        }
        let currentState = await coordinator.state
        guard currentState == .listening || currentState == .finalizing else {
            // The provider may have already ended this generation because of
            // an interruption, route change, background transition, or
            // failure. Do not manufacture a second cancellation diagnostic.
            listeningDiagnostic = nil
            return
        }
        await coordinator.cancelListening()
        listeningDiagnostic = nil
        let stateAfterCancellation = await coordinator.state
        if stateAfterCancellation == .failed {
            emit(
                operationID: record.id,
                operation: .listening,
                phase: .failed,
                state: stateAfterCancellation,
                errorCategory: .audioSessionUnavailable,
                durationNanoseconds: Self.elapsed(since: record.start)
            )
            return
        }
        emit(
            operationID: record.id,
            operation: .listening,
            phase: .cancelled,
            state: stateAfterCancellation,
            errorCategory: .cancelled,
            durationNanoseconds: Self.elapsed(since: record.start)
        )
    }

    /// Cancels only the matching active recognition session. A stale identity
    /// is an idempotent no-op and cannot cancel a later generation.
    public func cancelSession(id: RecognitionSessionID) async {
        await coordinator.cancelSession(id: id)
    }

    /// Speaks text using an installed Apple voice.
    ///
    /// Long text is split into bounded utterances by the provider. The call
    /// completes after playback finishes or throws a typed `VoiceError`.
    /// Empty and whitespace-only text are intentional no-ops and emit no
    /// speech lifecycle events.
    public func speak(_ text: String, configuration: SpeechConfiguration = .init()) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard normalized.utf16.count <= VoiceTextLimits.maximumUTF16Length else {
            throw VoiceError.textTooLong(maximumUTF16Length: VoiceTextLimits.maximumUTF16Length)
        }
        // `isAvailableForNewOperation()` is an async coordinator check. Keep
        // a synchronous facade reservation as well so concurrent main-actor
        // callers cannot both pass that check and leave diagnostics owned by
        // the losing task.
        guard speakingDiagnostic == nil else {
            throw VoiceError.invalidState("A voice operation is already active.")
        }
        let operationID = UUID()
        let start = Self.monotonicNanoseconds
        let operationEpoch = lifecycleEpoch
        let admissionEpoch = await coordinator.currentAdmissionEpoch()
        try Task.checkCancellation()
        // Reserve the facade diagnostic synchronously before the first await.
        // A second main-actor caller can therefore never overwrite the first
        // operation's record while the coordinator is reserving its token.
        let ownsOperationStart = true
        speakingDiagnostic = (operationID, start)
        do {
            if let preAdmissionError = await coordinator.preAdmissionErrorForNewOperation() {
                if ownsOperationStart, speakingDiagnostic?.id == operationID {
                    speakingDiagnostic = nil
                }
                throw preAdmissionError
            }
            try Task.checkCancellation()
            guard operationEpoch == lifecycleEpoch else { throw VoiceError.cancelled }
            let startedState = await coordinator.state
            try Task.checkCancellation()
            guard ownsOperationStart,
                  speakingDiagnostic?.id == operationID,
                  operationEpoch == lifecycleEpoch else {
                throw VoiceError.cancelled
            }
            if ownsOperationStart {
                emit(
                    operationID: operationID,
                    operation: .speaking,
                    phase: .started,
                    state: startedState,
                    durationNanoseconds: 0
                )
            }
            try await coordinator.speak(
                normalized,
                configuration: configuration,
                admissionEpoch: admissionEpoch
            )
            if ownsOperationStart, speakingDiagnostic?.id == operationID {
                speakingDiagnostic = nil
                emit(
                    operationID: operationID,
                    operation: .speaking,
                    phase: .completed,
                    state: await coordinator.state,
                    durationNanoseconds: Self.elapsed(since: start)
                )
            }
        } catch {
            if ownsOperationStart, speakingDiagnostic?.id == operationID {
                speakingDiagnostic = nil
                emit(
                    operationID: operationID,
                    operation: .speaking,
                    phase: error is VoiceError && (error as? VoiceError) == .cancelled ? .cancelled : .failed,
                    state: await coordinator.state,
                    error: error,
                    durationNanoseconds: Self.elapsed(since: start)
                )
            }
            throw error
        }
    }

    /// Accepts an identified immediate speech attempt without retaining it for
    /// replay. Await `waitForSpeechPlayback(id:)` for its terminal result.
    ///
    /// This lane bypasses queued ordering but still obeys the same serialized
    /// audio lifecycle as recognition and queue playback.
    public func speakImmediately(
        _ text: String,
        configuration: SpeechConfiguration = .init()
    ) async throws -> SpeechPlaybackAcceptance {
        try await coordinator.speakImmediately(text, configuration: configuration)
    }

    /// Validates and accepts text into the serialized speech queue. Acceptance
    /// does not wait for playback; returned text from any chat backend can be
    /// enqueued while another item is speaking.
    public func enqueueSpeech(
        _ text: String,
        priority: SpeechPriority = .normal,
        configuration: SpeechConfiguration = .init(),
        policy: SpeechEnqueuePolicy = .append
    ) async throws -> SpeechPlaybackAcceptance {
        let request = try SpeechItemRequest(
            text: text,
            priority: priority,
            configuration: configuration
        )
        return try await coordinator.enqueueSpeech(request, policy: policy)
    }

    /// Replays an item retained by the bounded queue history.
    public func replaySpeech(
        itemID: SpeechItemID,
        policy: SpeechEnqueuePolicy = .append
    ) async throws -> SpeechPlaybackAcceptance {
        try await coordinator.replaySpeech(itemID, policy: policy)
    }

    /// Waits for the exactly-once terminal result of one accepted playback
    /// attempt. Cancelling this wait affects only this caller; it never stops
    /// speech, changes queue mode, or cancels another observer's wait.
    public func waitForSpeechPlayback(
        id playbackID: SpeechPlaybackID
    ) async throws -> SpeechPlaybackResult {
        try await coordinator.waitForSpeechPlayback(playbackID)
    }

    /// Pauses active queued playback, if any, without discarding pending items.
    public func pauseSpeechQueue() async -> SpeechControlResult {
        await coordinator.pauseSpeechQueue()
    }

    /// Resumes queued playback when the queue is suspended.
    public func resumeSpeechQueue() async -> SpeechControlResult {
        await coordinator.resumeSpeechQueue()
    }

    /// Stops only the active queued playback and suspends the queue. Pending
    /// queued attempts remain accepted for a later `resumeSpeechQueue()`.
    @discardableResult
    public func stopSpeechQueue() async -> [SpeechPlaybackResult] {
        await coordinator.stopSpeechQueue()
    }

    /// Stops active queued playback, terminalizes all pending queued attempts,
    /// and leaves the queue suspended. Direct `speak` calls are unaffected.
    @discardableResult
    public func stopAndClearSpeechQueue() async -> [SpeechPlaybackResult] {
        await coordinator.stopAndClearSpeechQueue()
    }

    /// Skips the active queued item and advances to the next pending item.
    @discardableResult
    public func skipSpeechQueue() async -> SpeechPlaybackResult? {
        await coordinator.skipSpeechQueue()
    }

    /// Cancels pending queued items while leaving active playback unchanged.
    @discardableResult
    public func clearPendingSpeechQueue() async -> [SpeechPlaybackResult] {
        await coordinator.clearPendingSpeechQueue()
    }

    /// Pauses the active speech synthesis request, if any.
    ///
    /// This is an idempotent no-op when synthesis is inactive.
    public func pauseSpeaking() async { await coordinator.pauseSpeaking() }

    /// Resumes a paused speech synthesis request, if any.
    ///
    /// This is an idempotent no-op when synthesis is inactive or not paused.
    public func resumeSpeaking() async { await coordinator.resumeSpeaking() }

    /// Stops speech synthesis and releases its audio resources.
    public func stopSpeaking() async {
        guard let record = speakingDiagnostic else {
            await coordinator.stopSpeaking()
            return
        }
        let currentState = await coordinator.state
        guard currentState == .speaking || currentState == .failed else {
            // The request may still be in coordinator preflight while the
            // public state is idle. Invalidate that admission and publish the
            // one cancellation diagnostic here instead of allowing speech to
            // begin after stop returns.
            lifecycleEpoch &+= 1
            speakingDiagnostic = nil
            emit(
                operationID: record.id,
                operation: .speaking,
                phase: .cancelled,
                state: currentState,
                errorCategory: .cancelled,
                durationNanoseconds: Self.elapsed(since: record.start)
            )
            return
        }
        let stopped = await coordinator.stopSpeaking()
        guard speakingDiagnostic?.id == record.id else { return }
        speakingDiagnostic = nil
        guard stopped else {
            emit(
                operationID: record.id,
                operation: .speaking,
                phase: .failed,
                state: await coordinator.state,
                errorCategory: .speechSynthesisUnavailable,
                durationNanoseconds: Self.elapsed(since: record.start)
            )
            return
        }
        emit(
            operationID: record.id,
            operation: .speaking,
            phase: .cancelled,
            state: await coordinator.state,
            errorCategory: .cancelled,
            durationNanoseconds: Self.elapsed(since: record.start)
        )
    }

    /// Idempotently cancels active work and releases audio resources.
    ///
    /// Returns typed cleanup truth. `.released` means all resources owned by
    /// the service were observed released. `.blocked` means cleanup remains
    /// unresolved; the host should render the supplied recovery action and
    /// retry `close()` before starting another operation.
    @discardableResult
    public func close() async -> CleanupResult {
        let closeID = UUID()
        let closeStart = Self.monotonicNanoseconds
        lifecycleEpoch &+= 1
        if listeningStartID != nil {
            listeningStartCancellationRequested = true
        }
        emit(
            operationID: closeID,
            operation: .close,
            phase: .started,
            state: await coordinator.state,
            durationNanoseconds: 0
        )
        let stateBeforeClose = await coordinator.state
        let listening = (stateBeforeClose == .listening || stateBeforeClose == .finalizing)
            ? listeningDiagnostic
            : nil
        // A speech request may still be in facade/coordinator preflight while
        // the coordinator state is idle. Capture its marker so close owns the
        // cancellation diagnostic instead of letting the stale request start
        // after the close boundary.
        let speaking = speakingDiagnostic
        let closed = await coordinator.closeAndReport()
        let finalState = await coordinator.state
        if closed, listeningStartID != nil {
            // The coordinator has observed a terminal close boundary. A
            // cancelled startup task may still be unwinding its facade frame;
            // do not let that stale frame block a new start after close.
            listeningStartID = nil
            listeningStartCancellationRequested = false
        }
        if let listening, listeningDiagnostic?.id == listening.id {
            listeningDiagnostic = nil
            emit(
                operationID: listening.id,
                operation: .listening,
                phase: closed ? .cancelled : .failed,
                state: finalState,
                errorCategory: closed ? .cancelled : .audioSessionUnavailable,
                durationNanoseconds: Self.elapsed(since: listening.start)
            )
        }
        if let speaking, speakingDiagnostic?.id == speaking.id {
            speakingDiagnostic = nil
            emit(
                operationID: speaking.id,
                operation: .speaking,
                phase: closed ? .cancelled : .failed,
                state: finalState,
                errorCategory: closed ? .cancelled : .speechSynthesisUnavailable,
                durationNanoseconds: Self.elapsed(since: speaking.start)
            )
        }
        // Provider callbacks can finish a generation without a facade method
        // being called (for example, an interruption can end the transcript
        // stream). In that case the coordinator has already emitted the
        // operation's terminal event; do not manufacture a second diagnostic,
        // but do discard the facade's stale timing marker at the lifecycle
        // boundary.
        if listening == nil, listeningDiagnostic != nil,
           finalState != .listening, finalState != .preparing, finalState != .finalizing {
            listeningDiagnostic = nil
        }
        if speaking == nil, speakingDiagnostic != nil, finalState != .speaking {
            speakingDiagnostic = nil
        }
        emit(
            operationID: closeID,
            operation: .close,
            phase: closed ? .completed : .failed,
            state: finalState,
            errorCategory: closed ? nil : .audioSessionUnavailable,
            durationNanoseconds: Self.elapsed(since: closeStart)
        )
        guard !closed else { return .released }
        let failure: VoiceFailure
        if case .blocked(let blockedFailure) = await coordinator.recoveryState {
            failure = blockedFailure
        } else {
            failure = VoiceError.cleanupPending.failure
        }
        return .blocked(failure)
    }

    /// The current serialized lifecycle state.
    public var state: VoiceState { get async { await coordinator.state } }

    private static var monotonicNanoseconds: UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func elapsed(since start: UInt64) -> UInt64 {
        let now = monotonicNanoseconds
        return now >= start ? now - start : 0
    }

    private func emit(
        operationID: UUID,
        operation: VoiceDiagnosticOperation,
        phase: VoiceDiagnosticPhase,
        state: VoiceState,
        error: Error? = nil,
        errorCategory: VoiceErrorCategory? = nil,
        durationNanoseconds: UInt64
    ) {
        let category = errorCategory ?? (error as? VoiceError)?.category
        let diagnostic = VoiceDiagnostic(
            operationID: operationID,
            operation: operation,
            phase: phase,
            state: state,
            errorCategory: category,
            routeClass: Self.currentRouteClass(),
            durationNanoseconds: durationNanoseconds
        )
        diagnosticsSink?(diagnostic)
        for continuation in diagnosticContinuations.values { continuation.yield(diagnostic) }
    }

    private func removeDiagnosticContinuation(_ id: UUID) {
        diagnosticContinuations.removeValue(forKey: id)
        diagnosticContinuationOrder.removeAll { $0 == id }
    }

    private static func currentRouteClass() -> VoiceRouteClass {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType else {
            return .unknown
        }
        switch port {
        case .builtInSpeaker: return .builtInSpeaker
        case .builtInReceiver: return .builtInReceiver
        case .headphones, .headsetMic, .lineOut: return .wired
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return .bluetooth
        case .usbAudio: return .usb
        case .carAudio: return .car
        case .airPlay: return .airPlay
        default: return .other
        }
    }
}
