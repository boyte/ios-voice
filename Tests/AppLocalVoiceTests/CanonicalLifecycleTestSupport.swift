import Foundation
import XCTest
@testable import AppLocalVoice

// Test-only conveniences over the canonical session and playback APIs.
//
// Every helper here is expressible by a host: it uses `startSession`,
// `endSession`/`finishSession`, `cancelSession`, `speakImmediately`,
// `waitForSpeechPlayback`, `runtimeSnapshot`, and `voiceEvents`. There is no
// second lifecycle API in production for tests to lean on.

extension VoiceCoordinator {
    /// Admits a session and waits until the provider is listening. A startup
    /// failure is rethrown exactly as a host observes it through
    /// `endSession(id:)` on the accepted session.
    @discardableResult
    func startTurn(
        configuration: RecognitionConfiguration = .init(),
        session: RecognitionSessionConfiguration? = nil
    ) async throws -> RecognitionSessionID {
        let sessionConfiguration = session ?? RecognitionSessionConfiguration(
            recognition: configuration,
            publicationPolicy: .previewAndFinal
        )
        let acceptance = try await startSession(configuration: sessionConfiguration)
        try await awaitTurnStarted(acceptance.sessionID)
        return acceptance.sessionID
    }

    /// Waits for an accepted session to reach `.listening`, or rethrows its
    /// recorded terminal failure if startup ended the session first.
    func awaitTurnStarted(_ id: RecognitionSessionID) async throws {
        while true {
            let snapshot = await runtimeSnapshot()
            if let recognition = snapshot.recognition, recognition.sessionID == id {
                if recognition.state != .preparing { return }
            } else {
                // The session ended before listening. `endSession` returns the
                // recorded terminal outcome: it rethrows a typed startup
                // failure and returns normally for a completed session.
                _ = try await endSession(id: id)
                return
            }
            await Task.yield()
        }
    }

    /// Identity of the active recognition session, if any.
    func activeTurnID() async -> RecognitionSessionID? {
        await runtimeSnapshot().recognition?.sessionID
    }

    /// Finalizes the active listening session and returns its text.
    func finishTurn() async throws -> String {
        let snapshot = await runtimeSnapshot()
        guard let id = snapshot.recognition?.sessionID, snapshot.state == .listening else {
            throw VoiceError.invalidState("Voice input is not active.")
        }
        return try await endSession(id: id).text
    }

    /// Cancels the active recognition session, if any.
    func cancelTurn() async {
        guard let id = await activeTurnID() else { return }
        await cancelSession(id: id)
    }

    /// Speaks immediately and waits for the terminal playback result, throwing
    /// for failure, interruption, and cancellation the way a host sees them.
    func speakNow(_ text: String, configuration: SpeechConfiguration = .init()) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let acceptance = try await speakImmediately(text, configuration: configuration)
        try await awaitPlayback(acceptance.playbackID)
    }

    /// Waits for a playback result and maps non-finished outcomes to errors.
    func awaitPlayback(_ playbackID: SpeechPlaybackID) async throws {
        let result = try await waitForSpeechPlayback(playbackID)
        switch result.outcome {
        case .finished:
            return
        case .cancelled, .skipped:
            throw VoiceError.cancelled
        case .interrupted:
            throw VoiceError.interrupted("Speech playback was interrupted.")
        case .failed:
            // `waitForSpeechPlayback` already rethrows the provider error for
            // failed outcomes; this arm is a defensive fallback.
            throw VoiceError.underlying("Speech playback failed.")
        }
    }
}

extension AppLocalVoice {
    /// Current serialized lifecycle state, read through the public snapshot.
    var state: VoiceState {
        get async { await runtimeSnapshot().state }
    }

    /// Stops active immediate playback. Hosts have no direct control for
    /// immediate playback beyond `close()`; this reaches the coordinator so
    /// admission-boundary tests can exercise the stop path.
    func stopSpeaking() async { _ = await coordinator.stopSpeaking() }

