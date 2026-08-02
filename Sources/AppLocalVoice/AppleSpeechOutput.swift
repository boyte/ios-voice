import AVFoundation
import UIKit

@MainActor
protocol SpeechSynthesizerDriver: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    /// Rebuilds the Apple synthesizer after media services reset. Test seams
    /// may keep their deterministic driver by using the default no-op.
    func resetAfterMediaServicesReset()
    /// Makes AVSpeechSynthesizer use the application's explicitly leased
    /// AVAudioSession instead of managing a private playback session.
    func configureForApplicationAudioSession()
    func speak(_ utterance: AVSpeechUtterance)
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func continueSpeaking() -> Bool
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension SpeechSynthesizerDriver {
    func configureForApplicationAudioSession() {}
    func resetAfterMediaServicesReset() {}
}

@MainActor
final class DefaultSpeechSynthesizerDriver: SpeechSynthesizerDriver {
    private var synthesizer: AVSpeechSynthesizer

    init(_ synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        synthesizer.usesApplicationAudioSession = true
    }

    func configureForApplicationAudioSession() {
        synthesizer.usesApplicationAudioSession = true
    }

    func resetAfterMediaServicesReset() {
        let delegate = synthesizer.delegate
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.delegate = nil
        let replacement = AVSpeechSynthesizer()
        replacement.usesApplicationAudioSession = true
        replacement.delegate = delegate
        synthesizer = replacement
    }

    var delegate: AVSpeechSynthesizerDelegate? {
        get { synthesizer.delegate }
        set { synthesizer.delegate = newValue }
    }

    func speak(_ utterance: AVSpeechUtterance) { synthesizer.speak(utterance) }
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { synthesizer.pauseSpeaking(at: boundary) }
    func continueSpeaking() -> Bool { synthesizer.continueSpeaking() }
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { synthesizer.stopSpeaking(at: boundary) }
}

/// Apple-native, on-device speech synthesis for one active logical request.
///
/// This type is main-actor isolated because AVSpeechSynthesizer delegate
/// callbacks and request mutation must be observed in one ordering domain.
@MainActor
final class AppleSpeechOutput: NSObject, SpeechOutput {
    private static let watchdogBaseSeconds = 30.0
    private static let watchdogSecondsPerUTF16Unit = 0.02
    private static let watchdogMaximumSeconds = 300.0
    private static let watchdogFailure = VoiceError.speechSynthesisUnavailable(
        "The speech synthesizer did not report completion within the recovery deadline."
    )
    private static let maximumCharactersPerUtterance = 32_000
    private static let audioSessionReleaseFailure = VoiceError.audioSessionUnavailable(
        "The speech audio session could not be restored; retry close() before starting another turn."
    )

    private struct ActiveSpeech {
        let id: UInt64
        let chunks: [SpeechTextChunker.Chunk]
        let configuration: SpeechConfiguration
        let voice: AVSpeechSynthesisVoice?
        var nextChunk: Int
        var continuation: CheckedContinuation<Void, Error>?
        let progressHandler: (@Sendable (Range<Int>) async -> Void)?
        var lastProgressRange: Range<Int>?
    }

    private let synthesizer: any SpeechSynthesizerDriver
    private let audioSession: AudioSessionController
    private let notificationCenter: any AudioNotificationCenter
    private let watchdogSleep: @Sendable (Duration) async throws -> Void
    private let voiceResolver: @MainActor (SpeechConfiguration) throws -> AVSpeechSynthesisVoice?
    /// SAFETY: this container never escapes `AppleSpeechOutput`. Tokens are
    /// written only on the main actor, and notification closures capture the
    /// output weakly. Nonisolated deinit is the only off-actor reader and cannot
    /// race main-actor work because any such work would still retain the output.
    private final class ObserverTokens: @unchecked Sendable {
        var interruption: NSObjectProtocol?
        var route: NSObjectProtocol?
        var background: NSObjectProtocol?
        var mediaServicesLost: NSObjectProtocol?
        var mediaServicesReset: NSObjectProtocol?
    }
    private let observers = ObserverTokens()
    private var current: ActiveSpeech?
    private var currentUtterance: AVSpeechUtterance?
    private var currentRequestID: UInt64?
    private var watchdogTask: Task<Void, Never>?
    private var nextID: UInt64 = 0
    private var stopping = false
    private var sessionReleaseFailed = false
    private var nextProgressHandler: (@Sendable (Range<Int>) async -> Void)?

