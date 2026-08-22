import AVFoundation
import AppLocalVoiceAudioEngineSafe

/// Internal seam around `AVAudioEngine` + `AVAudioPlayerNode` so the driver's
/// ordering, completion, stop, and rebuild logic is testable without hardware.
/// The production implementation talks to AVFoundation; tests record calls
/// and fire completions deterministically.
@MainActor
protocol PCMPlaybackEngine: AnyObject {
    /// Attaches and connects the player node for `format` and prepares the
    /// engine. Returns false when AVFoundation rejects the graph.
    func configure(format: AVAudioFormat) -> Bool
    /// Starts the engine and the player node. Returns false when the engine
    /// will not start.
    func start() -> Bool
    /// Schedules one buffer after any already-scheduled buffers. `completion`
    /// fires when the buffer's data has been played back; after `stop()` or
    /// `rebuild()` it may fire late or never, so callers must not trust it as
    /// the only terminal signal.
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void)
    func pause()
    /// Resumes a paused player. Returns false when playback could not resume.
    func resume() -> Bool
    /// Stops the player, discarding scheduled buffers, and stops the engine.
    func stop()
    /// Discards the engine and player after a media-services reset. The next
    /// `configure` must start from fresh objects.
    func rebuild()
}

/// Production engine seam. Engine prepare/start cross the Objective-C exception
/// barrier through `AppLocalVoiceAudioEngineSafe`, matching the capture path.
@MainActor
final class DefaultPCMPlaybackEngine: PCMPlaybackEngine {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var isAttached = false

    func configure(format: AVAudioFormat) -> Bool {
        if !isAttached {
            engine.attach(player)
            isAttached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        return AppLocalVoiceAudioEngineSafe.prepare(engine)
    }

    func start() -> Bool {
        guard AppLocalVoiceAudioEngineSafe.start(engine) else { return false }
        player.play()
        return true
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) {
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
            completion()
        }
    }

    func pause() {
        player.pause()
    }

    func resume() -> Bool {
        if !engine.isRunning {
            guard AppLocalVoiceAudioEngineSafe.start(engine) else { return false }
        }
        player.play()
        return true
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    func rebuild() {
        player.stop()
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        isAttached = false
    }
}

/// Plays synthesized PCM through the shared speaking lease.
///
/// One playback session at a time: `begin` acquires the lease and starts the
/// engine; `schedule` queues buffers in order; `stop` ends audible output,
/// resolves every outstanding buffer as `.stopped`, and releases the lease.
/// The caller (a `SpeechOutput`) decides *when* to begin — after the first
/// PCM exists — so external audio is not ducked while a model computes.
@MainActor
final class PCMPlaybackDriver {
    enum BufferOutcome: Sendable, Equatable {
        /// The buffer's data was played back.
        case played
        /// Playback was stopped before this buffer finished.
        case stopped
    }

    private static let activeFailure = VoiceError.invalidState("PCM playback is already active.")
    private static let inactiveFailure = VoiceError.invalidState("PCM playback is not active.")
    private static let engineFailure = VoiceError.speechSynthesisUnavailable("The playback engine could not start.")
    private static let bufferFailure = VoiceError.speechSynthesisUnavailable("Synthesized audio could not be buffered.")
    private static let formatFailure = VoiceError.speechSynthesisUnavailable("The synthesized audio format is unsupported.")

    private let audioSession: AudioSessionController
    private let engine: any PCMPlaybackEngine

    private var sessionActive = false
    private var format: AVAudioFormat?
    /// Monotonic across sessions, so a late completion from a stopped session
    /// can never name a buffer of a later session.
    private var nextBufferID: UInt64 = 0
    /// Buffers scheduled in the current session that have not resolved.
    private var outstanding: Set<UInt64> = []
    private var waiters: [UInt64: CheckedContinuation<BufferOutcome, Never>] = [:]
    private var outcomes: [UInt64: BufferOutcome] = [:]
    private var leaseReleaseFailed = false

