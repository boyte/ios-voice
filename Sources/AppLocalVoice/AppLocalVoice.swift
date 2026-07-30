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
/// A recognition session has explicit start and finish calls so the host
/// controls the end of user speech:
///
/// ```swift
/// let voice = AppLocalVoice()
/// let session = try await voice.startSession()
/// let transcript = try await voice.finishSession(id: session.sessionID)
/// let playback = try await voice.speakImmediately(transcript.text)
/// _ = try await voice.waitForSpeechPlayback(id: playback.playbackID)
/// _ = await voice.close()
/// ```
///
/// The package deliberately does not provide a `transcribe()` method that
/// starts and ends a turn by itself. There is no reliable, platform-neutral
/// definition of “the user has finished speaking”; automatic silence
/// detection would make lifecycle behavior less deterministic. Apps that have
/// their own push-to-talk, turn detector, or endpoint policy should call
/// `startSession(configuration:)` and `finishSession(id:)` explicitly.
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

    /// Returns the canonical backend-agnostic stream for recognition, speech
    /// queue/playback, and process recovery events.
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

    // Internal seams retain deterministic provider coverage while the public
    // package exposes only the identified session and playback APIs.
    func events() async -> AsyncStream<VoiceEvent> { await coordinator.events() }
    func recognitionEvents() async -> AsyncThrowingStream<RecognitionEvent, Error> {
        await coordinator.recognitionEvents()
    }
    func capabilities(for locale: Locale = .current) async -> SpeechCapabilities {
        await coordinator.capabilities(for: locale)
    }
    func startListening(configuration: RecognitionConfiguration = .init()) async throws {
        try await coordinator.startListening(configuration: configuration)
    }
    func finishListening() async throws -> String { try await coordinator.endListening() }
    func cancelListening() async { await coordinator.cancelListening() }
    func speak(_ text: String, configuration: SpeechConfiguration = .init()) async throws {
        try await coordinator.speak(text, configuration: configuration)
    }
    func pauseSpeaking() async { await coordinator.pauseSpeaking() }
    func resumeSpeaking() async { await coordinator.resumeSpeaking() }
    func stopSpeaking() async { _ = await coordinator.stopSpeaking() }

    /// Admits a host-identified recognition session without waiting for Apple
    /// provider preparation to finish.
    ///
    /// Pre-admission rejection throws without creating a session identity.
    /// Once returned, startup failures are delivered as a typed terminal event
    /// for the accepted session.
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

    /// Finalizes only the matching active recognition session.
    ///
    /// A stale or unknown identity is rejected before provider state changes.
    public func finishSession(id: RecognitionSessionID) async throws -> FinalTranscript {
        try await coordinator.endSession(id: id)
    }

    /// Cancels only the matching active recognition session. A stale identity
    /// is an idempotent no-op and cannot cancel a later generation.
    public func cancelSession(id: RecognitionSessionID) async {
        await coordinator.cancelSession(id: id)
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
    /// and leaves the queue suspended. Immediate playback is unaffected.
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
        emit(
            operationID: closeID,
            operation: .close,
            phase: .started,
            state: await coordinator.state,
            durationNanoseconds: 0
        )
        let closed = await coordinator.closeAndReport()
        let finalState = await coordinator.state
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

    var state: VoiceState { get async { await coordinator.state } }

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
