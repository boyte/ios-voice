import CoreMedia
import XCTest
@testable import AppLocalVoice

final class TranscriptAssemblerTests: XCTestCase {
    func testPartialMiddleDeletionUsesAttributedSegmentBoundaries() throws {
        var assembler = TranscriptAssembler()
        let alpha = timeRange(start: 0, duration: 1)
        let beta = timeRange(start: 1, duration: 1)
        let gamma = timeRange(start: 2, duration: 1)

        _ = try assembler.consume(TranscriptAssemblerResult(
            range: timeRange(start: 0, duration: 3),
            segments: [
                .init(text: "alpha", timeRange: alpha),
                .init(text: "beta", timeRange: beta),
                .init(text: "gamma", timeRange: gamma)
            ],
            isFinal: false
        ))

        let deletion = try assembler.consume(TranscriptAssemblerResult(
            range: timeRange(start: 0, duration: 3),
            segments: [
                .init(text: "alpha", timeRange: alpha),
                .init(text: "gamma", timeRange: gamma)
            ],
            isFinal: true
        ))

        XCTAssertEqual(deletion.text, "alpha gamma")
        XCTAssertTrue(deletion.isFinal)
    }

    func testPartialOverlapReplacementKeepsUntouchedAttributedSegments() throws {
        var assembler = TranscriptAssembler()
        let alpha = timeRange(start: 0, duration: 1)
        let beta = timeRange(start: 1, duration: 1)
        let gamma = timeRange(start: 2, duration: 1)
        _ = try assembler.consume(TranscriptAssemblerResult(
            range: timeRange(start: 0, duration: 3),
            segments: [
                .init(text: "alpha", timeRange: alpha),
                .init(text: "beta", timeRange: beta),
                .init(text: "gamma", timeRange: gamma)
            ],
            isFinal: false
        ))

        let replacement = try assembler.consume(TranscriptAssemblerResult(
            range: timeRange(start: 1, duration: 2),
            segments: [
                .init(text: "delta", timeRange: beta),
                .init(text: "epsilon", timeRange: gamma)
            ],
            isFinal: true
        ))

        XCTAssertEqual(replacement.text, "alpha delta epsilon")
    }

    func testTouchingRangesDoNotDeleteTheirNeighbors() throws {
        var assembler = TranscriptAssembler()
        let alpha = timeRange(start: 0, duration: 1)
        let beta = timeRange(start: 1, duration: 1)
        let gamma = timeRange(start: 2, duration: 1)
        for (text, range) in [("alpha", alpha), ("beta", beta), ("gamma", gamma)] {
            _ = try assembler.consume(range: range, text: text, isFinal: false)
        }

        let deletion = try assembler.consume(
            range: timeRange(start: 1, duration: 1),
            text: "",
            isFinal: true
        )
        XCTAssertEqual(deletion.text, "alpha gamma")
    }

    func testEmojiRemainsWholeWhenAnAdjacentTimedSegmentIsDeleted() throws {
        var assembler = TranscriptAssembler()
        let left = timeRange(start: 0, duration: 1)
        let emoji = timeRange(start: 1, duration: 1)
        let right = timeRange(start: 2, duration: 1)
        _ = try assembler.consume(TranscriptAssemblerResult(
            range: timeRange(start: 0, duration: 3),
            segments: [
                .init(text: "left", timeRange: left),
                .init(text: "👩🏽", timeRange: emoji),
                .init(text: "right", timeRange: right)
            ],
            isFinal: false
        ))

        let deletion = try assembler.consume(
            range: emoji,
            text: "",
            isFinal: true
        )
        XCTAssertEqual(deletion.text, "left right")
        XCTAssertEqual(deletion.text.utf16.count, "left right".utf16.count)
    }

    func testMissingSegmentTimingFallsBackToAnUntimedCompleteSnapshot() throws {
        var assembler = TranscriptAssembler()
        _ = try assembler.consumeSnapshot("old transcript", isFinal: false)

        let update = try assembler.consume(TranscriptAssemblerResult(
            range: timeRange(start: 0, duration: 2),
            segments: [
                .init(text: "new"),
                .init(text: " snapshot")
            ],
            isFinal: true
        ))

        XCTAssertEqual(update, TranscriptUpdate(text: "new snapshot", isFinal: true))
        XCTAssertEqual(assembler.text, "new snapshot")
    }

