import Foundation
@testable import AppLocalVoice

/// A small, actor-isolated ledger used by every fake. A test can assert that
/// resources acquired before a failure are released exactly once.
actor ResourceLedger {
    enum Resource: Hashable, Sendable {
        case microphone
        case audioSession
        case analyzer
        case converter
        case speech
    }

    private var held: Set<Resource> = []
    private(set) var acquisitions: [Resource] = []
    private(set) var releases: [Resource] = []

    func acquire(_ resource: Resource) {
        precondition(held.insert(resource).inserted, "double acquisition: \(resource)")
        acquisitions.append(resource)
    }

    func release(_ resource: Resource) {
        precondition(held.remove(resource) != nil, "release without acquisition: \(resource)")
        releases.append(resource)
    }

    func isBalanced() -> Bool { held.isEmpty }
    func count(_ resource: Resource) -> (acquired: Int, released: Int) {
        (acquisitions.filter { $0 == resource }.count, releases.filter { $0 == resource }.count)
    }
}

enum HarnessStage: Hashable, Sendable {
    case microphonePermission
    case speechAuthorization
    case capability
    case model
    case sessionActivation
    case hostAudioCoexistence
    case analyzer
    case converter
    case engineStart
    case interruption
    case routeChange
    case finalization
    case speech
}

struct HarnessFailure: Error, Sendable, Equatable {
    let stage: HarnessStage
    let message: String
}

/// Controlled input models the whole capture pipeline behind SpeechInput. The
/// `stage` knob lets tests fail at a named boundary while the ledger verifies
/// cleanup. `retainedContinuations` deliberately allows stale callbacks after
/// cancellation.
actor ControlledSpeechInput: SpeechInput {
    let ledger: ResourceLedger
    var capabilitiesValue = SpeechCapabilities(locale: .current, isSupported: true, supportsOnDevice: true)
    var microphonePermission = true
    var authorization: SpeechAuthorization = .authorized
    var failure: HarnessFailure?
    var latestText = ""
    var cleanupBlocked = false
    private var startBlocked = false
    private var startEntered = false
    private var startRelease: CheckedContinuation<Void, Never>?
    private var startEntryWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var starts = 0
    private(set) var lastConfiguration: RecognitionConfiguration?
    private(set) var stops = 0
    private(set) var cancels = 0
    private(set) var isActive = false
    private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private var preparationPhases: [RecognitionPreparationPhase] = []
    private var preparationInstalledModel = false
    private var preparationBlocked = false
    private var preparationEntered = false
    private var preparationRelease: CheckedContinuation<Void, Never>?
    private var preparationEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var retainedContinuations: [AsyncThrowingStream<TranscriptUpdate, Error>.Continuation] = []

    init(ledger: ResourceLedger = ResourceLedger()) { self.ledger = ledger }

    func setCleanupBlocked(_ blocked: Bool) { cleanupBlocked = blocked }

    func setFailure(_ value: HarnessFailure?) { failure = value }

    func setPreparation(
        phases: [RecognitionPreparationPhase],
        installedModel: Bool
    ) {
        preparationPhases = phases
        preparationInstalledModel = installedModel
    }

    func setPreparationBlocked(_ blocked: Bool) {
        preparationBlocked = blocked
        if !blocked {
            preparationRelease?.resume()
            preparationRelease = nil
        }
    }

    func waitForPreparationEntry() async {
        if preparationEntered { return }
        await withCheckedContinuation { preparationEntryWaiters.append($0) }
    }

    func setStartBlocked(_ blocked: Bool) {
        startBlocked = blocked
        if !blocked {
            startRelease?.resume()
            startRelease = nil
        }
    }

    func waitForStartEntry() async {
        if startEntered { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startEntryWaiters.append(continuation)
        }
    }

    func capabilities(for locale: Locale) async -> SpeechCapabilities {
        if failure?.stage == .capability { return SpeechCapabilities(locale: locale, isSupported: false, supportsOnDevice: false) }
        return capabilitiesValue
    }

    func requestAuthorization() async -> SpeechAuthorization {
        failure?.stage == .speechAuthorization ? .denied : authorization
    }

    func requestMicrophonePermission() async -> Bool {
        failure?.stage == .microphonePermission ? false : microphonePermission
    }

    func prepareRecognition(
        for locale: Locale,
        policy: SpeechModelPolicy,
        progress: RecognitionPreparationProgressHandler?
    ) async throws -> Bool {
        _ = locale
        _ = policy
        if preparationBlocked {
            preparationEntered = true
            let waiters = preparationEntryWaiters
            preparationEntryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { preparationRelease = $0 }
        }
        for phase in preparationPhases {
            await progress?(phase)
        }
        return preparationInstalledModel
    }

    func start(configuration: RecognitionConfiguration) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        starts += 1
        lastConfiguration = configuration
        if startBlocked {
            startEntered = true
            let waiters = startEntryWaiters
            startEntryWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                startRelease = continuation
            }
        }
        if let failure, [.model, .analyzer, .converter, .engineStart].contains(failure.stage) {
            throw failure
        }
        if failure?.stage == .hostAudioCoexistence {
            throw VoiceError.audioSessionUnavailable("Host audio is active.")
        }
        isActive = true
        await ledger.acquire(.microphone)
        if let failure, failure.stage == .sessionActivation {
            await releaseCapture()
            throw failure
        }

        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            self.retainedContinuations.append(continuation)
            // Keep enough old continuations to exercise stale-callback tests
            // without making the fake itself an unbounded-memory fixture.
            if retainedContinuations.count > 8 {
                retainedContinuations.removeFirst(retainedContinuations.count - 8)
            }
        }
    }

    func stop() async throws -> String {
        stops += 1
        if let failure, failure.stage == .finalization { throw failure }
        await releaseCapture()
        continuation?.finish()
        continuation = nil
        return latestText
    }

    func cancel() async {
        guard isActive else { return }
        cancels += 1
        await releaseCapture()
        continuation?.finish()
        continuation = nil
    }

    func resourcesAreReleased() async -> Bool {
        !isActive && !cleanupBlocked
    }

    func send(_ update: TranscriptUpdate) {
        latestText = update.text
        continuation?.yield(update)
    }

    func sendStale(_ update: TranscriptUpdate) {
        latestText = update.text
        for continuation in retainedContinuations { continuation.yield(update) }
    }

    func failStream(_ error: Error = HarnessFailure(stage: .interruption, message: "interrupted")) {
        continuation?.finish(throwing: error)
        continuation = nil
    }

    private func releaseCapture() async {
        guard isActive else { return }
        isActive = false
        await ledger.release(.microphone)
    }
}

