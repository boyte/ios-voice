import AVFoundation
import XCTest
@testable import AppLocalVoice

@MainActor
final class PCMPlaybackDriverTests: XCTestCase {
    private func makeDriver(
        engine: RecordingPCMPlaybackEngine,
        sessionDriver: PlaybackAudioSessionDriver = PlaybackAudioSessionDriver()
    ) -> PCMPlaybackDriver {
        PCMPlaybackDriver(audioSession: AudioSessionController(driver: sessionDriver), engine: engine)
    }

    func testBeginConfiguresAndStartsEngineInOrderAndOwnsResources() async throws {
        let engine = RecordingPCMPlaybackEngine()
        let driver = makeDriver(engine: engine)

        XCTAssertTrue(driver.resourcesAreReleased())
        try await driver.begin(sampleRate: 24_000, lifecyclePolicy: .init())

        XCTAssertEqual(engine.operations, [.configure(24_000), .start])
        XCTAssertFalse(driver.resourcesAreReleased())
    }

    func testBuffersResolveInScheduledOrderAsPlayed() async throws {
        let engine = RecordingPCMPlaybackEngine()
        let driver = makeDriver(engine: engine)
        try await driver.begin(sampleRate: 24_000, lifecyclePolicy: .init())

        let first = try driver.schedule([Float](repeating: 0.25, count: 480))
        let second = try driver.schedule([Float](repeating: -0.25, count: 240))
        XCTAssertEqual(engine.operations.suffix(2), [.schedule(480), .schedule(240)])

        engine.fireCompletion(at: 0)
        let firstOutcome = await driver.outcome(of: first)
        XCTAssertEqual(firstOutcome, .played)

        engine.fireCompletion(at: 1)
        let secondOutcome = await driver.outcome(of: second)
        XCTAssertEqual(secondOutcome, .played)
        XCTAssertFalse(driver.resourcesAreReleased(), "natural completion does not release until stop()")
    }

    func testCompletionBeforeAwaitIsRetainedForTheLaterWaiter() async throws {
        let engine = RecordingPCMPlaybackEngine()
        let driver = makeDriver(engine: engine)
        try await driver.begin(sampleRate: 24_000, lifecyclePolicy: .init())

        let id = try driver.schedule([0.5, 0.5])
        engine.fireCompletion(at: 0)
        await Task.yield()
        await Task.yield()

        let outcome = await driver.outcome(of: id)
        XCTAssertEqual(outcome, .played)
    }

    func testStopResolvesOutstandingBuffersAsStoppedStopsEngineAndReleasesLease() async throws {
        let engine = RecordingPCMPlaybackEngine()
        let sessionDriver = PlaybackAudioSessionDriver()
        let driver = makeDriver(engine: engine, sessionDriver: sessionDriver)
        try await driver.begin(sampleRate: 24_000, lifecyclePolicy: .init())
        let id = try driver.schedule([0.1, 0.2, 0.3])

        let waiter = Task { @MainActor in await driver.outcome(of: id) }
        await Task.yield()
        let released = await driver.stop()

        XCTAssertTrue(released)
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(engine.operations.last, .stop)
        XCTAssertTrue(driver.resourcesAreReleased())
        XCTAssertEqual(sessionDriver.deactivationCalls, 1)
    }

