import Foundation

/// Monotonic time seam used only by stable transcript publication.
protocol StableTranscriptClock: Sendable {
    var now: Duration { get }
    func sleep(for duration: Duration) async throws
}

struct ContinuousStableTranscriptClock: StableTranscriptClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    init() {
        origin = clock.now
    }

    var now: Duration {
        origin.duration(to: clock.now)
    }

    func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

/// Builds immutable UTF-16-ranged chunks from complete provider snapshots.
/// State is actor-confined by `VoiceCoordinator`.
struct StableTranscriptPublisher {
    private struct Boundary {
        let utf16Offset: Int
        let isSentence: Bool
        let isWord: Bool
    }

    private let sessionID: RecognitionSessionID
    private let interval: Duration
    private var latestText = ""
    private var latestUTF16: [UInt16] = []
    private var firstUnchangedAt: [Duration] = []
    private var emittedUTF16: [UInt16] = []
    private var nextSequence: UInt64 = 0
    private var terminalGraphemeWasExtended = false

    init(sessionID: RecognitionSessionID, policy: StableChunkPolicy) {
        self.sessionID = sessionID
        interval = .seconds(policy.intervalSeconds)
    }

    /// Observes a complete snapshot and returns every newly mature chunk.
    mutating func observe(text: String, at now: Duration) throws -> [StableTranscriptChunk] {
        let utf16 = Array(text.utf16)
        guard utf16.starts(with: emittedUTF16) else {
            throw VoiceError.transcriptConsistency
        }

        var unchangedCount = 0
        let comparisonCount = min(latestUTF16.count, utf16.count)
        while unchangedCount < comparisonCount,
              latestUTF16[unchangedCount] == utf16[unchangedCount] {
            unchangedCount += 1
        }

        if utf16 != latestUTF16 {
            terminalGraphemeWasExtended = Self.extendsTerminalGrapheme(
                previous: latestUTF16,
                current: utf16
            )
        }
        if firstUnchangedAt.count > unchangedCount {
            firstUnchangedAt.removeSubrange(unchangedCount...)
        }
        if utf16.count > unchangedCount {
            firstUnchangedAt.append(
                contentsOf: repeatElement(now, count: utf16.count - unchangedCount)
            )
        }
        latestText = text
        latestUTF16 = utf16
        return try drainMaturedChunks(at: now)
    }

    /// Emits all currently mature text using sentence, word, then grapheme
    /// boundary preference.
    mutating func drainMaturedChunks(at now: Duration) throws -> [StableTranscriptChunk] {
        var chunks: [StableTranscriptChunk] = []
        while let endOffset = preferredMatureBoundary(at: now) {
            chunks.append(try emitChunk(endingAt: endOffset))
        }
        return chunks
    }

    /// Delay until the next complete grapheme can mature. `nil` means there
    /// is no unpublished candidate text and therefore no timer is needed.
    func nextMaturityDelay(at now: Duration) -> Duration? {
        let nextBoundary = boundaries().first {
            $0.utf16Offset > emittedUTF16.count && isPublishableBoundary($0)
        }
        guard let nextBoundary, nextBoundary.utf16Offset <= firstUnchangedAt.count else {
            return nil
        }
        let deadline = firstUnchangedAt[nextBoundary.utf16Offset - 1] + interval
        return deadline > now ? deadline - now : .zero
    }

    /// Verifies the immutable prefix and flushes the successful final tail.
    mutating func finalize(text: String) throws -> [StableTranscriptChunk] {
        let finalUTF16 = Array(text.utf16)
        guard finalUTF16.starts(with: emittedUTF16) else {
            throw VoiceError.transcriptConsistency
        }

        latestText = text
        latestUTF16 = finalUTF16
        firstUnchangedAt.removeAll(keepingCapacity: false)

        var chunks: [StableTranscriptChunk] = []
        if finalUTF16.count > emittedUTF16.count {
            chunks.append(try emitChunk(endingAt: finalUTF16.count))
        }
        guard emittedUTF16 == finalUTF16 else {
            throw VoiceError.transcriptConsistency
        }
        return chunks
    }

    private func preferredMatureBoundary(at now: Duration) -> Int? {
        var matureFrontier = emittedUTF16.count
        for index in emittedUTF16.count..<firstUnchangedAt.count {
            guard firstUnchangedAt[index] + interval <= now else { break }
            matureFrontier = index + 1
        }
        guard matureFrontier > emittedUTF16.count else { return nil }

        let candidates = boundaries().filter {
            $0.utf16Offset > emittedUTF16.count &&
                $0.utf16Offset <= matureFrontier &&
                isPublishableBoundary($0)
        }
        guard !candidates.isEmpty else { return nil }
        if let sentence = candidates.last(where: \.isSentence) {
            return sentence.utf16Offset
        }
        if let word = candidates.last(where: \.isWord) {
            return word.utf16Offset
        }
        return candidates.last?.utf16Offset
    }

