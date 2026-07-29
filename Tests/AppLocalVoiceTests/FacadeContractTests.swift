import Foundation
import XCTest
@testable import AppLocalVoice

/// Tests the injected public facade, not only the internal coordinator. This
/// keeps the drop-in surface's forwarding, event ordering, and no-op rules
/// honest when internal implementation seams evolve.
@MainActor
final class FacadeContractTests: XCTestCase {
    func testEmptyAndWhitespaceSpeechAreObservableNoOps() async throws {
        let input = ControlledSpeechInput()
        let output = ControlledSpeechOutput()
        let voice = AppLocalVoice(input: input, output: output)
        let stream = await voice.events()

        try await voice.speak("")
        try await voice.speak(" \n\t ")

        let starts = await output.starts
        let state = await voice.state
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(state, .idle)

        // The stream remains open and has no speech lifecycle events for
        // either no-op request. A later turn proves it was not terminated.
        try await voice.startListening()
        await voice.cancelListening()
        let events = await collectFacadeEventsThroughListeningFinished(stream)
        XCTAssertFalse(events.contains(.speechStarted))
        XCTAssertFalse(events.contains(.speechFinished))
        XCTAssertFalse(events.contains(.speechCancelled))
        await voice.close()
    }

    func testCapabilitiesAndVoicesForwardThroughThePublicFacade() async throws {
        let locale = Locale(identifier: "vi-VN")
        let capabilities = SpeechCapabilities(
            locale: locale,
            isSupported: true,
            supportsOnDevice: true,
            reason: "fixture"
        )
        let voices = [SpeechVoice(
            id: "com.example.voice",
            name: "Fixture Voice",
            languageIdentifier: "vi-VN",
            quality: .enhanced
        )]
        let input = ForwardingInput(capabilities: capabilities)
        let output = ForwardingOutput(voices: voices)
        let voice = AppLocalVoice(input: input, output: output)

        let returnedCapabilities = await voice.capabilities(for: locale)
        let returnedVoices = await voice.availableVoices(for: locale)
        XCTAssertEqual(returnedCapabilities, capabilities)
        XCTAssertEqual(returnedVoices, voices)
        let forwardedInputLocale = await input.lastLocale
        let forwardedOutputLocale = await output.lastLocale
        XCTAssertEqual(forwardedInputLocale, locale)
        XCTAssertEqual(forwardedOutputLocale, locale)
        await voice.close()
    }

    func testPublicStateSnapshotsExposeActiveListeningAndSpeaking() async throws {
        let input = ControlledSpeechInput()
        let output = ControlledSpeechOutput()
        let voice = AppLocalVoice(input: input, output: output)

        try await voice.startListening()
        let listeningState = await voice.state
        XCTAssertEqual(listeningState, .listening)
        await voice.cancelListening()

        let speech = Task { try await voice.speak("active") }
        await output.waitUntilStarted()
        let speakingState = await voice.state
        XCTAssertEqual(speakingState, .speaking)
        await voice.stopSpeaking()
        _ = try? await speech.value

        let idleState = await voice.state
        XCTAssertEqual(idleState, .idle)
        await voice.close()
    }

    func testStoppingSpeechDuringFacadePreflightPreventsProviderAdmission() async throws {
        let output = PreflightBlockingSpeechOutput()
        let voice = AppLocalVoice(input: ControlledSpeechInput(), output: output)

        let speech = Task { try await voice.speak("must not start") }
        await output.waitUntilPreflightEntered()
        await voice.stopSpeaking()
        await output.releasePreflight()

        do {
            try await speech.value
            XCTFail("speech stopped during preflight must not enter the provider")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let starts = await output.starts
        let state = await voice.state
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(state, .idle)
        await voice.close()
    }

    func testFacadeExposesUnresolvedCleanupAsFailedUntilCloseReconciles() async throws {
        let input = ControlledSpeechInput()
        await input.setCleanupBlocked(true)
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput())

        try await voice.startListening()
        await voice.cancelListening()
        let failedState = await voice.state
        XCTAssertEqual(failedState, .failed)

        await input.setCleanupBlocked(false)
        await voice.close()
        let idleState = await voice.state
        XCTAssertEqual(idleState, .idle)
    }