    override init() {
        audioSession = AudioSessionController()
        synthesizer = DefaultSpeechSynthesizerDriver()
        notificationCenter = DefaultAudioNotificationCenter()
        watchdogSleep = { duration in try await Task.sleep(for: duration) }
        voiceResolver = { configuration in try Self.selectedVoice(for: configuration) }
        super.init()
        synthesizer.configureForApplicationAudioSession()
        synthesizer.delegate = self
        registerObservers()
    }

    init(audioSession: AudioSessionController) {
        self.audioSession = audioSession
        synthesizer = DefaultSpeechSynthesizerDriver()
        notificationCenter = DefaultAudioNotificationCenter()
        watchdogSleep = { duration in try await Task.sleep(for: duration) }
        voiceResolver = { configuration in try Self.selectedVoice(for: configuration) }
        super.init()
        synthesizer.configureForApplicationAudioSession()
        synthesizer.delegate = self
        registerObservers()
    }

    init(audioSession: AudioSessionController, synthesizer: any SpeechSynthesizerDriver) {
        self.audioSession = audioSession
        self.synthesizer = synthesizer
        notificationCenter = DefaultAudioNotificationCenter()
        watchdogSleep = { duration in try await Task.sleep(for: duration) }
        voiceResolver = { configuration in try Self.selectedVoice(for: configuration) }
        super.init()
        synthesizer.configureForApplicationAudioSession()
        synthesizer.delegate = self
        registerObservers()
    }

    init(
        audioSession: AudioSessionController,
        synthesizer: any SpeechSynthesizerDriver,
        notificationCenter: any AudioNotificationCenter,
        watchdogSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        voiceResolver: @escaping @MainActor (SpeechConfiguration) throws -> AVSpeechSynthesisVoice? = { configuration in
            try AppleSpeechOutput.selectedVoice(for: configuration)
        }
    ) {
        self.audioSession = audioSession
        self.synthesizer = synthesizer
        self.notificationCenter = notificationCenter
        self.watchdogSleep = watchdogSleep
        self.voiceResolver = voiceResolver
        super.init()
        synthesizer.configureForApplicationAudioSession()
        synthesizer.delegate = self
        registerObservers()
    }

    func speak(_ text: String, configuration: SpeechConfiguration = .init()) async throws {
        try await speak(
            text,
            configuration: configuration,
            lifecyclePolicy: .init()
        )
    }

    func speak(
        _ text: String,
        configuration: SpeechConfiguration = .init(),
        lifecyclePolicy: AudioLifecyclePolicy
    ) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard !stopping else {
            throw VoiceError.invalidState("Speech cleanup is still in progress; retry after close().")
        }
        // Cross-message ordering belongs exclusively to SpeechQueueEngine.
        // This adapter sequences chunks for one logical request, but must not
        // retain a second request for later playback.
        guard current == nil else {
            throw VoiceError.invalidState("Speech output is already active.")
        }
        try Self.validateText(normalized)
        try Self.validate(configuration)

        let chunks = SpeechTextChunker.splitWithUTF16Ranges(
            normalized,
            maximumUTF16Length: configuration.maximumCharactersPerUtterance
        )
        guard !chunks.isEmpty else { return }
        let selectedVoice = try voiceResolver(configuration)

        nextID &+= 1
        let requestID = nextID

        let acquiredLease = current == nil
        if acquiredLease {
            do {
                try await audioSession.enter(
                    role: .speaking,
                    lifecyclePolicy: lifecyclePolicy
                )
                sessionReleaseFailed = false
            } catch {
                // Activation can fail after changing the process-wide
                // singleton. The owner-scoped controller makes this retry
                // safe even when another voice service is active.
                _ = await releaseAudioSessionIfIdle()
                throw VoiceError.audioSessionUnavailable("Audio session activation failed.")
            }
        }