    func testRangeUpdatesReplaceOnlyTheVolatilePhrase() throws {
        var assembler = TranscriptAssembler()
        let first = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1_000))
        let second = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 1_000), duration: CMTime(seconds: 1, preferredTimescale: 1_000))

        XCTAssertEqual(try assembler.consume(range: first, text: "hello", isFinal: false).text, "hello")
        XCTAssertEqual(try assembler.consume(range: second, text: "world", isFinal: false).text, "hello world")
        XCTAssertEqual(try assembler.consume(range: first, text: "hi", isFinal: true).text, "hi world")
    }

    func testFullTurnRangeReplacesPriorFragments() throws {
        var assembler = TranscriptAssembler()
        let first = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1_000))
        let second = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 1_000), duration: CMTime(seconds: 1, preferredTimescale: 1_000))
        _ = try assembler.consume(range: first, text: "old", isFinal: false)
        _ = try assembler.consume(range: second, text: "text", isFinal: false)

        let whole = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 1_000))
        XCTAssertEqual(try assembler.consume(range: whole, text: "new text", isFinal: true).text, "new text")
    }

    func testEmptyTimedUpdateDeletesOnlyItsAddressedFragment() throws {
        var assembler = TranscriptAssembler()
        let first = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1_000))
        let second = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 1_000), duration: CMTime(seconds: 1, preferredTimescale: 1_000))
        let third = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 1_000), duration: CMTime(seconds: 1, preferredTimescale: 1_000))

        _ = try assembler.consume(range: first, text: "left", isFinal: false)
        _ = try assembler.consume(range: second, text: "removed", isFinal: false)
        _ = try assembler.consume(range: third, text: "right", isFinal: false)

        let deletion = try assembler.consume(range: second, text: "", isFinal: true)
        XCTAssertEqual(deletion.text, "left right")
        XCTAssertTrue(deletion.isFinal)
        XCTAssertEqual(assembler.text, "left right")
    }

    func testUntimedEmptyFinalClearsAnEmptyTurnAndCompleteTranscript() throws {
        var emptyTurn = TranscriptAssembler()
        let emptyFinal = try emptyTurn.consume(range: .invalid, text: "", isFinal: true)
        XCTAssertEqual(emptyFinal, TranscriptUpdate(text: "", isFinal: true))

        var assembler = TranscriptAssembler()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1_000))
        _ = try assembler.consume(range: range, text: "existing", isFinal: false)

        XCTAssertEqual(
            try assembler.consume(range: .invalid, text: "", isFinal: true),
            TranscriptUpdate(text: "", isFinal: true)
        )
        XCTAssertEqual(assembler.text, "")
    }

    func testUntimedProviderResultIsTreatedAsACompleteSnapshot() throws {
        var assembler = TranscriptAssembler()
        let invalid = CMTimeRange.invalid
        XCTAssertEqual(try assembler.consume(range: invalid, text: "one", isFinal: false).text, "one")
        XCTAssertEqual(try assembler.consume(range: invalid, text: "one two", isFinal: true).text, "one two")
    }

    func testAssemblerFailsClosedBeforeRetainingOverLimitText() throws {
        var assembler = TranscriptAssembler(maximumUTF16Length: 8)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1_000))

        _ = try assembler.consume(range: range, text: "12345678", isFinal: false)
        XCTAssertThrowsError(try assembler.consume(range: range, text: "123456789", isFinal: true)) { error in
            XCTAssertEqual(error as? TranscriptAssemblerError, .textLimitExceeded)
        }
        XCTAssertEqual(assembler.text, "12345678")
    }

    func testStablePublisherHoldsScalarUntilCombiningRevisionIsWhole() throws {
        var publisher = StableTranscriptPublisher(
            sessionID: RecognitionSessionID(),
            policy: try StableChunkPolicy(intervalSeconds: 1)
        )
        XCTAssertTrue(try publisher.observe(text: "e", at: .zero).isEmpty)
        XCTAssertTrue(try publisher.drainMaturedChunks(at: .seconds(1)).isEmpty)

        let composed = "e\u{0301}"
        XCTAssertTrue(try publisher.observe(text: composed, at: .seconds(1)).isEmpty)
        let chunks = try publisher.drainMaturedChunks(at: .seconds(2))
        XCTAssertEqual(chunks.map(\.text), [composed])
        XCTAssertEqual(chunks[0].utf16Range.length, composed.utf16.count)
    }

    func testStablePublisherHoldsEmojiUntilModifierRevisionIsWhole() throws {
        var publisher = StableTranscriptPublisher(
            sessionID: RecognitionSessionID(),
            policy: try StableChunkPolicy(intervalSeconds: 1)
        )
        XCTAssertTrue(try publisher.observe(text: "👩", at: .zero).isEmpty)
        XCTAssertTrue(try publisher.drainMaturedChunks(at: .seconds(1)).isEmpty)

        let modified = "👩🏽"
        XCTAssertTrue(try publisher.observe(text: modified, at: .seconds(1)).isEmpty)
        let chunks = try publisher.drainMaturedChunks(at: .seconds(2))
        XCTAssertEqual(chunks.map(\.text), [modified])
        XCTAssertEqual(chunks[0].utf16Range.length, modified.utf16.count)
    }

    func testStablePublisherKeepsCJKGraphemesAndDuplicateFinalIsIdempotent() throws {
        var publisher = StableTranscriptPublisher(
            sessionID: RecognitionSessionID(),
            policy: try StableChunkPolicy(intervalSeconds: 1)
        )
        XCTAssertTrue(try publisher.observe(text: "東京", at: .zero).isEmpty)
        let cjkChunks = try publisher.drainMaturedChunks(at: .seconds(1))
        XCTAssertEqual(cjkChunks.map(\.text), ["東京"])
        XCTAssertEqual(cjkChunks[0].utf16Range, try TranscriptUTF16Range(location: 0, length: 2))

        var finalPublisher = StableTranscriptPublisher(
            sessionID: RecognitionSessionID(),
            policy: try StableChunkPolicy(intervalSeconds: 1)
        )
        let firstFinal = try finalPublisher.finalize(text: "final")
        let duplicateFinal = try finalPublisher.finalize(text: "final")
        XCTAssertEqual(firstFinal.map(\.text), ["final"])
        XCTAssertTrue(duplicateFinal.isEmpty)
    }

    func testStablePublisherRejectsStaleSnapshotAfterPublishedPrefix() throws {
        var publisher = StableTranscriptPublisher(
            sessionID: RecognitionSessionID(),
            policy: try StableChunkPolicy(intervalSeconds: 1)
        )
        _ = try publisher.finalize(text: "current")

        XCTAssertThrowsError(try publisher.observe(text: "stale", at: .seconds(1))) { error in
            XCTAssertEqual(error as? VoiceError, .transcriptConsistency)
        }
    }

    private func timeRange(start: Double, duration: Double) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1_000),
            duration: CMTime(seconds: duration, preferredTimescale: 1_000)
        )
    }
}
