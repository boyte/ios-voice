import CoreMedia
import Foundation

enum TranscriptAssemblerError: Error, Equatable {
    case textLimitExceeded
}

/// Reconstructs the complete transcript snapshot promised by AppLocalVoice
/// from SpeechTranscriber result fragments.
///
/// Progressive SpeechTranscriber results are range-addressed. A result may
/// replace a volatile phrase instead of containing all text seen so far. The
/// assembler keeps those ranges separate, replaces overlapping fragments, and
/// renders a stable complete snapshot for the host-facing event stream.
struct TranscriptAssembler {
    private static let maximumFragmentCount = 4_096

    private struct Fragment: Equatable {
        let range: CMTimeRange?
        let text: String
        let isFinal: Bool
    }

    private var fragments: [Fragment] = []
    private let maximumUTF16Length: Int

    init(maximumUTF16Length: Int = VoiceTextLimits.maximumUTF16Length) {
        self.maximumUTF16Length = max(1, maximumUTF16Length)
    }

    var text: String {
        render(fragments) ?? ""
    }

    mutating func reset() {
        // A reset is a terminal ownership boundary, not a hot-loop scratch
        // operation. Release retained fragment storage so a large turn cannot
        // permanently raise the provider's baseline memory footprint.
        fragments.removeAll(keepingCapacity: false)
    }

    mutating func consume(
        range: CMTimeRange,
        text: String,
        isFinal: Bool
    ) throws -> TranscriptUpdate {
        let normalizedRange = Self.positiveRangeOrNil(range)
        return try consume(
            TranscriptAssemblerResult(
                range: normalizedRange,
                segments: text.isEmpty
                    ? []
                    : [TranscriptTextSegment(text: text, timeRange: normalizedRange)],
                isFinal: isFinal
            )
        )
    }

    mutating func consume(_ result: TranscriptAssemblerResult) throws -> TranscriptUpdate {
        let normalizedResultRange = result.range.flatMap(Self.positiveRangeOrNil)
        let incomingTextLength = result.segments.reduce(into: 0) { length, segment in
            length += segment.text.utf16.count
        }
        guard incomingTextLength <= maximumUTF16Length else {
            throw TranscriptAssemblerError.textLimitExceeded
        }

        // Build and validate a copy before committing it. A rejected provider
        // result must not leave the assembler in an over-limit state that a
        // later cleanup path could render or retain.
        var updatedFragments = fragments
        if result.segments.isEmpty {
            if let range = normalizedResultRange {
                // An empty timed result is a deletion of the provider-owned
                // range. Stored fragments are already the smallest exact
                // attributed units, so an overlap removes a whole segment;
                // no text offset is estimated from the range's duration.
                updatedFragments.removeAll { existing in
                    guard let existingRange = existing.range else { return false }
                    return Self.rangesOverlap(existingRange, range)
                }
                guard let rendered = render(updatedFragments) else {
                    throw TranscriptAssemblerError.textLimitExceeded
                }
                fragments = updatedFragments
                return TranscriptUpdate(text: rendered, isFinal: result.isFinal)
            }

            // Invalid/untimed empty final is the provider's only complete
            // empty-turn signal. An untimed empty preview carries no deletion
            // address and therefore leaves the current snapshot unchanged.
            if result.isFinal {
                updatedFragments.removeAll(keepingCapacity: false)
                fragments = updatedFragments
                return TranscriptUpdate(text: "", isFinal: true)
            }
                return TranscriptUpdate(text: self.text, isFinal: false)
        }

        // If any attributed run lacks timing, its character position cannot be
        // be recovered safely. Preserve the existing untimed contract by
        // treating the provider result as a complete snapshot instead of
        // guessing where that run belongs in a timed transcript.
        guard result.segments.allSatisfy({ segment in
            segment.timeRange.map { Self.positiveRangeOrNil($0) != nil } ?? false
        }) else {
            let snapshot = result.segments.reduce(into: "") { text, segment in
                text.append(contentsOf: segment.text)
            }
            guard snapshot.utf16.count <= maximumUTF16Length else {
                throw TranscriptAssemblerError.textLimitExceeded
            }
            updatedFragments = [Fragment(range: nil, text: snapshot, isFinal: result.isFinal)]
            fragments = updatedFragments
            return TranscriptUpdate(text: snapshot, isFinal: result.isFinal)
        }

        let timedSegments = result.segments.compactMap { segment -> Fragment? in
            guard !segment.text.isEmpty,
                  let timeRange = segment.timeRange,
                  let normalizedRange = Self.positiveRangeOrNil(timeRange) else {
                return nil
            }
            return Fragment(range: normalizedRange, text: segment.text, isFinal: result.isFinal)
        }

        // Prefer the provider's result range because it describes deletions
        // represented by a gap between attributed runs. A union of segment
        // ranges is the safe fallback for provider-neutral callers that only
        // have per-segment timing.
        let replacementRange = normalizedResultRange ?? Self.enclosingRange(of: timedSegments)
        if let replacementRange {
            // A range-addressed result supersedes every stored segment it
            // touches. This handles partial middle deletion and replacement
            // while preserving fragments that merely touch the boundary.
            updatedFragments.removeAll { existing in
                guard let existingRange = existing.range else { return true }
                return Self.rangesOverlap(existingRange, replacementRange)
            }
        } else if !timedSegments.isEmpty {
            // This branch is unreachable for valid timed segments, but keeps
            // the fallback deterministic if CoreMedia rejects their union.
            updatedFragments = []
        }

        updatedFragments.append(contentsOf: timedSegments)
        updatedFragments.sort { lhs, rhs in
            guard let left = lhs.range, let right = rhs.range else {
                return lhs.range != nil
            }
            if left.start == right.start {
                return left.duration < right.duration
            }
            return left.start < right.start
        }

        guard updatedFragments.count <= Self.maximumFragmentCount else {
            throw TranscriptAssemblerError.textLimitExceeded
        }
        guard let rendered = render(updatedFragments) else {
            throw TranscriptAssemblerError.textLimitExceeded
        }
        fragments = updatedFragments
        return TranscriptUpdate(text: rendered, isFinal: result.isFinal)
    }

