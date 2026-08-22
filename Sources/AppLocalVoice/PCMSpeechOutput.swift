import AVFoundation
import UIKit

/// Engine-agnostic speech output: splits a request into chunks, synthesizes
/// through a ``SpeechSynthesizer``, and plays the PCM through
/// `PCMPlaybackDriver` under the shared speaking lease.
///
/// Ordering that matters:
/// 1. The first chunk is synthesized *before* the speaking lease is acquired,
///    so external audio is not ducked while an engine computes.
/// 2. While chunk N plays, at most chunk N+1 is synthesized. There is never an
///    unbounded PCM queue.
/// 3. Progress is published only for chunks that have finished playing, as the
///    chunk's exact UTF-16 range in the original request.
///
/// Like `AppleSpeechOutput`, this type is main-actor isolated so notification
/// callbacks, player completions, and request mutation share one ordering
/// domain.
@MainActor
final class PCMSpeechOutput: SpeechOutput {
    /// Keeps first audio fast: the first chunk is roughly one sentence.
    static let firstChunkMaximumUTF16Length = 140
    /// Later chunks: a few sentences, well inside any engine's input limit.
    static let chunkMaximumUTF16Length = 300
    private static let watchdogBaseSeconds = 20.0
    private static let watchdogSecondsPerUTF16Unit = 0.02
    private static let watchdogMaximumSeconds = 120.0
    private static let watchdogFailure = VoiceError.speechSynthesisUnavailable(
        "The speech synthesizer did not return audio within the recovery deadline."
    )
    private static let audioSessionReleaseFailure = VoiceError.audioSessionUnavailable(
        "The speech audio session could not be restored; retry close() before starting another turn."
    )

    private struct ActiveRequest {
        let id: UInt64
        let chunks: [SpeechTextChunker.Chunk]
        let configuration: SpeechConfiguration
        let lifecyclePolicy: AudioLifecyclePolicy
        var continuation: CheckedContinuation<Void, Error>?
        let progressHandler: (@Sendable (Range<Int>) async -> Void)?
        var playbackBegun = false
        var paused = false
    }

    /// SAFETY: see `AppleSpeechOutput.ObserverTokens`; tokens are written on
    /// the main actor and read only by the nonisolated deinit.
    private final class ObserverTokens: @unchecked Sendable {
        var interruption: NSObjectProtocol?
        var route: NSObjectProtocol?
        var background: NSObjectProtocol?
        var mediaServicesLost: NSObjectProtocol?
        var mediaServicesReset: NSObjectProtocol?
    }

    private let synthesizer: any SpeechSynthesizer
    private let player: PCMPlaybackDriver
    private let notificationCenter: any AudioNotificationCenter
    private let watchdogSleep: @Sendable (Duration) async throws -> Void
    private let observers = ObserverTokens()

    private var current: ActiveRequest?
    private var pipeline: Task<Void, Never>?
    private var activeSynthesis: Task<SynthesizedSpeech, Error>?
    private var nextID: UInt64 = 0
    private var stopping = false
    private var nextProgressHandler: (@Sendable (Range<Int>) async -> Void)?

    convenience init(synthesizer: any SpeechSynthesizer, audioSession: AudioSessionController) {
        self.init(
            synthesizer: synthesizer,
            player: PCMPlaybackDriver(audioSession: audioSession),
            notificationCenter: DefaultAudioNotificationCenter()
        )
    }

    init(
        synthesizer: any SpeechSynthesizer,
        player: PCMPlaybackDriver,
        notificationCenter: any AudioNotificationCenter,
        watchdogSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.synthesizer = synthesizer
        self.player = player
        self.notificationCenter = notificationCenter
        self.watchdogSleep = watchdogSleep
        registerObservers()
    }

    // MARK: SpeechOutput

    func availableVoices(for locale: Locale) async -> [SpeechVoice] {
        await synthesizer.availableVoices(for: locale)
    }

    func speak(_ text: String, configuration: SpeechConfiguration) async throws {
        try await speak(text, configuration: configuration, lifecyclePolicy: .init())
    }

    func speak(
        _ text: String,
        configuration: SpeechConfiguration,
        lifecyclePolicy: AudioLifecyclePolicy
    ) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard !stopping else {
            throw VoiceError.invalidState("Speech cleanup is still in progress; retry after close().")
        }
        guard current == nil else {
            throw VoiceError.invalidState("Speech output is already active.")
        }
        try AppleSpeechOutput.validateText(normalized)
        try AppleSpeechOutput.validate(configuration)

        let chunks = Self.chunk(normalized, maximumUTF16Length: configuration.maximumCharactersPerUtterance)
        guard !chunks.isEmpty else { return }

