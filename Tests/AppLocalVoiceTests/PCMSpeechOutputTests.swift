import AVFoundation
import UIKit
import XCTest
@testable import AppLocalVoice

@MainActor
final class PCMSpeechOutputTests: XCTestCase {
    private struct Harness {
        let synthesizer: GatedSpeechSynthesizer
        let engine: RecordingPCMPlaybackEngine
        let sessionDriver: PlaybackAudioSessionDriver
        let notifications: PCMOutputNotificationCenter
        let output: PCMSpeechOutput
    }

    private func makeHarness(
        watchdogSleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.never() }
    ) -> Harness {
        let synthesizer = GatedSpeechSynthesizer()
        let engine = RecordingPCMPlaybackEngine()
        let sessionDriver = PlaybackAudioSessionDriver()
        let notifications = PCMOutputNotificationCenter()
        let output = PCMSpeechOutput(
            synthesizer: synthesizer,
            player: PCMPlaybackDriver(audioSession: AudioSessionController(driver: sessionDriver), engine: engine),
            notificationCenter: notifications,
            watchdogSleep: watchdogSleep
        )
        return Harness(synthesizer: synthesizer, engine: engine, sessionDriver: sessionDriver, notifications: notifications, output: output)
    }

    /// Polls on wall-clock time (not yields): the real audio session and the
    /// coordinator's actor hops take measurable time on the simulator.
    private func waitUntil(_ condition: @MainActor () async -> Bool, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: Chunking

    func testChunkingUsesAShortFirstChunkThenSentenceGroupsWithExactRanges() {
        let sentence = "This is a sentence that is long enough to matter. "
        let text = String(repeating: sentence, count: 12).trimmingCharacters(in: .whitespaces)

        let chunks = PCMSpeechOutput.chunk(text, maximumUTF16Length: 4_000)

        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertLessThanOrEqual(chunks[0].text.utf16.count, PCMSpeechOutput.firstChunkMaximumUTF16Length)
        XCTAssertTrue(chunks[0].text.hasSuffix("matter."), "first chunk breaks right after a sentence terminator")
        for chunk in chunks.dropFirst() {
            XCTAssertLessThanOrEqual(chunk.text.utf16.count, PCMSpeechOutput.chunkMaximumUTF16Length)
        }
        // Ranges are contiguous, cover the whole request, and are exact.
        var expectedStart = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.utf16Range.lowerBound, expectedStart)
            XCTAssertEqual(chunk.utf16Range.count, chunk.text.utf16.count)
            let slice = String(text.utf16[
                text.utf16.index(text.utf16.startIndex, offsetBy: chunk.utf16Range.lowerBound)
                    ..< text.utf16.index(text.utf16.startIndex, offsetBy: chunk.utf16Range.upperBound)
            ])
            XCTAssertEqual(slice, chunk.text)
            expectedStart = chunk.utf16Range.upperBound
        }
        XCTAssertEqual(expectedStart, text.utf16.count)
        XCTAssertEqual(chunks.map(\.text).joined(), text)
    }

    func testChunkingRespectsTheHostUtteranceLimitAndKeepsGraphemesWhole() {
        let text = "👩🏽‍💻 codes. 👩🏽‍💻 ships. 👩🏽‍💻 rests."
        let chunks = PCMSpeechOutput.chunk(text, maximumUTF16Length: 128)
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        for chunk in chunks {
            XCTAssertTrue(chunk.text.hasPrefix("👩🏽‍💻") || chunk.text.hasPrefix(" 👩🏽‍💻") || chunk.text.first?.isWhitespace == false)
            XCTAssertEqual(chunk.utf16Range.count, chunk.text.utf16.count)
        }
        let capped = PCMSpeechOutput.chunk(String(repeating: "word ", count: 100), maximumUTF16Length: 128)
        XCTAssertTrue(capped.allSatisfy { $0.text.utf16.count <= 128 })
    }

    // MARK: Lease ordering and prefetch

    func testLeaseIsAcquiredOnlyAfterTheFirstChunkIsSynthesized() async throws {
        let harness = makeHarness()
        await harness.synthesizer.setAutoRelease(false)
        let speech = Task { @MainActor in
            try await harness.output.speak("Hello there.", configuration: .init(locale: Locale(identifier: "en-US")))
        }

        await waitUntil { await harness.synthesizer.requestedTexts.count == 1 }
        XCTAssertTrue(harness.engine.operations.isEmpty, "no engine or lease work before PCM exists")
        XCTAssertEqual(harness.sessionDriver.activationCalls, 0)

        await harness.synthesizer.releaseNext()
        await waitUntil { harness.engine.operations.count >= 3 }
        XCTAssertEqual(harness.engine.operations, [.configure(24_000), .start, .schedule(100)])
        XCTAssertEqual(harness.sessionDriver.activationCalls, 1)

        harness.engine.fireCompletion(at: 0)
        try await speech.value
        XCTAssertEqual(harness.engine.operations.last, .stop)
        XCTAssertEqual(harness.sessionDriver.deactivationCalls, 1)
        let released = await harness.output.resourcesAreReleased()
        XCTAssertTrue(released)
    }

    func testPrefetchesOneChunkAheadAndPublishesProgressOnlyAtCompletedChunkBoundaries() async throws {
        let harness = makeHarness()
        let text = String(repeating: "A short sentence here. ", count: 12).trimmingCharacters(in: .whitespaces)
        let configuration = SpeechConfiguration(locale: Locale(identifier: "en-US"), maximumCharactersPerUtterance: 128)
        let chunks = PCMSpeechOutput.chunk(text, maximumUTF16Length: 128)
        XCTAssertEqual(chunks.count, 3)
        let collector = ProgressRangeCollector()
        await harness.output.setProgressHandler { range in await collector.append(range) }

        let speech = Task { @MainActor in try await harness.output.speak(text, configuration: configuration) }

        // Chunk 0 synthesized, scheduled; chunk 1 prefetched; chunk 2 must wait.
        await waitUntil { await harness.synthesizer.requestedTexts.count == 2 }
        await waitUntil { harness.engine.operations.contains(.schedule(100)) }
        try? await Task.sleep(for: .milliseconds(50))
        let requestedBeforeFirstCompletion = await harness.synthesizer.requestedTexts.count
        XCTAssertEqual(requestedBeforeFirstCompletion, 2, "only current + next are ever in flight")
        let progressBeforeCompletion = await collector.ranges
        XCTAssertTrue(progressBeforeCompletion.isEmpty, "no progress before a chunk has played")

        harness.engine.fireCompletion(at: 0)
        await waitUntil { await collector.ranges.count == 1 }
        await waitUntil { await harness.synthesizer.requestedTexts.count == 3 }
        await waitUntil { harness.engine.operations.filter { $0 == .schedule(100) }.count == 2 }

        harness.engine.fireCompletion(at: 1)
        await waitUntil { harness.engine.operations.filter { $0 == .schedule(100) }.count == 3 }
        harness.engine.fireCompletion(at: 2)
        try await speech.value

        let ranges = await collector.ranges
        XCTAssertEqual(ranges, chunks.map(\.utf16Range))
        XCTAssertEqual(harness.engine.operations.filter { $0 == .schedule(100) }.count, 3)
        let requested = await harness.synthesizer.requestedTexts
        XCTAssertEqual(requested, chunks.map(\.text))
    }

    // MARK: Stop, cancel, pause

    func testStopDuringFirstSynthesisCancelsWithoutEverAcquiringTheLease() async throws {
        let harness = makeHarness()
        await harness.synthesizer.setAutoRelease(false)
        let speech = Task { @MainActor in
            try await harness.output.speak("Hello there.", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await waitUntil { await harness.synthesizer.requestedTexts.count == 1 }

        await harness.output.stop()

        do {
            try await speech.value
            XCTFail("expected cancellation")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let released = await harness.output.resourcesAreReleased()
        XCTAssertTrue(released)
        XCTAssertEqual(harness.sessionDriver.activationCalls, 0)

        // The engine's late result must not start playback.
        await harness.synthesizer.releaseNext()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(harness.engine.operations.isEmpty)
        XCTAssertEqual(harness.sessionDriver.activationCalls, 0)
    }

    func testStopDuringPlaybackStopsTheEngineAndReleasesTheLease() async throws {
        let harness = makeHarness()
        let speech = Task { @MainActor in
            try await harness.output.speak("Hello there.", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await waitUntil { harness.engine.operations.contains(.schedule(100)) }

        await harness.output.stop()

        do {
            try await speech.value
            XCTFail("expected cancellation")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(harness.engine.operations.last, .stop)
        XCTAssertEqual(harness.sessionDriver.deactivationCalls, 1)
        let released = await harness.output.resourcesAreReleased()
        XCTAssertTrue(released)
    }

    func testTaskCancellationDuringPlaybackBehavesLikeStop() async throws {
        let harness = makeHarness()
        let speech = Task { @MainActor in
            try await harness.output.speak("Hello there.", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await waitUntil { harness.engine.operations.contains(.schedule(100)) }

        speech.cancel()

        do {
            try await speech.value
            XCTFail("expected cancellation")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        await waitUntil { await harness.output.resourcesAreReleased() }
        let released = await harness.output.resourcesAreReleased()
        XCTAssertTrue(released)
        XCTAssertEqual(harness.engine.operations.last, .stop)
    }

    func testPauseDuringSynthesisLatchesUntilPlaybackBeginsAndResumeForwards() async throws {
        let harness = makeHarness()
        await harness.synthesizer.setAutoRelease(false)
        let speech = Task { @MainActor in
            try await harness.output.speak("Hello there.", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await waitUntil { await harness.synthesizer.requestedTexts.count == 1 }

        await harness.output.pause()
        XCTAssertTrue(harness.engine.operations.isEmpty)

        await harness.synthesizer.releaseNext()
        await waitUntil { harness.engine.operations.count >= 4 }
        XCTAssertEqual(harness.engine.operations, [.configure(24_000), .start, .pause, .schedule(100)])

        await harness.output.resume()
        XCTAssertEqual(harness.engine.operations.last, .resume)

        harness.engine.fireCompletion(at: 0)
        try await speech.value
    }

    func testSecondRequestWhileActiveIsRejectedAndEmptyTextIsANoOp() async throws {
        let harness = makeHarness()
        try await harness.output.speak("   \n", configuration: .init(locale: Locale(identifier: "en-US")))
        XCTAssertTrue(harness.engine.operations.isEmpty)

        let speech = Task { @MainActor in
            try await harness.output.speak("Hello there.", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await waitUntil { harness.engine.operations.contains(.schedule(100)) }
        do {
            try await harness.output.speak("Second", configuration: .init(locale: Locale(identifier: "en-US")))
            XCTFail("second request must be rejected")
        } catch let error as VoiceError {
            guard case .invalidState = error else { return XCTFail("expected invalidState, got \(error)") }
        }
        harness.engine.fireCompletion(at: 0)
        try await speech.value
    }

    // MARK: Failures

    func testSynthesisWatchdogFailsAStalledEngineWithoutAcquiringTheLease() async throws {
        let harness = makeHarness(watchdogSleep: { _ in })
        await harness.synthesizer.setAutoRelease(false)

        do {
            try await harness.output.speak("Hello there.", configuration: .init(locale: Locale(identifier: "en-US")))
            XCTFail("expected watchdog failure")
        } catch let error as VoiceError {
            XCTAssertEqual(error.category, .speechSynthesisUnavailable)
        }
        XCTAssertTrue(harness.engine.operations.isEmpty)
        XCTAssertEqual(harness.sessionDriver.activationCalls, 0)
        let released = await harness.output.resourcesAreReleased()
        XCTAssertTrue(released)

        // The stalled engine may finish later; nothing may happen.
        await harness.synthesizer.releaseNext()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(harness.engine.operations.isEmpty)
    }

    func testSynthesisFailureFailsTheRequestAndLeavesResourcesReleased() async throws {
        let harness = makeHarness()
        await harness.synthesizer.setFailure(VoiceError.speechVoiceUnavailable("missing"))

        do {
            try await harness.output.speak("Hello there.", configuration: .init(locale: Locale(identifier: "en-US")))
            XCTFail("expected synthesis failure")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .speechVoiceUnavailable("missing"))
        }
        XCTAssertTrue(harness.engine.operations.isEmpty)
        let released = await harness.output.resourcesAreReleased()
        XCTAssertTrue(released)
    }

    func testInterruptionFailsTheActiveRequestWithATypedInterruption() async throws {
        let harness = makeHarness()
        let speech = Task { @MainActor in
            try await harness.output.speak("Hello there.", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await waitUntil { harness.engine.operations.contains(.schedule(100)) }

        harness.notifications.post(Notification(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        ))

        do {
            try await speech.value
            XCTFail("expected interruption")
        } catch let error as VoiceLifecycleInterruption {
            XCTAssertEqual(error.reason, .systemInterruption)
        }
        XCTAssertEqual(harness.engine.operations.last, .stop)
        let released = await harness.output.resourcesAreReleased()
        XCTAssertTrue(released)
    }

    func testBackgroundAndRouteLossFailTheActiveRequest() async throws {
        for (notification, reason) in [
            (Notification(name: UIApplication.didEnterBackgroundNotification), VoiceInterruptionReason.appBackground),
            (Notification(
                name: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
            ), VoiceInterruptionReason.routeChange)
        ] {
            let harness = makeHarness()
            let speech = Task { @MainActor in
                try await harness.output.speak("Hello there.", configuration: .init(locale: Locale(identifier: "en-US")))
            }
            await waitUntil { harness.engine.operations.contains(.schedule(100)) }
            harness.notifications.post(notification)
            do {
                try await speech.value
                XCTFail("expected interruption for \(reason)")
            } catch let error as VoiceLifecycleInterruption {
                XCTAssertEqual(error.reason, reason)
            }
            let released = await harness.output.resourcesAreReleased()
            XCTAssertTrue(released)
        }
    }

    func testMediaServicesResetRebuildsThePlayerEvenWhileIdleAndFailsAnActiveRequest() async throws {
        let harness = makeHarness()
        let reset = Notification(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )

        harness.notifications.post(reset)
        await waitUntil { harness.engine.operations.contains(.rebuild) }
        XCTAssertEqual(harness.engine.operations, [.rebuild])

        let speech = Task { @MainActor in
            try await harness.output.speak("Hello there.", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await waitUntil { harness.engine.operations.contains(.schedule(100)) }
        harness.notifications.post(reset)
        do {
            try await speech.value
            XCTFail("expected interruption")
        } catch let error as VoiceLifecycleInterruption {
            XCTAssertEqual(error.reason, .mediaServicesReset)
        }
        XCTAssertEqual(harness.engine.operations.suffix(2), [.stop, .rebuild])
    }

    func testLeaseReleaseFailureKeepsResourcesOwnedUntilAStopRetrySucceeds() async throws {
        let harness = makeHarness()
        let speech = Task { @MainActor in
            try await harness.output.speak("Hello there.", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await waitUntil { harness.engine.operations.contains(.schedule(100)) }

        harness.sessionDriver.setRestoreFailure(true)
        await harness.output.stop()
        do {
            try await speech.value
            XCTFail("expected failure")
        } catch let error as VoiceError {
            XCTAssertEqual(error.category, .audioSessionUnavailable)
        }
        let blocked = await harness.output.resourcesAreReleased()
        XCTAssertFalse(blocked)

        harness.sessionDriver.setRestoreFailure(false)
        await harness.output.stop()
        let released = await harness.output.resourcesAreReleased()
        XCTAssertTrue(released)
    }

    func testAvailableVoicesForwardsToTheSynthesizer() async {
        let harness = makeHarness()
        let voices = await harness.output.availableVoices(for: Locale(identifier: "en-US"))
        XCTAssertEqual(voices.map(\.id), ["fake"])
    }

    // MARK: Facade

    func testFacadeSpeaksThroughAPluginSynthesizerWithTheStandardPlaybackContract() async throws {
        let synthesizer = GatedSpeechSynthesizer()
        let engine = RecordingPCMPlaybackEngine()
        let voice = AppLocalVoice(
            input: ControlledSpeechInput(),
            makeOutput: { audioSession in
                PCMSpeechOutput(
                    synthesizer: synthesizer,
                    player: PCMPlaybackDriver(audioSession: audioSession, engine: engine),
                    notificationCenter: PCMOutputNotificationCenter()
                )
            }
        )

        let accepted = try await voice.speakImmediately("Hello from a plug-in.")
        await waitUntil { engine.operations.contains(.schedule(100)) }
        engine.fireCompletion(at: 0)
        let result = try await voice.waitForSpeechPlayback(id: accepted.playbackID)

        XCTAssertEqual(result.outcome, .finished)
        let state = await voice.state
        XCTAssertEqual(state, .idle)
        _ = await voice.close()
    }
}

// MARK: - Fixtures

/// A synthesizer whose calls can be held open until the test releases them.
actor GatedSpeechSynthesizer: SpeechSynthesizer {
    nonisolated let sampleRate: Double = 24_000
    private(set) var requestedTexts: [String] = []
    private var autoRelease = true
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var failure: Error?
    var samplesPerCall = 100

    func setAutoRelease(_ value: Bool) { autoRelease = value }
    func setFailure(_ error: Error?) { failure = error }

    func releaseNext() {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume()
    }

    func prepare() async throws {}
    func unload() async {}

    func availableVoices(for locale: Locale) async -> [SpeechVoice] {
        [SpeechVoice(id: "fake", name: "Fake", languageIdentifier: "en-US", quality: .enhanced)]
    }

    func synthesize(_ text: String, configuration: SpeechConfiguration) async throws -> SynthesizedSpeech {
        requestedTexts.append(text)
        if !autoRelease {
            await withCheckedContinuation { gates.append($0) }
        }
        if let failure { throw failure }
        return SynthesizedSpeech(samples: [Float](repeating: 0.1, count: samplesPerCall))
    }
}

private actor ProgressRangeCollector {
    private(set) var ranges: [Range<Int>] = []
    func append(_ range: Range<Int>) { ranges.append(range) }
}

/// SAFETY: the internal lock protects all mutable fixture state.
final class PCMOutputNotificationCenter: @unchecked Sendable, AudioNotificationCenter {
    private let lock = NSLock()
    private var handlers: [NSObject: (Notification.Name?, @Sendable (Notification) -> Void)] = [:]

    func addObserver(
        forName name: Notification.Name?,
        object obj: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        let token = NSObject()
        lock.withLock { handlers[token] = (name, block) }
        return token
    }

    func removeObserver(_ observer: Any) {
        guard let token = observer as? NSObject else { return }
        lock.withLock { _ = handlers.removeValue(forKey: token) }
    }

    func post(_ notification: Notification) {
        let callbacks = lock.withLock {
            handlers.values.filter { $0.0 == notification.name }.map { $0.1 }
        }
        callbacks.forEach { $0(notification) }
    }
}

private extension Task where Success == Never, Failure == Never {
    static func never() async throws {
        try await withCheckedThrowingContinuation { (_: CheckedContinuation<Void, Error>) in }
    }
}
