// AppLocalVoiceKokoro — Kokoro-82M (MLX) plug-in for AppLocalVoice.
//
// This module builds only when the package trait `Kokoro` is enabled by the
// consumer, because its dependencies (kokoro-ios, MisakiSwift, mlx-swift) run
// on Apple GPUs only: no iOS Simulator, and only Xcode can build MLX's Metal
// shaders. With the trait off this file compiles to an empty module and the
// core package stays dependency-free.
#if Kokoro
import AppLocalVoice
import Foundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

/// Where the Kokoro model and voice data live in the host app.
///
/// The host ships these files (they are not part of the package): the
/// Kokoro-82M weights as `kokoro-v1_0.safetensors`, and an `.npz` archive of
/// voice embeddings containing at least the named voice.
public struct KokoroSpeechResources: Sendable, Equatable {
    /// The Kokoro model weights (`kokoro-v1_0.safetensors`).
    public var modelFile: URL
    /// An `.npz` archive of one or more voice embeddings.
    public var voicesFile: URL
    /// The voice to speak, as its key inside `voicesFile` (for example
    /// `"bf_emma"`). A `b…` prefix selects British English phonemization,
    /// anything else American English, matching Kokoro's voice naming.
    public var voice: String

    /// Creates a resource description for one bundled model and voice.
    public init(modelFile: URL, voicesFile: URL, voice: String) {
        self.modelFile = modelFile
        self.voicesFile = voicesFile
        self.voice = voice
    }
}

/// Speaks through Kokoro-82M on MLX. Conforms to ``AppLocalVoice/SpeechSynthesizer``;
/// pass it to `AppLocalVoice(synthesizer:)`.
///
/// ```swift
/// let engine = KokoroSpeechEngine(resources: .init(modelFile: model, voicesFile: voices, voice: "bf_emma"))
/// let voice = AppLocalVoice(synthesizer: engine)
/// Task { try? await engine.prepare() }   // optional warm-up at launch
/// ```
///
/// The engine is host-owned: call `prepare()` early to pay model loading
/// before the first reply, and `unload()` on memory pressure. It never touches
/// `AVAudioSession` and never retains or logs the text it is given.
public actor KokoroSpeechEngine: SpeechSynthesizer {
    /// Kokoro produces 24 kHz mono audio.
    public nonisolated let sampleRate: Double = Double(KokoroTTS.Constants.samplingRate)

    private static let loadFailure = VoiceError.speechSynthesisUnavailable(
        "The speech model resources could not be loaded."
    )
    private static let synthesisFailure = VoiceError.speechSynthesisUnavailable(
        "The speech model could not synthesize this text."
    )
    private static let warmUpText = "Ready."

    private struct Runtime {
        let tts: KokoroTTS
        let voice: MLXArray
        let language: Language
    }

    private let resources: KokoroSpeechResources
    private var runtime: Runtime?
    private var loading: Task<Void, Error>?
    private var inFlight = 0
    private var unloadPending = false

    /// Creates an engine for the given bundled resources. Nothing is loaded
    /// until `prepare()` or the first `synthesize`.
    public init(resources: KokoroSpeechResources) {
        self.resources = resources
    }

    // MARK: SpeechSynthesizer

    /// Loads the model and voice and runs one short discarded utterance so
    /// the first real reply is not the cold path. Concurrent callers share one
    /// load. Never touches `AVAudioSession`.
    public func prepare() async throws {
        try await ensureLoaded(warmUp: true)
    }

    /// Drops the model and voice. If a synthesis is in flight the drop happens
    /// when it finishes. A later `prepare()` or `synthesize` reloads.
    public func unload() async {
        loading?.cancel()
        loading = nil
        guard inFlight == 0 else {
            unloadPending = true
            return
        }
        runtime = nil
        MLX.GPU.clearCache()
    }

    /// The configured voice, for English locales only. Kokoro's voices are
    /// English; the quality class is provider-defined, not an Apple class.
    public func availableVoices(for locale: Locale) async -> [SpeechVoice] {
        guard locale.language.languageCode?.identifier.lowercased() == "en" else { return [] }
        let language = Self.language(forVoice: resources.voice) == .enGB ? "en-GB" : "en-US"
        return [SpeechVoice(id: resources.voice, name: resources.voice, languageIdentifier: language, quality: .enhanced)]
    }

    /// Synthesizes one chunk at speed 1.0. Apple-only `SpeechConfiguration`
    /// fields (`locale`, `voiceIdentifier`, `preferredQuality`, `rate`) are
    /// ignored; `volume` is applied by AppLocalVoice's player.
    public func synthesize(_ text: String, configuration: SpeechConfiguration) async throws -> SynthesizedSpeech {
        try await ensureLoaded(warmUp: false)
        guard let runtime else { throw Self.loadFailure }
        inFlight += 1
        defer {
            inFlight -= 1
            if inFlight == 0, unloadPending {
                unloadPending = false
                self.runtime = nil
                MLX.GPU.clearCache()
            }
        }
        try Task.checkCancellation()
        do {
            let (samples, _) = try runtime.tts.generateAudio(
                voice: runtime.voice,
                language: runtime.language,
                text: text,
                speed: 1.0
            )
            return SynthesizedSpeech(samples: samples)
        } catch {
            throw Self.synthesisFailure
        }
    }

    // MARK: Loading

    private func ensureLoaded(warmUp: Bool) async throws {
        if runtime != nil { return }
        if let loading {
            try await loading.value
            return
        }
        let resources = self.resources
        let task = Task<Void, Error> {
            let loaded = try Self.load(resources)
            if warmUp {
                _ = try? loaded.tts.generateAudio(
                    voice: loaded.voice,
                    language: loaded.language,
                    text: Self.warmUpText,
                    speed: 1.0
                )
            }
            try Task.checkCancellation()
            self.install(loaded)
        }
        loading = task
        defer { if loading == task { loading = nil } }
        try await task.value
    }

    private func install(_ loaded: Runtime) {
        runtime = loaded
        unloadPending = false
    }

    /// MLX keeps freed GPU buffers in an unbounded cache. A long reply is many
    /// synthesis passes, and on iOS the app is killed for memory long before
    /// the cache is reclaimed, so hold it to a small ceiling once per process.
    private static let boundMemoryOnce: Void = {
        MLX.GPU.set(cacheLimit: 32 * 1024 * 1024)
    }()

    private static func load(_ resources: KokoroSpeechResources) throws -> Runtime {
        _ = boundMemoryOnce
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: resources.modelFile.path),
              fileManager.fileExists(atPath: resources.voicesFile.path) else {
            throw loadFailure
        }
        guard let voices = NpyzReader.read(fileFromPath: resources.voicesFile) else {
            throw loadFailure
        }
        guard let voice = voices[resources.voice] ?? voices[resources.voice + ".npy"] else {
            throw VoiceError.speechVoiceUnavailable(resources.voice)
        }
        let tts = KokoroTTS(modelPath: resources.modelFile, g2p: .misaki)
        return Runtime(tts: tts, voice: voice, language: language(forVoice: resources.voice))
    }

    private static func language(forVoice voice: String) -> Language {
        voice.lowercased().hasPrefix("b") ? .enGB : .enUS
    }
}
#endif