    init(audioSession: AudioSessionController, engine: (any PCMPlaybackEngine)? = nil) {
        self.audioSession = audioSession
        // Constructed inside the main-actor initializer rather than as a
        // default argument so the production symbol-graph build (Swift 5
        // language mode) does not see an isolated call in a nonisolated
        // default-argument context.
        self.engine = engine ?? DefaultPCMPlaybackEngine()
    }

    /// Acquires the speaking lease and starts the engine for mono Float32 PCM
    /// at `sampleRate`. Call only when PCM is ready to play.
    func begin(sampleRate: Double, lifecyclePolicy: AudioLifecyclePolicy) async throws {
        guard !sessionActive else { throw Self.activeFailure }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw Self.formatFailure
        }
        do {
            try await audioSession.enter(role: .speaking, lifecyclePolicy: lifecyclePolicy)
            leaseReleaseFailed = false
        } catch {
            _ = await releaseLease()
            throw VoiceError.audioSessionUnavailable("Audio session activation failed.")
        }
        guard engine.configure(format: format), engine.start() else {
            engine.stop()
            _ = await releaseLease()
            throw Self.engineFailure
        }
        self.format = format
        sessionActive = true
    }

    /// Queues `samples` after any buffer already scheduled in this session and
    /// returns a ticket for `outcome(of:)`.
    func schedule(_ samples: [Float]) throws -> UInt64 {
        guard sessionActive, let format else { throw Self.inactiveFailure }
        guard let buffer = Self.makeBuffer(samples, format: format) else { throw Self.bufferFailure }
        nextBufferID &+= 1
        let id = nextBufferID
        outstanding.insert(id)
        engine.schedule(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                self?.complete(id)
            }
        }
        return id
    }

    /// Suspends until the buffer has played back or playback was stopped.
    func outcome(of id: UInt64) async -> BufferOutcome {
        if let known = outcomes.removeValue(forKey: id) { return known }
        guard outstanding.contains(id) else { return .stopped }
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
        }
    }

    func pause() {
        guard sessionActive else { return }
        engine.pause()
    }

    func resume() {
        guard sessionActive else { return }
        _ = engine.resume()
    }

    /// Ends audible output now, discards scheduled buffers, resolves every
    /// outstanding buffer as `.stopped`, stops the engine, and releases the
    /// lease. Returns false when the lease could not be released; the session
    /// stays marked unreleased until a later `stop()` succeeds.
    @discardableResult
    func stop() async -> Bool {
        if sessionActive {
            engine.stop()
            for id in outstanding { resolve(id, .stopped) }
            outstanding.removeAll()
            sessionActive = false
            format = nil
        }
        return await releaseLease()
    }

    /// After a media-services reset the old engine is not a trustworthy stop
    /// authority. Stop, then discard the engine so the next session starts
    /// from new objects.
    @discardableResult
    func rebuildAfterMediaServicesReset() async -> Bool {
        let released = await stop()
        engine.rebuild()
        return released
    }

    /// True when no session is active and the lease was released.
    func resourcesAreReleased() -> Bool {
        !sessionActive && !leaseReleaseFailed
    }

    /// Copies mono Float32 samples into a PCM buffer of `format`.
    static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, format.channelCount == 1, format.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: source.count)
        }
        return buffer
    }

    private func complete(_ id: UInt64) {
        // A completion from a stopped session was already resolved as
        // `.stopped` and removed from `outstanding`; AVFoundation fires
        // completions on stop too, so this late call must be a no-op.
        guard outstanding.contains(id) else { return }
        outstanding.remove(id)
        resolve(id, .played)
    }

    private func resolve(_ id: UInt64, _ outcome: BufferOutcome) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: outcome)
        } else {
            outcomes[id] = outcome
        }
    }

    private func releaseLease() async -> Bool {
        do {
            try await audioSession.exit()
            leaseReleaseFailed = false
            return true
        } catch {
            leaseReleaseFailed = true
            return false
        }
    }
}
