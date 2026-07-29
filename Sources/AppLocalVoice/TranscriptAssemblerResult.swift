import CoreMedia

/// Provider-neutral transcript data used by the range-aware assembler.
///
/// A result's range is the provider's replacement envelope. Individual
/// segments carry the exact time ranges supplied for their attributed runs;
/// a missing segment range is intentionally preserved as untimed metadata.
struct TranscriptAssemblerResult: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let text: String
        let timeRange: CMTimeRange?

        init(text: String, timeRange: CMTimeRange? = nil) {
            self.text = text
            self.timeRange = timeRange
        }
    }

    let range: CMTimeRange?
    let segments: [Segment]
    let isFinal: Bool

    init(
        range: CMTimeRange? = nil,
        segments: [Segment],
        isFinal: Bool
    ) {
        self.range = range
        self.segments = segments
        self.isFinal = isFinal
    }
}

typealias TranscriptTextSegment = TranscriptAssemblerResult.Segment
