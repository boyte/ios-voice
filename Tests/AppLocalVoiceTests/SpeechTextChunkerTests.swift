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

    // MARK: Sentence bound

    /// Counts sentence ends the way the chunker does, independently of it.
    private func sentenceEnds(in text: String) -> Int {
        let characters = Array(text)
        return characters.indices.reduce(into: 0) { total, index in
            let character = characters[index]
            if character == "。" || character == "！" || character == "？" {
                total += 1
                return
            }
            guard character == "." || character == "!" || character == "?" else { return }
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if next == nil || next!.isWhitespace { total += 1 }
        }
    }

    func testSentenceBoundCapsChunksAndPreservesSourceExactly() {
        let source = (1 ... 12).map { "Sentence number \($0) says something." }.joined(separator: " ")
        let chunks = SpeechTextChunker.split(source, maximumUTF16Length: 4000, maximumSentences: 3)

        XCTAssertEqual(chunks.joined(), source)
        XCTAssertTrue(chunks.count >= 4, "12 sentences capped at 3 must produce at least 4 chunks")
        XCTAssertTrue(
            chunks.allSatisfy { sentenceEnds(in: $0) <= 3 },
            "chunks: \(chunks.map { sentenceEnds(in: $0) })"
        )
    }

    func testSentenceBoundStillHonorsTheLengthLimit() {
        // One sentence far longer than the length budget: the sentence bound
        // cannot help, so the length bound must still cut it.
        let source = String(repeating: "word ", count: 200) + "end."
        let chunks = SpeechTextChunker.split(source, maximumUTF16Length: 64, maximumSentences: 3)

        XCTAssertEqual(chunks.joined(), source)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 64 })
    }

    func testSentenceBoundDoesNotBreakDecimalsOrDottedTokens() {
        // A terminator forces a break now rather than merely being preferred,
        // so an intra-token period must not register as a sentence end.
        let source = "Version 3.5 shipped from example.com at 9.30 exactly. Then it stopped."
        let chunks = SpeechTextChunker.split(source, maximumUTF16Length: 4000, maximumSentences: 1)

        XCTAssertEqual(chunks.joined(), source)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.first, "Version 3.5 shipped from example.com at 9.30 exactly.")
        for token in ["3.5", "example.com", "9.30"] {
            XCTAssertTrue(
                chunks.contains { $0.contains(token) },
                "\(token) was split across chunks: \(chunks)"
            )
        }
    }

    func testSentenceBoundHandlesFullWidthTerminatorsWithoutTrailingSpace() {
        let source = "你好世界。これはテストです。三番目の文。四番目の文。"
        let chunks = SpeechTextChunker.split(source, maximumUTF16Length: 4000, maximumSentences: 2)

        XCTAssertEqual(chunks.joined(), source)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { sentenceEnds(in: $0) <= 2 })
    }

    func testSentenceBoundKeepsRangesContiguousAndExact() {
        let source = "First one. Second one! Third one? Fourth 👩🏽‍💻 one. Fifth one."
        let chunks = SpeechTextChunker.splitWithUTF16Ranges(
            source,
            maximumUTF16Length: 4000,
            maximumSentences: 2
        )

        XCTAssertEqual(chunks.map(\.text).joined(), source)
        var expected = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.utf16Range.lowerBound, expected)
            XCTAssertEqual(chunk.utf16Range.count, chunk.text.utf16.count)
            expected = chunk.utf16Range.upperBound
        }
        XCTAssertEqual(expected, source.utf16.count)
    }

    func testOmittingTheSentenceBoundLeavesLengthOnlyBehaviorUnchanged() {
        let source = "One sentence. Two sentences. A final clause"
        XCTAssertEqual(
            SpeechTextChunker.split(source, maximumUTF16Length: 20, maximumSentences: nil),
            SpeechTextChunker.split(source, maximumUTF16Length: 20)
        )
    }
}