        do {
            try Task.checkCancellation()
        } catch {
            if acquiredLease { _ = await releaseAudioSessionIfIdle() }
            throw VoiceError.cancelled
        }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let pending = ActiveSpeech(
                        id: requestID,
                        chunks: chunks,
                        configuration: configuration,
                        voice: selectedVoice,
                        nextChunk: 0,
                        continuation: continuation,
                        progressHandler: nextProgressHandler,
                        lastProgressRange: nil
                    )
                    if Task.isCancelled {
                        continuation.resume(throwing: VoiceError.cancelled)
                        return
                    }
                    stopping = false
                    start(pending)
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    await self?.cancelRequest(id: requestID)
                }
            }
        } catch {
            // Cancellation can win between the lease acquisition and the
            // continuation registration. In that narrow window there is no
            // request callback to release the lease for us.
            if acquiredLease, current == nil {
                _ = await releaseAudioSessionIfIdle()
            }
            throw error
        }
    }

    func setProgressHandler(_ handler: (@Sendable (Range<Int>) async -> Void)?) async {
        nextProgressHandler = handler
    }

    func availableVoices(for locale: Locale) async -> [SpeechVoice] {
        Self.voiceCatalog(from: AVSpeechSynthesisVoice.speechVoices(), locale: locale)
    }

    func pause() async {
        guard current != nil else { return }
        _ = synthesizer.pauseSpeaking(at: .word)
    }

    func resume() async {
        guard current != nil else { return }
        _ = synthesizer.continueSpeaking()
    }

    func stop() async {
        stopping = true
        watchdogTask?.cancel()
        watchdogTask = nil

        let hasOutstandingSpeech = current != nil
        let stopAccepted = synthesizer.stopSpeaking(at: .immediate)
        guard !hasOutstandingSpeech || stopAccepted else {
            // A false result does not prove that AVFoundation stopped the
            // utterance. Keep the request and audio lease owned so a later
            // close() can retry instead of claiming clean teardown while
            // audio may still be playing.
            return
        }

        let currentContinuation = current?.continuation
        current = nil
        currentUtterance = nil
        currentRequestID = nil

        // Clear our bookkeeping immediately after the accepted stop request.
        // Its delegate may call back synchronously or later; either way the
        // callback cannot complete a new request.
        currentContinuation?.resume(throwing: VoiceError.cancelled)
        if await releaseAudioSessionIfIdle() {
            stopping = false
        }
    }

    func resourcesAreReleased() async -> Bool {
        current == nil && !stopping && !sessionReleaseFailed
    }

    static func validate(_ configuration: SpeechConfiguration) throws {
        guard !configuration.locale.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceError.invalidSpeechConfiguration("Speech locale must not be empty.")
        }
        guard configuration.rate >= 0, configuration.rate <= 1 else {
            throw VoiceError.invalidSpeechConfiguration("Speech rate must be between 0 and 1.")
        }
        guard configuration.volume >= 0, configuration.volume <= 1 else {
            throw VoiceError.invalidSpeechConfiguration("Speech volume must be between 0 and 1.")
        }
        guard configuration.maximumCharactersPerUtterance >= 128,
              configuration.maximumCharactersPerUtterance <= Self.maximumCharactersPerUtterance else {
            throw VoiceError.invalidSpeechConfiguration(
                "Speech chunks must contain between 128 and \(Self.maximumCharactersPerUtterance) UTF-16 code units."
            )
        }
    }

    static func validateText(_ text: String) throws {
        guard text.utf16.count <= VoiceTextLimits.maximumUTF16Length else {
            throw VoiceError.textTooLong(maximumUTF16Length: VoiceTextLimits.maximumUTF16Length)
        }
    }

    private func start(_ pending: ActiveSpeech) {
        guard !stopping, pending.nextChunk < pending.chunks.count else {
            pending.continuation?.resume(throwing: VoiceError.cancelled)
            return
        }

        var active = pending
        active.lastProgressRange = nil
        current = active
        let utterance = AVSpeechUtterance(string: pending.chunks[pending.nextChunk].text)
        utterance.rate = pending.configuration.rate
        utterance.volume = pending.configuration.volume
        utterance.voice = pending.voice
        currentUtterance = utterance
        currentRequestID = pending.id
        synthesizer.speak(utterance)
        startWatchdog(for: utterance, requestID: pending.id)
    }

    private func startWatchdog(for utterance: AVSpeechUtterance, requestID: UInt64) {
        watchdogTask?.cancel()
        let duration = Self.watchdogDuration(
            forUTF16Length: utterance.speechString.utf16.count,
            rate: current?.configuration.rate ?? 0.52
        )
        watchdogTask = Task { @MainActor [weak self] in
            do {
                try await self?.watchdogSleep(duration)
                guard !Task.isCancelled else { return }
                await self?.handleWatchdogExpiry(for: utterance, requestID: requestID)
            } catch {
                // Cancellation is the normal path when AVFoundation reports
                // completion, cancellation, interruption, or a route change.
            }
        }
    }

    private func handleSpeechProgress(for utteranceID: ObjectIdentifier, localRange: NSRange) async {
        guard let currentUtterance,
              ObjectIdentifier(currentUtterance) == utteranceID,
              let requestID = currentRequestID,
              let current,
              current.nextChunk < current.chunks.count,
              localRange.location >= 0,
              localRange.length >= 0 else { return }
        let chunk = current.chunks[current.nextChunk]
        guard localRange.location <= chunk.text.utf16.count,
              localRange.length <= chunk.text.utf16.count - localRange.location else { return }
        let mapped = (chunk.utf16Range.lowerBound + localRange.location)
            ..< (chunk.utf16Range.lowerBound + localRange.location + localRange.length)
        guard current.lastProgressRange != mapped else { return }

        var updated = current
        updated.lastProgressRange = mapped
        self.current = updated
        // AVSpeechSynthesizer exposes range callbacks as its progress signal.
        // Resetting the per-utterance timer here makes this an idle-stall bound
        // rather than a total-duration cap.
        startWatchdog(for: currentUtterance, requestID: requestID)
        if let handler = updated.progressHandler {
            await handler(mapped)
        }
    }

    private static func watchdogDuration(forUTF16Length length: Int, rate: Float) -> Duration {
        // The watchdog is scoped to one utterance. Completion of each chunk is
        // observable progress and starts a fresh budget, so long responses do
        // not fail because of an arbitrary total-request cap.
        let normalizedRate = max(0.25, Double(rate))
        let estimatedSpeechSeconds = Double(max(0, length))
            * watchdogSecondsPerUTF16Unit
            * (0.52 / normalizedRate)
        return .seconds(min(
            watchdogMaximumSeconds,
            watchdogBaseSeconds + estimatedSpeechSeconds
        ))
    }

    private func handleWatchdogExpiry(for utterance: AVSpeechUtterance, requestID: UInt64) async {
        guard currentRequestID == requestID,
              let currentUtterance,
              currentUtterance === utterance,
              current != nil else { return }
        // Stop first so a synthesizer that is merely late cannot continue
        // producing audio after the request has failed. A rejected stop is
        // not ownership proof; retain the current utterance and retry it at
        // the next close/stop boundary.
        stopping = true
        _ = synthesizer.stopSpeaking(at: .immediate)
        // A successful stop request is not proof that Apple has delivered its
        // terminal callback. Retain the utterance and lease until that callback
        // or an explicit stop boundary proves cleanup, while failing the
        // waiting caller exactly once now.
        failCurrent(with: Self.watchdogFailure)
    }

    private func registerObservers() {
        observers.interruption = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification) == .interruptionBegan else { return }
            Task { @MainActor [weak self] in
                await self?.handleAudioFailure(
                    VoiceLifecycleInterruption(reason: .systemInterruption)
                )
            }
        }
        observers.route = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification, consumer: .output) == .routeChanged else { return }
            Task { @MainActor [weak self] in
                await self?.handleAudioFailure(
                    VoiceLifecycleInterruption(reason: .routeChange)
                )
            }
        }
        observers.background = notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification) == .applicationBackgrounded else { return }
            Task { @MainActor [weak self] in
                await self?.handleAudioFailure(
                    VoiceLifecycleInterruption(reason: .appBackground)
                )
            }
        }
        observers.mediaServicesLost = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard audioNotificationAction(for: notification) == .mediaServicesInvalidated else { return }
            Task { @MainActor [weak self] in
                await self?.handleAudioFailure(
                    VoiceLifecycleInterruption(reason: .mediaServicesReset)
                )
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
                    recreateSynthesizer: true
                )
            }
        }
    }

    private func handleAudioFailure(
        _ error: Error,
        recreateSynthesizer: Bool = false
    ) async {
        stopping = true
        watchdogTask?.cancel()
        watchdogTask = nil

        if recreateSynthesizer {
            // Media-server reset is the one Apple boundary where the old
            // synthesizer is no longer a trustworthy stop authority. Rebuild
            // it unconditionally, invalidate every old utterance, and
            // resolve the active continuation before releasing the lease.
            _ = synthesizer.stopSpeaking(at: .immediate)
            synthesizer.resetAfterMediaServicesReset()
            await terminateAfterAcceptedStop(with: error)
            return
        }

        guard current != nil else {
            // A reset can arrive while idle; the next request must never use
            // an object that was attached to the old media server.
            stopping = false
            return
        }

        // Interruption and route loss invalidate the active request. If
        // AVSpeechSynthesizer rejects the stop, retain the active utterance
        // and lease while failing the caller; close()/stop() retries the
        // boundary before any new request can start.
        if synthesizer.stopSpeaking(at: .immediate) {
            await terminateAfterAcceptedStop(with: error)
        } else {
            failCurrent(with: error)
        }
    }

    /// Completes a terminal failure only after the synthesizer accepted the
    /// stop boundary. The continuation may already have been resolved by a
    /// rejected-stop path; the optional storage makes that resolution exactly
    /// once while retaining the active audio owner until this method runs.
    private func terminateAfterAcceptedStop(with error: Error) async {
        currentUtterance = nil
        currentRequestID = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        let active = current
        current = nil
        let released = await releaseAudioSessionIfIdle()
        if released { stopping = false }
        let terminalError: Error = released ? error : Self.audioSessionReleaseFailure
        active?.continuation?.resume(throwing: terminalError)
    }

    /// Resolves waiting callers while deliberately retaining `current` and its
    /// synthesizer identity. A later accepted stop can then release the lease
    /// without allowing a new utterance to overlap the old one.
    private func failCurrent(with error: Error) {
        current?.continuation?.resume(throwing: error)
        if var active = current {
            active.continuation = nil
            current = active
        }
    }

    private static func selectedVoice(for configuration: SpeechConfiguration) throws -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let catalog: [SpeechVoice]
        if configuration.voiceIdentifier == nil {
            catalog = Self.voiceCatalog(from: voices, locale: configuration.locale)
        } else {
            catalog = voices.map {
                SpeechVoice(
                    id: $0.identifier,
                    name: $0.name,
                    languageIdentifier: $0.language,
                    quality: Self.quality(for: $0)
                )
            }
        }
        let identifier = try Self.selectVoiceID(
            from: catalog,
            locale: configuration.locale,
            preferredQuality: configuration.preferredQuality,
            voiceIdentifier: configuration.voiceIdentifier,
            excludingPersonalVoices: configuration.voiceIdentifier == nil
                ? Set(voices.filter { Self.isPersonalVoice($0) }.map(\.identifier))
                : []
        )
        guard let voice = voices.first(where: { $0.identifier == identifier }) else {
            throw VoiceError.speechVoiceUnavailable(identifier)
        }
        if configuration.voiceIdentifier != nil, Self.isPersonalVoice(voice) {
            // Personal Voice requires an explicit Apple authorization flow that
            // is intentionally outside this dependency-free core. Never
            // trigger or bypass that consent boundary implicitly.
            throw VoiceError.speechVoiceUnavailable(identifier)
        }
        return voice
    }

    /// Returns voices for the requested language, with exact locale matches
    /// before same-language fallbacks. This pure catalog operation is shared
    /// by the runtime path and deterministic tests.
    static func voiceCatalog(from voices: [AVSpeechSynthesisVoice], locale: Locale) -> [SpeechVoice] {
        let catalog = voices.map {
            SpeechVoice(
                id: $0.identifier,
                name: $0.name,
                languageIdentifier: $0.language,
                quality: Self.quality(for: $0)
            )
        }
        return catalog
            .filter { localeMatch($0.languageIdentifier, locale: locale) }
            .sorted { lhs, rhs in
                let lhsRank = localeRank(lhs.languageIdentifier, locale: locale)
                let rhsRank = localeRank(rhs.languageIdentifier, locale: locale)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.quality != rhs.quality { return Self.qualityRank(lhs.quality) > Self.qualityRank(rhs.quality) }
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.id < rhs.id
            }
    }

    private static func quality(for voice: AVSpeechSynthesisVoice) -> SpeechVoiceQuality {
        switch voice.quality {
        case .premium: return .premium
        case .enhanced: return .enhanced
        default: return .compact
        }
    }

    private static func qualityRank(_ quality: SpeechVoiceQuality) -> Int {
        switch quality {
        case .compact: 0
        case .enhanced: 1
        case .premium: 2
        }
    }

    static func selectVoiceID(
        from voices: [SpeechVoice],
        locale: Locale,
        preferredQuality: SpeechVoiceQuality,
        voiceIdentifier: String?,
        excludingPersonalVoices: Set<String> = []
    ) throws -> String {
        if let voiceIdentifier {
            guard let voice = voices.first(where: { $0.id == voiceIdentifier }) else {
                throw VoiceError.speechVoiceUnavailable(voiceIdentifier)
            }
            guard localeMatch(voice.languageIdentifier, locale: locale) else {
                throw VoiceError.invalidSpeechConfiguration("Voice \(voiceIdentifier) does not match locale \(locale.identifier).")
            }
            return voice.id
        }

        let matchingVoices = voices.filter {
            localeMatch($0.languageIdentifier, locale: locale)
                && !excludingPersonalVoices.contains($0.id)
        }
        guard !matchingVoices.isEmpty else {
            throw VoiceError.speechVoiceUnavailable(locale.identifier)
        }
        let ordered = matchingVoices.sorted { lhs, rhs in
            let lhsRank = localeRank(lhs.languageIdentifier, locale: locale)
            let rhsRank = localeRank(rhs.languageIdentifier, locale: locale)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsQuality = qualityPreferenceRank(lhs.quality, preferred: preferredQuality)
            let rhsQuality = qualityPreferenceRank(rhs.quality, preferred: preferredQuality)
            if lhsQuality != rhsQuality { return lhsQuality < rhsQuality }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
        return ordered[0].id
    }

    private static func qualityPreferenceRank(
        _ quality: SpeechVoiceQuality,
        preferred: SpeechVoiceQuality
    ) -> Int {
        switch preferred {
        case .compact:
            switch quality { case .compact: 0; case .enhanced: 1; case .premium: 2 }
        case .enhanced:
            switch quality { case .enhanced: 0; case .premium: 1; case .compact: 2 }
        case .premium:
            switch quality { case .premium: 0; case .enhanced: 1; case .compact: 2 }
        }
    }

    private static func isPersonalVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if #available(iOS 17.0, *) {
            return voice.voiceTraits.contains(.isPersonalVoice)
        }
        return false
    }

    private static func localeMatch(_ voiceIdentifier: String, locale: Locale) -> Bool {
        let requested = localeParts(locale)
        let voice = localeParts(Locale(identifier: voiceIdentifier.replacingOccurrences(of: "_", with: "-")))
        guard !requested.language.isEmpty, requested.language == voice.language else { return false }
        if let requestedScript = requested.script,
           let voiceScript = voice.script,
           requestedScript != voiceScript {
            return false
        }
        return true
    }

    private static func localeRank(_ voiceIdentifier: String, locale: Locale) -> Int {
        let requested = localeParts(locale)
        let voice = localeParts(Locale(identifier: voiceIdentifier.replacingOccurrences(of: "_", with: "-")))
        guard requested.language == voice.language else { return Int.max }
        if requested.canonical == voice.canonical { return 0 }
        if requested.region != nil, requested.region == voice.region { return 1 }
        if requested.script != nil, requested.script == voice.script { return 2 }
        return 3
    }

    private static func localeParts(_ locale: Locale) -> (language: String, script: String?, region: String?, canonical: String) {
        let canonical = locale.identifier(.bcp47)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        return (
            locale.language.languageCode?.identifier.lowercased() ?? "",
            locale.language.script?.identifier.lowercased(),
            locale.region?.identifier.lowercased(),
            canonical
        )
    }

    private func finishCurrent(
        _ result: Result<Void, Error>,
        utteranceID: ObjectIdentifier,
        requestID: UInt64
    ) async {
        guard let pending = current,
              pending.id == requestID,
              let activeUtterance = currentUtterance,
              ObjectIdentifier(activeUtterance) == utteranceID else { return }

        currentUtterance = nil
        currentRequestID = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        switch result {
        case .failure(let error):
            current = nil
            if await releaseAudioSessionIfIdle() {
                stopping = false
            }
            pending.continuation?.resume(throwing: error)
        case .success:
            var updated = pending
            updated.nextChunk += 1
            if updated.nextChunk < updated.chunks.count && !stopping {
                start(updated)
            } else {
                current = nil
                let released = await releaseAudioSessionIfIdle()
                if !released {
                    pending.continuation?.resume(throwing: Self.audioSessionReleaseFailure)
                    return
                }
                stopping = false
                pending.continuation?.resume()
            }
        }
    }

    private func cancelRequest(id: UInt64) async {
        if current?.id == id, let pending = current {
            stopping = true
            watchdogTask?.cancel()
            watchdogTask = nil
            let stopAccepted = synthesizer.stopSpeaking(at: .immediate)
            if stopAccepted {
                current = nil
                currentUtterance = nil
                currentRequestID = nil
                if await releaseAudioSessionIfIdle() {
                    stopping = false
                }
            } else {
                // The cancelled caller is no longer waiting, but retain the
                // active utterance until a later stop/close retry is accepted.
                if var retained = current {
                    retained.continuation = nil
                    current = retained
                }
            }
            pending.continuation?.resume(throwing: VoiceError.cancelled)
            return
        }
    }

    private func releaseAudioSessionIfIdle() async -> Bool {
        guard current == nil else { return true }
        do {
            try await audioSession.exit()
            sessionReleaseFailed = false
            return true
        } catch {
            sessionReleaseFailed = true
            return false
        }
    }

    deinit {
        if let interruption = observers.interruption { notificationCenter.removeObserver(interruption) }
        if let route = observers.route { notificationCenter.removeObserver(route) }
        if let background = observers.background { notificationCenter.removeObserver(background) }
        if let mediaServicesLost = observers.mediaServicesLost { notificationCenter.removeObserver(mediaServicesLost) }
        if let mediaServicesReset = observers.mediaServicesReset { notificationCenter.removeObserver(mediaServicesReset) }
        watchdogTask?.cancel()
    }

}

extension AppleSpeechOutput: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            await self?.handleSpeechProgress(for: utteranceID, localRange: characterRange)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let requestID = self.currentRequestID else { return }
            await self.finishCurrent(.success(()), utteranceID: utteranceID, requestID: requestID)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let requestID = self.currentRequestID else { return }
            await self.finishCurrent(.failure(VoiceError.cancelled), utteranceID: utteranceID, requestID: requestID)
        }
    }
}
