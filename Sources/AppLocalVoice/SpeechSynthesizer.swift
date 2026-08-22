import Foundation

/// A pluggable text-to-speech engine that turns text into audio samples.
///
/// AppLocalVoice owns everything around the engine: sentence chunking, playing
/// the first chunk while the next one is synthesized, the process audio
/// session, interruptions, barge-in, pause/resume, and playback progress. A
/// synthesizer only converts one bounded piece of text into mono Float32 PCM.
///
/// Apple's `AVSpeechSynthesizer` remains the built-in default. Pass a
/// conforming engine to ``AppLocalVoice/init(synthesizer:queueConfiguration:lifecyclePolicy:)``
/// to speak through it instead; every other AppLocalVoice contract is identical
/// for every engine.
///
/// Requirements for conformers:
/// - `synthesize` is called one chunk at a time and must work without a prior
///   `prepare()`; `prepare()` exists so a host can pay model-loading cost early.
/// - Never touch `AVAudioSession`; AppLocalVoice owns it.
/// - A late result after cancellation is discarded by the caller, so an engine
///   whose compute cannot be interrupted should still return as soon as it can.
/// - Never log or retain the text it is given.
public protocol SpeechSynthesizer: Sendable {
    /// Sample rate, in hertz, of the mono Float32 PCM this engine produces.
    var sampleRate: Double { get }

    /// Loads or warms the engine's resources. Idempotent and coalescing: concurrent
    /// callers share one load. Must not acquire the audio session.
    func prepare() async throws

    /// Releases the engine's resources, for example on memory pressure. A later
    /// `synthesize` or `prepare()` reloads them.
    func unload() async

    /// The voices this engine can speak for `locale`. An empty array makes
    /// AppLocalVoice report speech synthesis as unavailable for that locale.
    func availableVoices(for locale: Locale) async -> [SpeechVoice]

    /// Synthesizes one bounded chunk of text. The chunk never exceeds
    /// `configuration.maximumCharactersPerUtterance` UTF-16 code units and is
    /// usually a few sentences.
    func synthesize(_ text: String, configuration: SpeechConfiguration) async throws -> SynthesizedSpeech
}

/// Audio returned by a ``SpeechSynthesizer`` for one chunk of text.
///
/// This is a struct so future fields (for example word timings) can be added
/// without breaking existing engines.
public struct SynthesizedSpeech: Sendable, Equatable {
    /// Mono Float32 samples at the engine's ``SpeechSynthesizer/sampleRate``.
    public var samples: [Float]

    /// Creates synthesized audio from mono Float32 samples.
    public init(samples: [Float]) {
        self.samples = samples
    }
}