    func testLateCompletionFromAStoppedSessionCannotTouchTheNextSession() async throws {
        let engine = RecordingPCMPlaybackEngine()
        let driver = makeDriver(engine: engine)
        try await driver.begin(sampleRate: 24_000, lifecyclePolicy: .init())
        _ = try driver.schedule([0.1])
        await driver.stop()

        try await driver.begin(sampleRate: 24_000, lifecyclePolicy: .init())
        let next = try driver.schedule([0.2])
        let waiter = Task { @MainActor in await driver.outcome(of: next) }
        await Task.yield()

        // The stopped session's buffer completes late (AVFoundation also fires
        // completions on stop). It must not resolve the new session's buffer.
        engine.fireCompletion(at: 0)
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(waiter.isCancelled)

        engine.fireCompletion(at: 1)
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .played)
    }

    func testSecondBeginWhileActiveIsRejectedAndScheduleRequiresBegin() async throws {
        let engine = RecordingPCMPlaybackEngine()
        let driver = makeDriver(engine: engine)

        XCTAssertThrowsError(try driver.schedule([0.1])) { error in
            guard case .invalidState = error as? VoiceError else {
                return XCTFail("expected invalidState, got \(error)")
            }
        }

        try await driver.begin(sampleRate: 24_000, lifecyclePolicy: .init())
        do {
            try await driver.begin(sampleRate: 24_000, lifecyclePolicy: .init())
            XCTFail("second begin must be rejected")
        } catch let error as VoiceError {
            guard case .invalidState = error else { return XCTFail("expected invalidState, got \(error)") }
        }
        XCTAssertEqual(engine.operations, [.configure(24_000), .start], "rejected begin touches no engine state")
    }

    func testEngineStartFailureReleasesLeaseAndThrows() async {
        let engine = RecordingPCMPlaybackEngine()
        engine.startSucceeds = false
        let sessionDriver = PlaybackAudioSessionDriver()
        let driver = makeDriver(engine: engine, sessionDriver: sessionDriver)

        do {
            try await driver.begin(sampleRate: 24_000, lifecyclePolicy: .init())
            XCTFail("begin must fail when the engine cannot start")
        } catch let error as VoiceError {
            XCTAssertEqual(error.category, .speechSynthesisUnavailable)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(driver.resourcesAreReleased())
        XCTAssertEqual(sessionDriver.deactivationCalls, 1)
        XCTAssertEqual(engine.operations, [.configure(24_000), .start, .stop])
    }

    func testRebuildAfterMediaServicesResetStopsResolvesAndRebuildsEngine() async throws {
        let engine = RecordingPCMPlaybackEngine()
        let driver = makeDriver(engine: engine)
        try await driver.begin(sampleRate: 24_000, lifecyclePolicy: .init())
        let id = try driver.schedule([0.1])
        let waiter = Task { @MainActor in await driver.outcome(of: id) }
        await Task.yield()

        let released = await driver.rebuildAfterMediaServicesReset()

        XCTAssertTrue(released)
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(engine.operations.suffix(2), [.stop, .rebuild])
        XCTAssertTrue(driver.resourcesAreReleased())
    }

    func testPauseAndResumeForwardOnlyWhileActive() async throws {
        let engine = RecordingPCMPlaybackEngine()
        let driver = makeDriver(engine: engine)

        driver.pause()
        driver.resume()
        XCTAssertTrue(engine.operations.isEmpty)

        try await driver.begin(sampleRate: 24_000, lifecyclePolicy: .init())
        driver.pause()
        driver.resume()
        XCTAssertEqual(engine.operations.suffix(2), [.pause, .resume])
    }

    func testLeaseReleaseFailureStaysVisibleUntilAStopRetrySucceeds() async throws {
        let engine = RecordingPCMPlaybackEngine()
        let sessionDriver = PlaybackAudioSessionDriver()
        let driver = makeDriver(engine: engine, sessionDriver: sessionDriver)
        try await driver.begin(sampleRate: 24_000, lifecyclePolicy: .init())

        sessionDriver.setRestoreFailure(true)
        let firstRelease = await driver.stop()
        XCTAssertFalse(firstRelease)
        XCTAssertFalse(driver.resourcesAreReleased())

        sessionDriver.setRestoreFailure(false)
        let retriedRelease = await driver.stop()
        XCTAssertTrue(retriedRelease)
        XCTAssertTrue(driver.resourcesAreReleased())
    }

    func testMakeBufferCopiesMonoFloatSamplesAndRejectsEmptyInput() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0]

        let buffer = try XCTUnwrap(PCMPlaybackDriver.makeBuffer(samples, format: format))
        XCTAssertEqual(buffer.frameLength, 4)
        XCTAssertEqual(buffer.format.sampleRate, 24_000)
        let copied = Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: 4))
        XCTAssertEqual(copied, samples)

        XCTAssertNil(PCMPlaybackDriver.makeBuffer([], format: format))
    }
}

// MARK: - Fixtures

@MainActor
final class RecordingPCMPlaybackEngine: PCMPlaybackEngine {
    enum Operation: Equatable {
        case configure(Double)
        case start
        case schedule(Int)
        case pause
        case resume
        case stop
        case rebuild
    }

    private(set) var operations: [Operation] = []
    private var completions: [@Sendable () -> Void] = []
    var configureSucceeds = true
    var startSucceeds = true

    func configure(format: AVAudioFormat) -> Bool {
        operations.append(.configure(format.sampleRate))
        return configureSucceeds
    }

    func start() -> Bool {
        operations.append(.start)
        return startSucceeds
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) {
        operations.append(.schedule(Int(buffer.frameLength)))
        completions.append(completion)
    }

    func pause() { operations.append(.pause) }

    func resume() -> Bool {
        operations.append(.resume)
        return true
    }

    func stop() { operations.append(.stop) }

    func rebuild() { operations.append(.rebuild) }

    /// Fires the completion of the `index`-th scheduled buffer, in order of
    /// scheduling across the engine's lifetime (AVFoundation may fire late).
    func fireCompletion(at index: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard completions.indices.contains(index) else {
            return XCTFail("no scheduled buffer at index \(index); scheduled: \(completions.count)", file: file, line: line)
        }
        completions[index]()
    }
}

/// SAFETY: the internal lock protects all mutable fixture state. Production
/// protocol calls and direct test inspection use the same ordering domain.
final class PlaybackAudioSessionDriver: @unchecked Sendable, AudioSessionDriver {
    private let lock = NSLock()
    private var recordedActivationCalls = 0
    private var recordedDeactivationCalls = 0
    private var restoreFailure = false
    private var currentSnapshot = AudioSessionSnapshot.empty

    var activationCalls: Int { lock.withLock { recordedActivationCalls } }
    var deactivationCalls: Int { lock.withLock { recordedDeactivationCalls } }

    var isOtherAudioPlaying: Bool { false }

    func configure(for role: AudioSessionRole, externalAudio: ExternalAudioPolicy, isOtherAudioPlaying: Bool) throws {}

    func snapshot() -> AudioSessionSnapshot { lock.withLock { currentSnapshot } }

    func setActive(_ active: Bool) throws {
        lock.withLock {
            if active { recordedActivationCalls += 1 } else { recordedDeactivationCalls += 1 }
        }
    }

    func restore(_ snapshot: AudioSessionSnapshot) throws {
        try lock.withLock {
            if restoreFailure {
                throw VoiceError.audioSessionUnavailable("fixture restore failure")
            }
            currentSnapshot = snapshot
        }
    }

    func setRestoreFailure(_ failed: Bool) {
        lock.withLock { restoreFailure = failed }
    }
}