    func testPublicStateSnapshotExposesFinalizing() async throws {
        let input = BlockingFinalizationInput()
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput())

        try await voice.startListening()
        let finishing = Task { try await voice.finishListening() }
        await input.waitUntilStopEntered()

        let finalizingState = await voice.state
        XCTAssertEqual(finalizingState, .finalizing)
        await input.completeStop()
        let finalText = try await finishing.value
        XCTAssertEqual(finalText, "final text")
        await voice.close()
    }

    func testPublicTTSStartPauseResumeAndStopHaveExactlyOneTerminalEvent() async throws {
        let output = ControlledSpeechOutput()
        let voice = AppLocalVoice(input: ControlledSpeechInput(), output: output)
        let stream = await voice.events()
        let eventsTask = Task { await collectSpeechEvents(stream) }
        let speech = Task { try await voice.speak("hello") }

        await output.waitUntilStarted()
        await voice.pauseSpeaking()
        await voice.resumeSpeaking()
        let pauseCount = await output.pauses
        let resumeCount = await output.resumes
        XCTAssertEqual(pauseCount, 1)
        XCTAssertEqual(resumeCount, 1)

        await voice.stopSpeaking()
        do {
            _ = try await speech.value
            XCTFail("stopped speech must be cancelled")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }

        let events = await eventsTask.value
        let terminals = events.filter { event in
            switch event {
            case .speechFinished, .speechCancelled, .failure: return true
            default: return false
            }
        }
        XCTAssertEqual(terminals, [.speechCancelled])
        await voice.close()
    }

    func testPublicTTSCompletionHasExactlyOneFinishedEvent() async throws {
        let output = ControlledSpeechOutput()
        let voice = AppLocalVoice(input: ControlledSpeechInput(), output: output)
        let stream = await voice.events()
        let eventsTask = Task { await collectSpeechEvents(stream) }
        let speech = Task { try await voice.speak("hello") }

        await output.waitUntilStarted()
        await output.complete(.success(()))
        try await speech.value

        let events = await eventsTask.value
        XCTAssertEqual(
            events.filter { $0 == .speechFinished || $0 == .speechCancelled || isFailure($0) },
            [.speechFinished]
        )
        await voice.close()
    }

    func testPublicTTSFailureHasExactlyOneFailureEvent() async throws {
        let output = ControlledSpeechOutput()
        await output.setFailure(HarnessFailure(stage: .speech, message: "fixture failure"))
        let voice = AppLocalVoice(input: ControlledSpeechInput(), output: output)
        let stream = await voice.events()
        let eventsTask = Task { await collectSpeechEvents(stream) }

        do {
            try await voice.speak("hello")
            XCTFail("expected synthesis failure")
        } catch let error as HarnessFailure {
            XCTAssertEqual(error.message, "fixture failure")
        }

        let events = await eventsTask.value
        let terminals = events.filter { event in
            switch event {
            case .speechFinished, .speechCancelled, .failure: return true
            default: return false
            }
        }
        XCTAssertEqual(terminals.count, 1)
        guard let first = terminals.first, case .failure = first else {
            XCTFail("expected one failure terminal event")
            return
        }
        let state = await voice.state
        XCTAssertEqual(state, .idle)
        await voice.close()
    }

    func testDuplicateFinalUpdatesProduceAtMostOnePublicFinalSnapshot() async throws {
        let input = ControlledSpeechInput()
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput())
        let stream = await voice.events()
        let eventsTask = Task { await collectFacadeEventsThroughListeningFinished(stream) }

        try await voice.startListening()
        let final = TranscriptUpdate(text: "final", isFinal: true)
        await input.send(final)
        await input.send(final)
        _ = try await voice.finishListening()

        let events = await eventsTask.value
        XCTAssertEqual(events.filter { event in
            if case .transcript(let update) = event { return update.isFinal }
            return false
        }.count, 1)
        await voice.close()
    }

    func testEventStreamRemainsUsableAfterClose() async throws {
        let input = ControlledSpeechInput()
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput())
        let stream = await voice.events()

        await voice.close()
        try await voice.startListening()
        let activeState = await voice.state
        XCTAssertEqual(activeState, .listening)
        await voice.cancelListening()

        let events = await collectFacadeEventsThroughListeningFinished(stream)
        XCTAssertTrue(events.contains(.stateChanged(.listening)))
        XCTAssertEqual(events.last, .listeningFinished(.cancelled))
        await voice.close()
    }
}