        nextID &+= 1
        let requestID = nextID
        try Task.checkCancellation()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: VoiceError.cancelled)
                    return
                }
                current = ActiveRequest(
                    id: requestID,
                    chunks: chunks,
                    configuration: configuration,
                    lifecyclePolicy: lifecyclePolicy,
                    continuation: continuation,
                    progressHandler: nextProgressHandler
                )
                pipeline = Task { @MainActor [weak self] in
                    await self?.run(requestID: requestID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.cancelRequest(id: requestID)
            }
        }
    }

    func pause() async {
        guard var request = current else { return }
        request.paused = true
        current = request
        if request.playbackBegun { player.pause() }
    }

    func resume() async {
        guard var request = current else { return }
        request.paused = false
        current = request
        if request.playbackBegun { player.resume() }
    }

    func stop() async {
        await terminate(with: VoiceError.cancelled, rebuildPlayer: false)
    }

    func setProgressHandler(_ handler: (@Sendable (Range<Int>) async -> Void)?) async {
        nextProgressHandler = handler
    }

    func resourcesAreReleased() async -> Bool {
        current == nil && !stopping && player.resourcesAreReleased()
    }

    // MARK: Chunking

    /// Splits a request into a short first chunk followed by sentence-group
    /// chunks, each carrying its exact UTF-16 range in `text`. Both limits are
    /// capped by the host's `maximumCharactersPerUtterance`.
    static func chunk(_ text: String, maximumUTF16Length: Int) -> [SpeechTextChunker.Chunk] {
        let firstLimit = max(1, min(firstChunkMaximumUTF16Length, maximumUTF16Length))
        let restLimit = max(1, min(chunkMaximumUTF16Length, maximumUTF16Length))
        guard let first = SpeechTextChunker.splitWithUTF16Ranges(text, maximumUTF16Length: firstLimit).first else {
            return []
        }
        let firstEnd = text.utf16.index(text.utf16.startIndex, offsetBy: first.utf16Range.count)
        let remainder = String(text[firstEnd...])
        let rest = SpeechTextChunker.splitWithUTF16Ranges(remainder, maximumUTF16Length: restLimit).map { chunk in
            SpeechTextChunker.Chunk(
                text: chunk.text,
                utf16Range: (chunk.utf16Range.lowerBound + first.utf16Range.count)
                    ..< (chunk.utf16Range.upperBound + first.utf16Range.count)
            )
        }
        return [first] + rest
    }

    // MARK: Pipeline

    private func run(requestID: UInt64) async {
        guard let request = current, request.id == requestID else { return }
        do {
            var pcm = try await synthesizeBounded(request.chunks[0], configuration: request.configuration, requestID: requestID)
            guard isCurrent(requestID) else { return }

            try await player.begin(sampleRate: synthesizer.sampleRate, lifecyclePolicy: request.lifecyclePolicy)
            guard isCurrent(requestID), var begun = current else {
                // Stopped while the lease was being acquired; the lease must
                // not outlive the request it was acquired for.
                _ = await player.stop()
                return
            }
            begun.playbackBegun = true
            current = begun
            if begun.paused { player.pause() }

            var index = 0
            var ticket = try player.schedule(pcm.samples)
            while true {
                let nextIndex = index + 1
                var prefetch: Task<SynthesizedSpeech, Error>?
                if nextIndex < request.chunks.count {
                    prefetch = synthesizeTask(request.chunks[nextIndex], configuration: request.configuration, requestID: requestID)
                }
                let outcome = await player.outcome(of: ticket)
                guard outcome == .played, isCurrent(requestID) else {
                    // `stop()`/interruption already resolved the request and
                    // released the lease; only the prefetch may drain late.
                    prefetch?.cancel()
                    return
                }
                if let handler = request.progressHandler {
                    await handler(request.chunks[index].utf16Range)
                }
                guard let prefetch else { break }
                pcm = try await prefetch.value
                guard isCurrent(requestID) else { return }
                ticket = try player.schedule(pcm.samples)
                index = nextIndex
            }

            guard isCurrent(requestID) else { return }
            let released = await player.stop()
            let finished = current
            current = nil
            stopping = !released
            if released {
                finished?.continuation?.resume()
            } else {
                finished?.continuation?.resume(throwing: Self.audioSessionReleaseFailure)
            }
        } catch {
            guard isCurrent(requestID) else { return }
            let released = await player.stop()
            let failed = current
            current = nil
            stopping = !released
            failed?.continuation?.resume(throwing: released ? error : Self.audioSessionReleaseFailure)
        }
    }

    private func isCurrent(_ requestID: UInt64) -> Bool {
        current?.id == requestID
    }

    /// Runs one synthesis on the engine without blocking the main actor, and
    /// remembers it so `stop()` can cancel cooperative engines.
    private func synthesizeTask(
        _ chunk: SpeechTextChunker.Chunk,
        configuration: SpeechConfiguration,
        requestID: UInt64
    ) -> Task<SynthesizedSpeech, Error> {
        let synthesizer = self.synthesizer
        let text = chunk.text
        let task = Task.detached(priority: .userInitiated) {
            try await synthesizer.synthesize(text, configuration: configuration)
        }
        activeSynthesis = task
        return task
    }

    /// Synthesis bounded by a stall watchdog. An engine whose compute cannot
    /// be interrupted may keep running after the deadline; the request fails
    /// now and the late result is discarded.
    private func synthesizeBounded(
        _ chunk: SpeechTextChunker.Chunk,
        configuration: SpeechConfiguration,
        requestID: UInt64
    ) async throws -> SynthesizedSpeech {
        let work = synthesizeTask(chunk, configuration: configuration, requestID: requestID)
        let deadline = Self.watchdogDuration(forUTF16Length: chunk.text.utf16.count)
        let sleep = watchdogSleep
        let timer = Task { try await sleep(deadline) }
        defer { timer.cancel() }

        let race = SynthesisRace()
        let waiter = Task { @MainActor in
            do {
                race.finish(.success(try await work.value))
            } catch {
                race.finish(.failure(error))
            }
        }
        Task { @MainActor in
            do {
                try await timer.value
                work.cancel()
                race.finish(.failure(Self.watchdogFailure))
            } catch {
                // The timer was cancelled because synthesis finished first.
            }
        }
        _ = waiter
        return try await race.result()
    }

    static func watchdogDuration(forUTF16Length length: Int) -> Duration {
        .seconds(min(
            watchdogMaximumSeconds,
            watchdogBaseSeconds + Double(max(0, length)) * watchdogSecondsPerUTF16Unit
        ))
    }

    // MARK: Termination

    private func cancelRequest(id: UInt64) async {
        guard current?.id == id else { return }
        await terminate(with: VoiceError.cancelled, rebuildPlayer: false)
    }

    /// Ends the active request (if any) with `error`, stops audible output,
    /// releases the lease, and resolves the waiting caller exactly once. A
    /// failed lease release keeps `stopping` set so `resourcesAreReleased()`
    /// stays false until a later `stop()` succeeds.
    private func terminate(with error: Error, rebuildPlayer: Bool) async {
        stopping = true
        activeSynthesis?.cancel()
        activeSynthesis = nil
        let request = current
        current = nil
        let released = rebuildPlayer
            ? await player.rebuildAfterMediaServicesReset()
            : await player.stop()
        stopping = !released
        request?.continuation?.resume(throwing: released ? error : Self.audioSessionReleaseFailure)
    }

    // MARK: Observers

    private func registerObservers() {
        observers.interruption = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification) == .interruptionBegan else { return }
            Task { @MainActor [weak self] in
                await self?.handleAudioFailure(VoiceLifecycleInterruption(reason: .systemInterruption))
            }
        }
        observers.route = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification, consumer: .output) == .routeChanged else { return }
            Task { @MainActor [weak self] in
                await self?.handleAudioFailure(VoiceLifecycleInterruption(reason: .routeChange))
            }
        }
        observers.background = notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification) == .applicationBackgrounded else { return }
            Task { @MainActor [weak self] in
                await self?.handleAudioFailure(VoiceLifecycleInterruption(reason: .appBackground))
            }
        }
        observers.mediaServicesLost = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification) == .mediaServicesInvalidated else { return }
            Task { @MainActor [weak self] in
                await self?.handleAudioFailure(VoiceLifecycleInterruption(reason: .mediaServicesReset))
            }
        }
        observers.mediaServicesReset = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification) == .mediaServicesInvalidated else { return }
            Task { @MainActor [weak self] in
                await self?.handleAudioFailure(
                    VoiceLifecycleInterruption(reason: .mediaServicesReset),
                    rebuildPlayer: true
                )
            }
        }
    }

    private func handleAudioFailure(_ error: Error, rebuildPlayer: Bool = false) async {
        if current == nil {
            // A reset can arrive while idle; the next request must never use
            // an engine that was attached to the old media server.
            if rebuildPlayer { _ = await player.rebuildAfterMediaServicesReset() }
            return
        }
        await terminate(with: error, rebuildPlayer: rebuildPlayer)
    }

    deinit {
        if let interruption = observers.interruption { notificationCenter.removeObserver(interruption) }
        if let route = observers.route { notificationCenter.removeObserver(route) }
        if let background = observers.background { notificationCenter.removeObserver(background) }
        if let mediaServicesLost = observers.mediaServicesLost { notificationCenter.removeObserver(mediaServicesLost) }
        if let mediaServicesReset = observers.mediaServicesReset { notificationCenter.removeObserver(mediaServicesReset) }
    }
}

/// Resolves a synthesis race (engine result vs. watchdog) exactly once.
@MainActor
private final class SynthesisRace {
    private var continuation: CheckedContinuation<SynthesizedSpeech, Error>?
    private var settled: Result<SynthesizedSpeech, Error>?

    func finish(_ result: Result<SynthesizedSpeech, Error>) {
        guard settled == nil else { return }
        settled = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func result() async throws -> SynthesizedSpeech {
        if let settled { return try settled.get() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }
}
