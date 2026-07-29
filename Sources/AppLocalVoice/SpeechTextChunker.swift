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

    static func split(_ text: String, maximumUTF16Length: Int) -> [String] {
        guard maximumUTF16Length > 0, text.utf16.count > maximumUTF16Length else {
            return text.isEmpty ? [] : [text]
        }

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
            if isSentenceTerminator(character) {
                lastSentenceBoundary = next
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
        maximumUTF16Length: Int
    ) -> [Chunk] {
        var offset = 0
        return split(text, maximumUTF16Length: maximumUTF16Length).map { chunk in
            let length = chunk.utf16.count
            defer { offset += length }
            return Chunk(text: chunk, utf16Range: offset..<(offset + length))
        }
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
            || character == "。" || character == "！" || character == "？"
    }
}