    private mutating func emitChunk(endingAt endOffset: Int) throws -> StableTranscriptChunk {
        let startOffset = emittedUTF16.count
        guard endOffset > startOffset, endOffset <= latestUTF16.count else {
            throw VoiceError.transcriptConsistency
        }
        let units = Array(latestUTF16[startOffset..<endOffset])
        let text = String(decoding: units, as: UTF16.self)
        guard Array(text.utf16) == units else {
            throw VoiceError.transcriptConsistency
        }
        let range = try TranscriptUTF16Range(location: startOffset, length: units.count)
        let chunk = try StableTranscriptChunk(
            sessionID: sessionID,
            sequence: nextSequence,
            text: text,
            utf16Range: range
        )
        guard nextSequence < .max else {
            throw VoiceError.transcriptConsistency
        }
        nextSequence += 1
        emittedUTF16.append(contentsOf: units)
        return chunk
    }

    private func boundaries() -> [Boundary] {
        let characters = Array(latestText)
        var result: [Boundary] = []
        result.reserveCapacity(characters.count)
        var utf16Offset = 0

        for index in characters.indices {
            let character = characters[index]
            utf16Offset += String(character).utf16.count
            let nextCharacter = characters.index(after: index) < characters.endIndex
                ? characters[characters.index(after: index)]
                : nil
            result.append(Boundary(
                utf16Offset: utf16Offset,
                isSentence: Self.isSentenceEnding(character),
                isWord: nextCharacter == nil ||
                    Self.isWordSeparator(character) ||
                    nextCharacter.map(Self.isWordSeparator) == true
            ))
        }
        return result
    }

    /// A terminal one-grapheme word can still be extended by a later
    /// provider snapshot (for example `e` -> `é` or `👩` -> `👩🏽`). Do not
    /// publish that boundary as immutable text. Longer ordinary words retain
    /// the established maturity behavior; a final authoritative snapshot
    /// always flushes any held tail.
    private func isPublishableBoundary(_ boundary: Boundary) -> Bool {
        guard boundary.utf16Offset == latestUTF16.count,
              let terminalCharacter = latestText.last else {
            return true
        }
        let terminalWord = latestText.split(whereSeparator: { character in
            character.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }
        }).last
        guard terminalWord?.count == 1 else { return true }
        if terminalGraphemeWasExtended { return true }
        return !Self.mayGainGraphemeScalars(terminalCharacter)
    }

    private static func extendsTerminalGrapheme(
        previous: [UInt16],
        current: [UInt16]
    ) -> Bool {
        guard !previous.isEmpty,
              current.count > previous.count,
              current.starts(with: previous) else {
            return false
        }
        let previousCharacters = Array(String(decoding: previous, as: UTF16.self))
        let currentCharacters = Array(String(decoding: current, as: UTF16.self))
        guard previousCharacters.count == currentCharacters.count,
              previousCharacters.dropLast().elementsEqual(currentCharacters.dropLast()),
              previousCharacters.last != currentCharacters.last else {
            return false
        }
        return true
    }

    private static func mayGainGraphemeScalars(_ character: Character) -> Bool {
        let scalars = Array(character.unicodeScalars)
        guard let last = scalars.last else { return false }

        // Combining marks, variation selectors, emoji modifiers, and ZWJ
        // sequences are the provider revisions that most commonly extend a
        // previously observed grapheme. A single non-whitespace scalar is
        // conservatively held as well, covering scalar-to-composed revisions
        // such as `e` -> `é` without splitting the published chunk.
        if CharacterSet.nonBaseCharacters.contains(last) ||
            last.value == 0x200D ||
            (0xFE00...0xFE0F).contains(last.value) ||
            (0x1F3FB...0x1F3FF).contains(last.value) {
            return true
        }
        return scalars.count == 1 &&
            !CharacterSet.whitespacesAndNewlines.contains(last) &&
            !CharacterSet.punctuationCharacters.contains(last)
    }

    private static func isSentenceEnding(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar == "." || scalar == "!" || scalar == "?" ||
                scalar == "\n" || scalar == "\r"
        }
    }

    private static func isWordSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ||
                CharacterSet.punctuationCharacters.contains(scalar)
        }
    }
}
