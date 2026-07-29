import CoreMedia
import Foundation
import XCTest
@testable import AppLocalVoice

final class AppleSpeechTranscriptMapperTests: XCTestCase {
    func testMapsAttributedRunsAndRetainsUTF16EmojiText() {
        var text = AttributedString("alpha 👩🏽 gamma")
        let firstEnd = text.index(text.startIndex, offsetByCharacters: 5)
        let firstRange = text.startIndex..<firstEnd
        // AttributedString.Index offsets by extended grapheme clusters. Keep
        // the leading space with the emoji run; the emoji is one grapheme but
        // four UTF-16 code units.
        let secondStart = firstEnd
        let secondEnd = text.index(secondStart, offsetByCharacters: 2)
        let emojiRange = secondStart..<secondEnd
        let lastStart = secondEnd
        let lastRange = lastStart..<text.endIndex
        let firstTimeRange = timeRange(start: 0, duration: 1)
        let emojiTimeRange = timeRange(start: 1, duration: 1)
        let lastTimeRange = timeRange(start: 2, duration: 1)

        text[firstRange][AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = firstTimeRange
        text[emojiRange][AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = emojiTimeRange
        text[lastRange][AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = lastTimeRange

        let mapped = AppleSpeechTranscriptMapper.map(
            text: text,
            range: timeRange(start: 0, duration: 3),
            isFinal: false
        )

        XCTAssertEqual(mapped.segments.map { $0.text }, ["alpha", " 👩🏽", " gamma"])
        XCTAssertEqual(mapped.segments.map { $0.timeRange }, [firstTimeRange, emojiTimeRange, lastTimeRange])
        XCTAssertEqual(mapped.segments[1].text.utf16.count, 5)
    }

    func testMissingRunAttributeMapsToNilTimeRange() {
        var text = AttributedString("timed missing")
        let timedEnd = text.index(text.startIndex, offsetByCharacters: 5)
        text[text.startIndex..<timedEnd][AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = timeRange(start: 0, duration: 1)

        let mapped = AppleSpeechTranscriptMapper.map(
            text: text,
            range: timeRange(start: 0, duration: 2),
            isFinal: true
        )

        XCTAssertEqual(mapped.segments.count, 2)
        XCTAssertNotNil(mapped.segments[0].timeRange)
        XCTAssertNil(mapped.segments[1].timeRange)
        XCTAssertEqual(mapped.segments.map { $0.text }, ["timed", " missing"])
    }

    func testEmptyAttributedTextKeepsResultRangeForDeletion() {
        let mapped = AppleSpeechTranscriptMapper.map(
            text: AttributedString(),
            range: timeRange(start: 1, duration: 1),
            isFinal: true
        )

        XCTAssertTrue(mapped.segments.isEmpty)
        XCTAssertEqual(mapped.range, timeRange(start: 1, duration: 1))
    }

    private func timeRange(start: Double, duration: Double) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1_000),
            duration: CMTime(seconds: duration, preferredTimescale: 1_000)
        )
    }
}