    mutating func consumeSnapshot(_ text: String, isFinal: Bool) throws -> TranscriptUpdate {
        guard text.utf16.count <= maximumUTF16Length else {
            throw TranscriptAssemblerError.textLimitExceeded
        }
        fragments = [Fragment(range: nil, text: text, isFinal: isFinal)]
        return TranscriptUpdate(text: text, isFinal: isFinal)
    }

    private static func rangesOverlap(_ lhs: CMTimeRange, _ rhs: CMTimeRange) -> Bool {
        let lhsEnd = lhs.end
        let rhsEnd = rhs.end
        return lhs.start < rhsEnd && rhs.start < lhsEnd
    }

    private static func positiveRangeOrNil(_ range: CMTimeRange) -> CMTimeRange? {
        guard range.isValid, range.duration.isNumeric,
              CMTimeCompare(range.duration, .zero) > 0 else {
            return nil
        }
        return range
    }

    private static func enclosingRange(of fragments: [Fragment]) -> CMTimeRange? {
        guard let first = fragments.first?.range else { return nil }
        var start = first.start
        var end = first.end
        for fragment in fragments.dropFirst() {
            guard let range = fragment.range else { continue }
            if CMTimeCompare(range.start, start) < 0 { start = range.start }
            if CMTimeCompare(range.end, end) > 0 { end = range.end }
        }
        return positiveRangeOrNil(CMTimeRangeFromTimeToTime(start: start, end: end))
    }

    private func render(_ fragments: [Fragment]) -> String? {
        var result = ""
        var resultUTF16Length = 0
        for fragment in fragments {
            let part = fragment.text
            guard !part.isEmpty else { continue }
            guard !result.isEmpty else {
                guard part.utf16.count <= maximumUTF16Length else { return nil }
                result = part
                resultUTF16Length = part.utf16.count
                continue
            }

            // Speech results commonly omit the separator at a range boundary,
            // while some locales include it. Add exactly one only when neither
            // side already supplies whitespace and the next fragment is not
            // punctuation that belongs directly to the previous word.
            guard let resultLast = result.last, let partFirst = part.first else {
                return nil
            }
            let needsSeparator = !resultLast.isWhitespace &&
                !partFirst.isWhitespace &&
                !isLeadingPunctuation(partFirst)
            let separator = needsSeparator ? " " : ""
            let additionalUTF16Length = separator.utf16.count + part.utf16.count
            guard resultUTF16Length <= maximumUTF16Length - additionalUTF16Length else {
                return nil
            }
            if needsSeparator { result.append(" ") }
            result.append(contentsOf: part)
            resultUTF16Length += additionalUTF16Length
        }
        return result
    }

    private func isLeadingPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.punctuationCharacters.contains(scalar) ||
                CharacterSet.symbols.contains(scalar)
        }
    }
}