    /// Facade-level turn helpers route through the facade's own public
    /// entry points so diagnostics wiring is exercised exactly as a host does.
    @discardableResult
    func startTurn(
        configuration: RecognitionConfiguration = .init(),
        session: RecognitionSessionConfiguration? = nil
    ) async throws -> RecognitionSessionID {
        let sessionConfiguration = session ?? RecognitionSessionConfiguration(
            recognition: configuration,
            publicationPolicy: .previewAndFinal
        )
        let acceptance = try await startSession(configuration: sessionConfiguration)
        try await coordinator.awaitTurnStarted(acceptance.sessionID)
        return acceptance.sessionID
    }

    func finishTurn() async throws -> String {
        let snapshot = await runtimeSnapshot()
        guard let id = snapshot.recognition?.sessionID, snapshot.state == .listening else {
            throw VoiceError.invalidState("Voice input is not active.")
        }
        return try await finishSession(id: id).text
    }

    func cancelTurn() async {
        guard let id = await runtimeSnapshot().recognition?.sessionID else { return }
        await cancelSession(id: id)
    }

    func speakNow(_ text: String, configuration: SpeechConfiguration = .init()) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let acceptance = try await speakImmediately(text, configuration: configuration)
        try await awaitPlayback(acceptance.playbackID)
    }

    func awaitPlayback(_ playbackID: SpeechPlaybackID) async throws {
        try await coordinator.awaitPlayback(playbackID)
    }
}

// MARK: - Canonical stream helpers

/// Collects recognition event kinds for one session through its terminal
/// outcome. Snapshot, speech, and recovery events are ignored.
func collectRecognitionKinds(
    _ stream: VoiceEventStream,
    sessionID: RecognitionSessionID? = nil
) async throws -> [RecognitionEventKind] {
    var kinds: [RecognitionEventKind] = []
    for try await event in stream {
        guard case .recognition(let recognition) = event else { continue }
        if let sessionID, recognition.sessionID != sessionID { continue }
        kinds.append(recognition.kind)
        if recognition.kind.isTerminal { break }
    }
    return kinds
}

/// Collects speech-queue event kinds for one playback through its outcome.
func collectSpeechKinds(
    _ stream: VoiceEventStream,
    playbackID: SpeechPlaybackID? = nil
) async throws -> [SpeechQueueEventKind] {
    var kinds: [SpeechQueueEventKind] = []
    for try await event in stream {
        guard case .speechQueue(let speech) = event else { continue }
        if let playbackID, speech.playbackID != playbackID { continue }
        kinds.append(speech.kind)
        if speech.kind.isTerminal { break }
    }
    return kinds
}

/// Collects every canonical event until the predicate matches (inclusive).
func collectEvents(
    _ stream: VoiceEventStream,
    until isLast: @escaping @Sendable (VoiceEventStreamEvent) -> Bool
) async throws -> [VoiceEventStreamEvent] {
    var events: [VoiceEventStreamEvent] = []
    for try await event in stream {
        events.append(event)
        if isLast(event) { break }
    }
    return events
}

/// Polls the coordinator until it reports the expected state or the bound
/// expires; the caller asserts the state afterwards.
func waitForState(
    _ expected: VoiceState,
    coordinator: VoiceCoordinator,
    timeout: Duration = .seconds(2)
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await coordinator.state != expected, clock.now < deadline {
        await Task.yield()
    }
}

func waitForState(
    _ expected: VoiceState,
    voice: AppLocalVoice,
    timeout: Duration = .seconds(2)
) async {
    await waitForState(expected, coordinator: voice.coordinator, timeout: timeout)
}

extension RecognitionEventKind {
    var isPreview: Bool {
        if case .transcript(.preview) = self { return true }
        return false
    }
    var isFinalTranscript: Bool {
        if case .transcript(.finalTranscript) = self { return true }
        return false
    }
    var outcome: RecognitionOutcome? {
        if case .outcome(let outcome) = self { return outcome }
        return nil
    }
}

extension SpeechQueueEventKind {
    var outcome: SpeechPlaybackOutcome? {
        if case .outcome(let outcome) = self { return outcome }
        return nil
    }
}
