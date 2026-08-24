import Foundation

/// Splits speech text without breaking Unicode boundaries and prefers natural
/// sentence/word boundaries. It is internal so the Apple provider stays small
/// while the pure behavior remains directly testable.
enum SpeechTextChunker {
    struct Chunk: Sendable, Equatable {
        let text: String
        /// UTF-16 range in the original logical speech request.
        let utf16Range: Range<Int>
    }

    /// Splits `text` so that no chunk exceeds `maximumUTF16Length`, and — when
    /// `maximumSentences` is given — so that no chunk carries more than that
    /// many complete sentences.
    ///
    /// The sentence bound exists for synthesizers whose cost scales with the
    /// length of one utterance: a neural engine builds a compute graph per
    /// chunk, so an unbounded chunk is an unbounded allocation. Apple's
    /// synthesizer has no such cost and passes no sentence bound, which keeps
    /// its behavior exactly as before.
    static func split(
        _ text: String,
        maximumUTF16Length: Int,
        maximumSentences: Int? = nil
    ) -> [String] {
        let sentenceLimit = maximumSentences.map { max(1, $0) }
        guard maximumUTF16Length > 0 else { return text.isEmpty ? [] : [text] }
        // With a sentence bound, text that fits the length budget may still
        // need splitting, so the single-chunk shortcut no longer applies.
        guard sentenceLimit != nil || text.utf16.count > maximumUTF16Length else {
            return text.isEmpty ? [] : [text]
        }
        if text.isEmpty { return [] }

        var chunks: [String] = []
        // The old implementation rescanned the full remaining substring to
        // decide whether another chunk was needed. For a large agent response
        // that made chunking quadratic. Keep one cursor and the best natural
        // boundaries seen in the current chunk instead; the only unavoidable
        // linear work is constructing the returned chunk strings.
        let totalUTF16Length = text.utf16.count
        chunks.reserveCapacity(max(1, (totalUTF16Length + maximumUTF16Length - 1) / maximumUTF16Length))

        var chunkStart = text.startIndex
        var cursor = chunkStart
        var chunkUTF16Length = 0
        var sentenceCount = 0
        var lastSentenceBoundary: String.Index?
        var lastWhitespaceBoundary: String.Index?

        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            let character = text[cursor]
            let characterUTF16Length = character.utf16.count

            if chunkUTF16Length > 0,
               chunkUTF16Length + characterUTF16Length > maximumUTF16Length {
                // Prefer the last sentence terminator that fit. Otherwise
                // break after the last whitespace grapheme. The source
                // separator stays in the preceding chunk exactly as before.
                let boundary = lastSentenceBoundary ?? lastWhitespaceBoundary ?? cursor
                chunks.append(String(text[chunkStart..<boundary]))
                chunkStart = boundary
                cursor = boundary
                chunkUTF16Length = 0
                sentenceCount = 0
                lastSentenceBoundary = nil
                lastWhitespaceBoundary = nil
                continue
            }

            // A single extended grapheme can be wider than the configured
            // limit. Keeping it intact is the only way to preserve Unicode
            // correctness, so it is emitted as one exceptional chunk.
            if chunkUTF16Length == 0, characterUTF16Length > maximumUTF16Length {
                chunks.append(String(text[cursor..<next]))
                chunkStart = next
                cursor = next
                continue
            }

            chunkUTF16Length += characterUTF16Length
            if isSentenceEnd(character, followedBy: next < text.endIndex ? text[next] : nil) {
                lastSentenceBoundary = next
                sentenceCount += 1
                if let sentenceLimit, sentenceCount >= sentenceLimit {
                    chunks.append(String(text[chunkStart..<next]))
                    chunkStart = next
                    cursor = next
                    chunkUTF16Length = 0
                    sentenceCount = 0
                    lastSentenceBoundary = nil
                    lastWhitespaceBoundary = nil
                    continue
                }
            }
            if character.isWhitespace {
                lastWhitespaceBoundary = next
            }
            cursor = next
        }

        if chunkStart < text.endIndex {
            chunks.append(String(text[chunkStart..<text.endIndex]))
        }
        return chunks
    }

    /// Splits text using the same grapheme-safe algorithm while retaining each
    /// chunk's exact location in the original UTF-16 request. The chunks
    /// preserve the source byte-for-byte, so cumulative UTF-16 length is an
    /// identity mapping rather than a duration or character-count estimate.
    static func splitWithUTF16Ranges(
        _ text: String,
        maximumUTF16Length: Int,
        maximumSentences: Int? = nil
    ) -> [Chunk] {
        var offset = 0
        return split(
            text,
            maximumUTF16Length: maximumUTF16Length,
            maximumSentences: maximumSentences
        ).map { chunk in
            let length = chunk.utf16.count
            defer { offset += length }
            return Chunk(text: chunk, utf16Range: offset..<(offset + length))
        }
    }

    /// Whether `character` ends a sentence, given the character that follows.
    ///
    /// Full-width terminators are unambiguous: CJK does not put a space after
    /// them. An ASCII terminator only ends a sentence when something
    /// whitespace-like or nothing at all follows, so `3.5`, `v1.2.1`, and
    /// `example.com` stay whole. That matters more than it used to: a
    /// terminator now forces a chunk break rather than merely being preferred
    /// as one, and splitting a decimal would be audible.
    private static func isSentenceEnd(_ character: Character, followedBy next: Character?) -> Bool {
        if character == "。" || character == "！" || character == "？" { return true }
        guard character == "." || character == "!" || character == "?" else { return false }
        guard let next else { return true }
        return next.isWhitespace
    }
}
