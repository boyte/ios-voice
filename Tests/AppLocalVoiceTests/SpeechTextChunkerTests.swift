import XCTest
@testable import AppLocalVoice

final class SpeechTextChunkerTests: XCTestCase {
    func testChunksStayWithinUTF16LimitAndPreserveGraphemes() {
        let source = String(repeating: "👩🏽‍💻café。", count: 200)
        let chunks = SpeechTextChunker.split(source, maximumUTF16Length: 64)

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 64 })
        XCTAssertEqual(chunks.joined(), source)
    }

    func testChunkerPrefersSentenceAndWordBoundaries() {
        let chunks = SpeechTextChunker.split("One sentence. Two sentences. A final clause", maximumUTF16Length: 20)

        XCTAssertEqual(chunks, ["One sentence.", " Two sentences.", " A final clause"])
        XCTAssertEqual(chunks.joined(), "One sentence. Two sentences. A final clause")
    }

    func testChunkerPreservesWhitespaceAndSentenceSeparatorsExactly() {
        let source = "First.\n\n  Second!\tThird?  End"
        let chunks = SpeechTextChunker.split(source, maximumUTF16Length: 10)

        XCTAssertEqual(chunks.joined(), source)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 10 })
        XCTAssertTrue(chunks.contains { $0.hasSuffix(".") })
        XCTAssertTrue(chunks.contains { $0.hasSuffix("!") })
        XCTAssertTrue(chunks.contains { $0.hasSuffix("?") })
    }

    func testChunkerHandlesCJKAndLongUnbrokenText() {
        let cjk = SpeechTextChunker.split("你好世界。これはテストです。", maximumUTF16Length: 8)
        let unbroken = SpeechTextChunker.split(String(repeating: "x", count: 100), maximumUTF16Length: 8)

        XCTAssertEqual(cjk.joined(), "你好世界。これはテストです。")
        XCTAssertEqual(unbroken.joined(), String(repeating: "x", count: 100))
        XCTAssertTrue(unbroken.allSatisfy { $0.utf16.count <= 8 })
    }

    func testRangedChunksMapExactlyToOriginalUTF16ForUnicodeAndWhitespace() {
        let source = "A 👩🏽‍💻 é。\n  你好 world!"
        let chunks = SpeechTextChunker.splitWithUTF16Ranges(source, maximumUTF16Length: 10)

        XCTAssertEqual(chunks.map(\.text).joined(), source)
        XCTAssertEqual(chunks.first?.utf16Range.lowerBound, 0)
        XCTAssertEqual(chunks.last?.utf16Range.upperBound, source.utf16.count)
        for pair in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(pair.0.utf16Range.upperBound, pair.1.utf16Range.lowerBound)
        }
        for chunk in chunks {
            let mapped = (source as NSString).substring(
                with: NSRange(chunk.utf16Range)
            )
            XCTAssertEqual(mapped, chunk.text)
        }
    }

    func testChunkerIsDeterministicAcrossSeededInputs() {
        for seed in 1...100 {
            var random = DeterministicRandom(seed: UInt64(seed))
            let source = String((0..<256).map { _ in ["a", "b", "é", "🙂", "。" ][random.nextInt(5)] })
            let first = SpeechTextChunker.split(source, maximumUTF16Length: 17)
            let second = SpeechTextChunker.split(source, maximumUTF16Length: 17)
            XCTAssertEqual(first, second, "seed \(seed)")
            XCTAssertEqual(first.joined(), source, "seed \(seed)")
        }
    }

    func testRepeatCyclePerformance() {
        measure {
            for _ in 0..<1_000 {
                _ = SpeechTextChunker.split(String(repeating: "hello world. ", count: 20), maximumUTF16Length: 256)
            }
        }
    }
}