private func isFailure(_ event: VoiceEvent) -> Bool {
    if case .failure = event { return true }
    return false
}

private func collectFacadeEventsThroughListeningFinished(
    _ stream: AsyncStream<VoiceEvent>
) async -> [VoiceEvent] {
    var events: [VoiceEvent] = []
    for await event in stream {
        events.append(event)
        if case .listeningFinished = event { break }
    }
    return events
}

private func collectSpeechEvents(_ stream: AsyncStream<VoiceEvent>) async -> [VoiceEvent] {
    var events: [VoiceEvent] = []
    for await event in stream {
        events.append(event)
        switch event {
        case .speechFinished, .speechCancelled, .failure:
            return events
        default:
            continue
        }
    }
    return events
}

private actor ForwardingInput: SpeechInput {
    let capabilitiesValue: SpeechCapabilities
    private(set) var lastLocale: Locale?

    init(capabilities: SpeechCapabilities) { self.capabilitiesValue = capabilities }

    func capabilities(for locale: Locale) async -> SpeechCapabilities {
        lastLocale = locale
        return capabilitiesValue
    }

    func requestAuthorization() async -> SpeechAuthorization { .authorized }
    func requestMicrophonePermission() async -> Bool { true }

    func start(configuration: RecognitionConfiguration) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stop() async throws -> String { "" }
    func cancel() async {}
}

private actor ForwardingOutput: SpeechOutput {
    let voices: [SpeechVoice]
    private(set) var lastLocale: Locale?

    init(voices: [SpeechVoice]) { self.voices = voices }

    func availableVoices(for locale: Locale) async -> [SpeechVoice] {
        lastLocale = locale
        return voices
    }

    func speak(_ text: String, configuration: SpeechConfiguration) async throws {}
    func pause() async {}
    func resume() async {}
    func stop() async {}
}

private actor PreflightBlockingSpeechOutput: SpeechOutput {
    private var blockFirstResourceCheck = true
    private var preflightWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var starts = 0

    func availableVoices(for locale: Locale) async -> [SpeechVoice] { [] }

    func speak(_ text: String, configuration: SpeechConfiguration) async throws {
        starts += 1
    }

    func pause() async {}
    func resume() async {}
    func stop() async {}

    func resourcesAreReleased() async -> Bool {
        if blockFirstResourceCheck {
            blockFirstResourceCheck = false
            preflightWaiter?.resume()
            preflightWaiter = nil
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseWaiter = continuation
            }
        }
        return true
    }

    func waitUntilPreflightEntered() async {
        if !blockFirstResourceCheck { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            preflightWaiter = continuation
        }
    }

    func releasePreflight() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor BlockingFinalizationInput: SpeechInput {
    private var stopContinuation: CheckedContinuation<String, Error>?
    private var stopEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var streamContinuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?

    func capabilities(for locale: Locale) async -> SpeechCapabilities {
        SpeechCapabilities(locale: locale, isSupported: true, supportsOnDevice: true)
    }

    func requestAuthorization() async -> SpeechAuthorization { .authorized }
    func requestMicrophonePermission() async -> Bool { true }

    func start(configuration: RecognitionConfiguration) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        AsyncThrowingStream { continuation in
            streamContinuation = continuation
        }
    }

    func stop() async throws -> String {
        for waiter in stopEnteredWaiters { waiter.resume() }
        stopEnteredWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            precondition(stopContinuation == nil)
            stopContinuation = continuation
        }
    }

    func cancel() async {
        streamContinuation?.finish()
        streamContinuation = nil
        stopContinuation?.resume(throwing: VoiceError.cancelled)
        stopContinuation = nil
        for waiter in stopEnteredWaiters { waiter.resume() }
        stopEnteredWaiters.removeAll()
    }

    func waitUntilStopEntered() async {
        if stopContinuation != nil { return }
        await withCheckedContinuation { stopEnteredWaiters.append($0) }
    }

    func completeStop() {
        stopContinuation?.resume(returning: "final text")
        stopContinuation = nil
        streamContinuation?.finish()
        streamContinuation = nil
    }
}
