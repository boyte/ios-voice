import XCTest
@testable import AppLocalVoice

@MainActor
final class SpeechQueueEngineTests: XCTestCase {
    func testAcceptanceStartsAtAcceptedAndPlaybackHasOneTerminalOutcome() async throws {
        let engine = SpeechQueueEngine()
        let request = try SpeechItemRequest(text: "hello")
        let acceptance = try await engine.enqueue(request)
        let attemptValue = await engine.nextAttempt()
        let attempt = try XCTUnwrap(attemptValue)
        XCTAssertEqual(attempt.playbackID, acceptance.playbackID)
        let resultValue = await engine.finish(
            playbackID: acceptance.playbackID,
            outcome: .finished
        )
        let result = try XCTUnwrap(resultValue)
        XCTAssertEqual(result.outcome, .finished)
        let duplicate = await engine.finish(playbackID: acceptance.playbackID, outcome: .finished)
        XCTAssertNil(duplicate)
    }

    func testPriorityIsFIFOWithinPriorityAndNeverPreemptsActivePlayback() async throws {
        let engine = SpeechQueueEngine()
        let normal = try SpeechItemRequest(text: "normal", priority: .normal)
        let first = try await engine.enqueue(normal)
        _ = await engine.nextAttempt()
        let queuedNormal = try SpeechItemRequest(text: "queued normal", priority: .normal)
        let urgent = try SpeechItemRequest(text: "urgent", priority: .userInitiated)
        let normalAcceptance = try await engine.enqueue(queuedNormal)
        let urgentAcceptance = try await engine.enqueue(urgent)
        let active = await engine.activeAttempt()
        XCTAssertEqual(active?.playbackID, first.playbackID)
        _ = await engine.finish(playbackID: first.playbackID, outcome: .finished)
        let urgentAttempt = await engine.nextAttempt()
        XCTAssertEqual(urgentAttempt?.playbackID, urgentAcceptance.playbackID)
        _ = await engine.finish(playbackID: urgentAcceptance.playbackID, outcome: .finished)
        let normalAttempt = await engine.nextAttempt()
        XCTAssertEqual(normalAttempt?.playbackID, normalAcceptance.playbackID)
    }

    func testReplacementAndReplayHistoryAreBounded() async throws {
        let configuration = try SpeechQueueConfiguration(
            maximumPendingItemCount: 2,
            maximumReplayHistoryItemCount: 1
        )
        let engine = SpeechQueueEngine(configuration: configuration)
        let first = try await engine.enqueue(try SpeechItemRequest(text: "one"))
        _ = try await engine.enqueue(try SpeechItemRequest(text: "two"))
        _ = try await engine.enqueue(try SpeechItemRequest(text: "three"), policy: .replaceAll)
        let pendingCount = await engine.pendingCount()
        XCTAssertEqual(pendingCount, 1)
        do {
            _ = try await engine.replay(first.itemID)
            XCTFail("Expected replay history eviction")
        } catch {
            XCTAssertEqual(error as? VoiceError, .itemUnavailable(first.itemID))
        }
    }

    func testRejectedReplaceCurrentLeavesActiveAttemptInPlace() async throws {
        let configuration = try SpeechQueueConfiguration(
            maximumPendingItemCount: 1,
            maximumReplayHistoryItemCount: 4,
            overflowPolicy: .rejectNew
        )
        let engine = SpeechQueueEngine(configuration: configuration)
        let active = try await engine.enqueue(try SpeechItemRequest(text: "active"))
        _ = await engine.nextAttempt()
        _ = try await engine.enqueue(try SpeechItemRequest(text: "pending"))

        do {
            _ = try await engine.enqueue(
                try SpeechItemRequest(text: "replacement"),
                policy: .replaceCurrent
            )
            XCTFail("Expected replacement admission to be rejected")
        } catch {
            XCTAssertEqual(
                error as? VoiceError,
                .queueFull(maximumPendingItemCount: 1)
            )
        }
        let remainsCurrent = await engine.isCurrent(active.playbackID)
        let pendingCount = await engine.pendingCount()
        XCTAssertTrue(remainsCurrent)
        XCTAssertEqual(pendingCount, 1)
    }

    func testStopAndClearSuspendsFutureAutoplay() async throws {
        let engine = SpeechQueueEngine()
        _ = try await engine.enqueue(try SpeechItemRequest(text: "before-stop"))
        _ = await engine.stopAndClear()
        _ = try await engine.enqueue(try SpeechItemRequest(text: "after-stop"))
        let suspendedAttempt = await engine.nextAttempt()
        XCTAssertNil(suspendedAttempt)
        let resumeResult = await engine.resume()
        XCTAssertEqual(resumeResult, .applied)
        let resumedAttempt = await engine.nextAttempt()
        XCTAssertNotNil(resumedAttempt)
    }

    func testStopActiveRetainsPendingAndTerminalizesOnlyActive() async throws {
        let engine = SpeechQueueEngine()
        let active = try await engine.enqueue(try SpeechItemRequest(text: "active"))
        let pending = try await engine.enqueue(try SpeechItemRequest(text: "pending"))
        _ = await engine.nextAttempt()

        let results = await engine.stopActive()
        XCTAssertEqual(results.map(\.playbackID), [active.playbackID])
        XCTAssertEqual(results.first?.outcome, .cancelled(.stopped))
        let pendingCountAfterStop = await engine.pendingCount()
        XCTAssertEqual(pendingCountAfterStop, 1)
        let suspendedAttempt = await engine.nextAttempt()
        XCTAssertNil(suspendedAttempt)

        _ = await engine.resume()
        let resumed = await engine.nextAttempt()
        XCTAssertEqual(resumed?.playbackID, pending.playbackID)
    }

    func testClearPendingLeavesActiveAttemptUnchanged() async throws {
        let engine = SpeechQueueEngine()
        let active = try await engine.enqueue(try SpeechItemRequest(text: "active"))
        _ = try await engine.enqueue(try SpeechItemRequest(text: "pending"))
        _ = await engine.nextAttempt()

        let results = await engine.clearPending()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.outcome, .cancelled(.cleared))
        let activeRemains = await engine.isCurrent(active.playbackID)
        let pendingCountAfterClear = await engine.pendingCount()
        XCTAssertTrue(activeRemains)
        XCTAssertEqual(pendingCountAfterClear, 0)
    }
}