/// Controlled output supports blocking speech and deterministic stop. It also
/// protects its continuation against double completion, which catches a class
/// of delegate/cancellation races common with AVSpeechSynthesizer.
actor ControlledSpeechOutput: SpeechOutput {
    let ledger: ResourceLedger
    var failure: HarnessFailure?
    private(set) var spoken: [String] = []
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var pauses = 0
    private(set) var resumes = 0
    private var pending: CheckedContinuation<Void, Error>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    init(ledger: ResourceLedger = ResourceLedger()) { self.ledger = ledger }

    func availableVoices(for locale: Locale) async -> [SpeechVoice] { [] }

    func speak(_ text: String, configuration: SpeechConfiguration) async throws {
        starts += 1
        spoken.append(text)
        if let failure, failure.stage == .speech { throw failure }
        await ledger.acquire(.speech)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    precondition(pending == nil, "double speech completion registration")
                    pending = continuation
                    for waiter in startedWaiters { waiter.resume() }
                    startedWaiters.removeAll()
                }
            } onCancel: {
                Task { await self.complete(.failure(VoiceError.cancelled)) }
            }
        } catch {
            await releaseSpeech()
            throw error
        }
        await releaseSpeech()
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func complete(_ result: Result<Void, Error>) {
        guard let pending else { return }
        self.pending = nil
        switch result {
        case .success: pending.resume()
        case .failure(let error): pending.resume(throwing: error)
        }
    }

    func pause() async { pauses += 1 }
    func resume() async { resumes += 1 }

    func stop() async {
        stops += 1
        complete(.failure(VoiceError.cancelled))
    }

    private func releaseSpeech() async {
        let counts = await ledger.count(.speech)
        if counts.acquired > counts.released { await ledger.release(.speech) }
    }
}

struct DeterministicRandom: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545F4914F6CDD1D
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }
}
