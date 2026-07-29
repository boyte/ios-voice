import XCTest
@testable import AppLocalVoice

@MainActor
final class QueueResourceBudgetTests: XCTestCase {
    func testDefaultsAndUTF16BudgetBounds() throws {
        let defaults = SpeechQueueConfiguration()
        XCTAssertEqual(defaults.maximumPendingTextUTF16Length, 1_048_576)
        XCTAssertEqual(defaults.maximumReplayHistoryTextUTF16Length, 2_097_152)

        let minimum = try SpeechQueueConfiguration(
            maximumPendingItemCount: 1,
            maximumPendingTextUTF16Length: SpeechQueueConfiguration.minimumPendingTextUTF16Length,
            maximumReplayHistoryTextUTF16Length: SpeechQueueConfiguration.minimumReplayHistoryTextUTF16Length
        )
        XCTAssertEqual(minimum.maximumPendingTextUTF16Length, 8_192)
        XCTAssertEqual(minimum.maximumReplayHistoryTextUTF16Length, 8_192)

        let maximum = try SpeechQueueConfiguration(
            maximumPendingItemCount: 128,
            maximumReplayHistoryItemCount: 256,
            maximumPendingTextUTF16Length: SpeechQueueConfiguration.maximumPendingTextUTF16Length,
            maximumReplayHistoryTextUTF16Length: SpeechQueueConfiguration.maximumReplayHistoryTextUTF16Length
        )
        XCTAssertEqual(maximum.maximumPendingTextUTF16Length, 4_194_304)
        XCTAssertEqual(maximum.maximumReplayHistoryTextUTF16Length, 8_388_608)

        XCTAssertThrowsError(try SpeechQueueConfiguration(
            maximumPendingItemCount: 1,
            maximumPendingTextUTF16Length: 8_191
        ))
        XCTAssertThrowsError(try SpeechQueueConfiguration(
            maximumPendingItemCount: 1,
            maximumReplayHistoryTextUTF16Length: 8_388_609
        ))
    }

    func testPendingMixedUTF16ExactBoundaryRejectsAtomically() async throws {
        let configuration = try SpeechQueueConfiguration(
            maximumPendingItemCount: 4,
            maximumReplayHistoryItemCount: 4,
            maximumPendingTextUTF16Length: 8_192,
            maximumReplayHistoryTextUTF16Length: 8_192,
            initialMode: .running
        )
        let engine = SpeechQueueEngine(configuration: configuration)
        let mixed = "a😀中"
        XCTAssertEqual(mixed.utf16.count, 4)

        let first = try await engine.enqueue(
            try SpeechItemRequest(text: String(repeating: mixed, count: 1_024))
        )
        _ = try await engine.enqueue(
            try SpeechItemRequest(text: String(repeating: mixed, count: 1_024))
        )
        let pendingCountBeforeRejection = await engine.pendingCount()
        XCTAssertEqual(pendingCountBeforeRejection, 2)

        do {
            _ = try await engine.enqueue(try SpeechItemRequest(text: "x"))
            XCTFail("Expected aggregate pending text rejection")
        } catch {
            XCTAssertEqual(
                error as? VoiceError,
                .queueTextBudgetExceeded(
                    maximumUTF16Length: configuration.maximumPendingTextUTF16Length
                )
            )
        }

        let pendingCountAfterRejection = await engine.pendingCount()
        XCTAssertEqual(pendingCountAfterRejection, 2)
        let next = await engine.nextAttempt()
        XCTAssertEqual(next?.playbackID, first.playbackID)
    }

    func testPendingTextOverflowDoesNotApplyDropOldestOrReplaceCurrent() async throws {
        let configuration = try SpeechQueueConfiguration(
            maximumPendingItemCount: 1,
            maximumReplayHistoryItemCount: 4,
            maximumPendingTextUTF16Length: 8_192,
            maximumReplayHistoryTextUTF16Length: 8_192,
            overflowPolicy: .dropOldestPending,
            initialMode: .running
        )
        let engine = SpeechQueueEngine(configuration: configuration)
        let active = try await engine.enqueue(try SpeechItemRequest(text: "active"))
        _ = await engine.nextAttempt()
        let pending = try await engine.enqueue(
            try SpeechItemRequest(text: String(repeating: "p", count: 8_192))
        )

        do {
            _ = try await engine.enqueue(
                try SpeechItemRequest(text: String(repeating: "r", count: 8_193)),
                policy: .replaceCurrent
            )
            XCTFail("Expected aggregate pending text rejection")
        } catch {
            XCTAssertEqual(
                error as? VoiceError,
                .queueTextBudgetExceeded(
                    maximumUTF16Length: configuration.maximumPendingTextUTF16Length
                )
            )
        }

        let activeRemains = await engine.isCurrent(active.playbackID)
        let pendingCount = await engine.pendingCount()
        XCTAssertTrue(activeRemains)
        XCTAssertEqual(pendingCount, 1)
        _ = await engine.finish(playbackID: active.playbackID, outcome: .finished)
        let resumed = await engine.nextAttempt()
        XCTAssertEqual(resumed?.playbackID, pending.playbackID)
    }

    func testRejectedReplaceAllLeavesAcceptedPendingWorkUntouched() async throws {
        let configuration = try SpeechQueueConfiguration(
            maximumPendingItemCount: 2,
            maximumReplayHistoryItemCount: 4,
            maximumPendingTextUTF16Length: 8_192,
            maximumReplayHistoryTextUTF16Length: 8_192,
            initialMode: .running
        )
        let engine = SpeechQueueEngine(configuration: configuration)
        let original = try await engine.enqueue(
            try SpeechItemRequest(text: String(repeating: "o", count: 4_096))
        )
        _ = try await engine.enqueue(try SpeechItemRequest(text: "second"))

        do {
            _ = try await engine.enqueue(
                try SpeechItemRequest(text: String(repeating: "r", count: 8_193)),
                policy: .replaceAll
            )
            XCTFail("Expected aggregate pending text rejection")
        } catch {
            XCTAssertEqual(
                error as? VoiceError,
                .queueTextBudgetExceeded(
                    maximumUTF16Length: configuration.maximumPendingTextUTF16Length
                )
            )
        }

        let pendingCount = await engine.pendingCount()
        XCTAssertEqual(pendingCount, 2)
        let next = await engine.nextAttempt()
        XCTAssertEqual(next?.playbackID, original.playbackID)
    }

    func testReplayHistoryEvictsOldestUntilCountAndTextBudgetsHold() async throws {
        let configuration = try SpeechQueueConfiguration(
            maximumPendingItemCount: 4,
            maximumReplayHistoryItemCount: 2,
            maximumPendingTextUTF16Length: 16_384,
            maximumReplayHistoryTextUTF16Length: 8_192,
            initialMode: .suspended
        )
        let engine = SpeechQueueEngine(configuration: configuration)
        let text = String(repeating: "h", count: 4_096)
        let first = try await engine.enqueue(try SpeechItemRequest(text: text))
        let second = try await engine.enqueue(try SpeechItemRequest(text: text))
        _ = try await engine.enqueue(try SpeechItemRequest(text: text))

        do {
            _ = try await engine.replay(first.itemID)
            XCTFail("Expected the oldest item to be evicted")
        } catch {
            XCTAssertEqual(error as? VoiceError, .itemUnavailable(first.itemID))
        }

        let replay = try await engine.replay(second.itemID)
        XCTAssertEqual(replay.itemID, second.itemID)
        let pendingCount = await engine.pendingCount()
        XCTAssertEqual(pendingCount, 4)
    }
}
