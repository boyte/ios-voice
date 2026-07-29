import XCTest
@testable import AppLocalVoice

@MainActor
final class QueueFacadeIntegrationTests: XCTestCase {
    func testFacadeQueuesReturnedTextAndPublishesCanonicalQueueEvents() async throws {
        let output = ControlledSpeechOutput()
        let voice = AppLocalVoice(
            input: ControlledSpeechInput(),
            output: output
        )
        let stream = await voice.voiceEvents()

        let first = try await voice.enqueueSpeech("first")
        let second = try await voice.enqueueSpeech("second")
        await output.waitUntilStarted()
        let firstSpoken = await output.spoken
        XCTAssertEqual(firstSpoken, ["first"])
        await output.complete(.success(()))
        await output.waitUntilStarted()
        let allSpoken = await output.spoken
        XCTAssertEqual(allSpoken, ["first", "second"])
        await output.complete(.success(()))

        var iterator = stream.makeAsyncIterator()
        var events: [SpeechQueueEvent] = []
        while events.count < 6 {
            guard let event = try await iterator.next() else {
                XCTFail("Canonical stream ended before queue lifecycle completed")
                break
            }
            if case .speechQueue(let queueEvent) = event { events.append(queueEvent) }
        }
        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(events.filter { $0.kind == .accepted }.count, 2)
        XCTAssertEqual(events.filter { $0.kind == .started }.count, 2)
        XCTAssertEqual(events.filter { $0.kind.isTerminal }.count, 2)
        XCTAssertEqual(events.filter { $0.itemID == first.itemID }.last?.kind, .outcome(.finished))
        XCTAssertEqual(events.filter { $0.itemID == second.itemID }.last?.kind, .outcome(.finished))
        XCTAssertTrue(events.map(\.eventOrdinal).isStrictlyIncreasing)
        await voice.close()
    }

    func testCancellingOnePlaybackWaitDoesNotStopPlaybackOrOtherWaiters() async throws {
        let output = ControlledSpeechOutput()
        let voice = AppLocalVoice(input: ControlledSpeechInput(), output: output)
        let acceptance = try await voice.enqueueSpeech("wait independently")
        await output.waitUntilStarted()

        let cancelledWait = Task {
            try await voice.waitForSpeechPlayback(id: acceptance.playbackID)
        }
        let survivingWait = Task {
            try await voice.waitForSpeechPlayback(id: acceptance.playbackID)
        }
        await Task.yield()
        cancelledWait.cancel()
        do {
            _ = try await cancelledWait.value
            XCTFail("Cancelled observer should not receive a playback result")
        } catch is CancellationError {
            // Expected: observation cancellation is local to this caller.
        }

        let outputStops = await output.stops
        let state = await voice.state
        XCTAssertEqual(outputStops, 0)
        XCTAssertEqual(state, .speaking)
        await output.complete(.success(()))
        let result = try await survivingWait.value
        XCTAssertEqual(result.playbackID, acceptance.playbackID)
        XCTAssertEqual(result.outcome, .finished)
        await voice.close()
    }

    func testRuntimeSnapshotReconstructsSuspendedQueueWithoutSpeechText() async throws {
        let configuration = try SpeechQueueConfiguration(
            maximumPendingItemCount: 4,
            initialMode: .suspended
        )
        let voice = AppLocalVoice(
            input: ControlledSpeechInput(),
            output: ControlledSpeechOutput(),
            queueConfiguration: configuration
        )
        let first = try await voice.enqueueSpeech("first", priority: .userInitiated)
        let second = try await voice.enqueueSpeech("second")

        let snapshot = await voice.runtimeSnapshot()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.queue.mode, .suspended)
        XCTAssertNil(snapshot.queue.active)
        XCTAssertEqual(snapshot.queue.pending.map(\.playbackID), [first.playbackID, second.playbackID])
        XCTAssertEqual(snapshot.queue.pending.map(\.priority), [.userInitiated, .normal])
        XCTAssertEqual(snapshot.queue.pending.map(\.textUTF16Length), [5, 6])
        XCTAssertFalse(snapshot.queue.retainedItemIDs.isEmpty)
        await voice.close()
    }

    func testCanonicalStreamBeginsWithCurrentRuntimeSnapshot() async throws {
        let configuration = try SpeechQueueConfiguration(
            maximumPendingItemCount: 4,
            initialMode: .suspended
        )
        let voice = AppLocalVoice(
            input: ControlledSpeechInput(),
            output: ControlledSpeechOutput(),
            queueConfiguration: configuration
        )
        let acceptance = try await voice.enqueueSpeech("snapshot")

        let stream = await voice.voiceEvents()
        var iterator = stream.makeAsyncIterator()
        guard case .snapshot(let snapshot) = try await iterator.next() else {
            return XCTFail("The first canonical event must be a runtime snapshot")
        }
        XCTAssertEqual(snapshot.queue.pending.map(\.playbackID), [acceptance.playbackID])
        XCTAssertEqual(snapshot.queue.mode, .suspended)
        await voice.close()
    }

    func testTerminalPlaybackResultCanBeObservedMoreThanOnce() async throws {
        let output = ControlledSpeechOutput()
        let voice = AppLocalVoice(input: ControlledSpeechInput(), output: output)
        let acceptance = try await voice.enqueueSpeech("observe terminal result")
        await output.waitUntilStarted()
        await output.complete(.success(()))

        let first = try await voice.waitForSpeechPlayback(id: acceptance.playbackID)
        let second = try await voice.waitForSpeechPlayback(id: acceptance.playbackID)
        XCTAssertEqual(first, second)
        await voice.close()
    }

    func testImmediateSpeechHasIdentityAndIsNotRetainedForReplay() async throws {
        let output = ControlledSpeechOutput()
        let voice = AppLocalVoice(input: ControlledSpeechInput(), output: output)
        let acceptance = try await voice.speakImmediately("direct")
        await output.waitUntilStarted()
        await output.complete(.success(()))

        let result = try await voice.waitForSpeechPlayback(id: acceptance.playbackID)
        XCTAssertEqual(result.itemID, acceptance.itemID)
        XCTAssertEqual(result.outcome, .finished)
        do {
            _ = try await voice.replaySpeech(itemID: acceptance.itemID)
            XCTFail("Immediate speech must not enter replay history")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .itemUnavailable(acceptance.itemID))
        }
        await voice.close()
    }

    func testCapabilitySnapshotIsSideEffectFreeAndIncludesQueueFeatures() async throws {
        let output = ControlledSpeechOutput()
        let voice = AppLocalVoice(input: ControlledSpeechInput(), output: output)

        let snapshot = await voice.capabilitySnapshot(for: Locale(identifier: "en_US"))

        XCTAssertEqual(snapshot.recognition.requestedLocale, Locale(identifier: "en_US"))
        XCTAssertEqual(snapshot.microphonePermission, .authorized)
        XCTAssertEqual(snapshot.speechRecognitionPermission, .authorized)
        XCTAssertEqual(snapshot.availability(for: .speechQueue), .available)
        XCTAssertEqual(snapshot.availability(for: .speechPauseResume), .available)
        let spoken = await output.spoken
        let state = await voice.state
        XCTAssertEqual(spoken, [])
        XCTAssertEqual(state, .idle)
        await voice.close()
    }
}

private extension Array where Element == UInt64 {
    var isStrictlyIncreasing: Bool {
        zip(self, dropFirst()).allSatisfy(<)
    }
}
