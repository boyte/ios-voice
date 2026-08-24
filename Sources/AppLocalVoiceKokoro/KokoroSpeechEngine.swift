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
import os

/// Numeric precision the Kokoro model is held and computed in.
///
/// The weights ship as 32-bit floats. Loading them at half precision halves
/// the resident model and most of the memory a synthesis pass allocates,
/// which is the difference between comfortable and marginal on a phone. It
/// is a quality trade: judge it by ear before shipping it.
public enum KokoroPrecision: String, Sendable, Equatable, CaseIterable {
    /// The weights as published. Highest fidelity, largest footprint.
    case float32
    /// Half precision. Roughly halves resident weights and most activations.
    case float16
    /// Half precision with float32's exponent range and fewer mantissa bits.
    /// Same footprint as ``float16``; worth trying if ``float16`` sounds wrong.
    case bfloat16
}

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
    /// Precision to load and compute in. Defaults to the published
    /// ``KokoroPrecision/float32``.
    public var precision: KokoroPrecision

    /// Creates a resource description for one bundled model and voice.
    public init(
        modelFile: URL,
        voicesFile: URL,
        voice: String,
        precision: KokoroPrecision = .float32
    ) {
        self.modelFile = modelFile
        self.voicesFile = voicesFile
        self.voice = voice
        self.precision = precision
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
        MLX.Memory.clearCache()
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
                MLX.Memory.clearCache()
            }
        }
        try Task.checkCancellation()
        MLX.Memory.peakMemory = 0  // setter resets; the value is ignored
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let (samples, _) = try runtime.tts.generateAudio(
                voice: runtime.voice,
                language: runtime.language,
                text: text,
                speed: 1.0
            )
            Self.record(utf16Length: text.utf16.count, sampleCount: samples.count, since: started)
            return SynthesizedSpeech(samples: samples)
        } catch {
            Self.record(utf16Length: text.utf16.count, sampleCount: 0, since: started)
            throw Self.synthesisFailure
        }
    }

    /// One content-free line per synthesis: how much memory the pass actually
    /// needed and how much headroom the process had left. A long reply that
    /// dies mid-playback leaves no app crash report — the system reclaims the
    /// process — so without this the only evidence is a device-wide
    /// `JetsamEvent` log. Carries no text, only lengths and byte counts.
    private static let log = Logger(subsystem: "AppLocalVoice", category: "Kokoro")

    /// Logged once per load: what the device allows and what MLX was told, so
    /// a later `peakMB` reading can be judged against the real ceiling rather
    /// than an assumed one.
    private static func recordDeviceBudget(precision: KokoroPrecision) {
        let info = MLX.GPU.deviceInfo()
        let workingSetMB = Int(info.maxRecommendedWorkingSetSize) >> 20
        let deviceMB = info.memorySize >> 20
        let cacheLimitMB = MLX.Memory.cacheLimit >> 20
        let memoryLimitMB = MLX.Memory.memoryLimit >> 20
        let headroomMB = Int(os_proc_available_memory()) >> 20
        log.info(
            """
            budget precision=\(precision.rawValue, privacy: .public) \
            deviceMB=\(deviceMB, privacy: .public) \
            workingSetMB=\(workingSetMB, privacy: .public) \
            cacheLimitMB=\(cacheLimitMB, privacy: .public) \
            memoryLimitMB=\(memoryLimitMB, privacy: .public) \
            headroomMB=\(headroomMB, privacy: .public)
            """
        )
    }

    private static func record(utf16Length: Int, sampleCount: Int, since start: UInt64) {
        let elapsedMS = (DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        let snapshot = MLX.Memory.snapshot()
        let peakMB = snapshot.peakMemory >> 20
        let activeMB = snapshot.activeMemory >> 20
        let cacheMB = snapshot.cacheMemory >> 20
        let headroomMB = Int(os_proc_available_memory()) >> 20
        log.info(
            """
            synth chars=\(utf16Length, privacy: .public) samples=\(sampleCount, privacy: .public) \
            ms=\(elapsedMS, privacy: .public) peakMB=\(peakMB, privacy: .public) \
            activeMB=\(activeMB, privacy: .public) cacheMB=\(cacheMB, privacy: .public) \
            headroomMB=\(headroomMB, privacy: .public)
            """
        )
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

    /// MLX sizes itself for a Mac, and on a phone those defaults sit at or
    /// above the point where iOS kills the app.
    ///
    /// Its allocator derives both thresholds from Metal's recommended working
    /// set: the buffer cache may grow to `1.5 x` that size, and it does not
    /// try to reclaim anything until active + cached memory reaches `0.95 x`
    /// it. On a 6 GB iPhone that reclaim threshold lands near 3.2 GB — which
    /// is also roughly where the per-process jetsam limit sits, so the app is
    /// killed at the very moment MLX would first have freed something. A
    /// confirmed kill of this app recorded 3,278 MB resident.
    ///
    /// Both ceilings are therefore set explicitly, once per process. The cache
    /// is held small because a synthesis pass allocates and frees large
    /// intermediates that would otherwise accumulate across chunks. The memory
    /// limit is not a hard cap and cannot fail an allocation — in this version
    /// it only moves the point at which the allocator releases cached buffers,
    /// so lowering it makes MLX reclaim early instead of never.
    private static let boundMemoryOnce: Void = {
        MLX.Memory.cacheLimit = 32 * 1024 * 1024
        MLX.Memory.memoryLimit = 1024 * 1024 * 1024
    }()

    private static func load(_ resources: KokoroSpeechResources) throws -> Runtime {
        _ = boundMemoryOnce
        recordDeviceBudget(precision: resources.precision)
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
        let dtype = dataType(for: resources.precision)
        let tts = KokoroTTS(modelPath: resources.modelFile, g2p: .misaki, dtype: dtype)
        // The voice embedding is read from the archive as float32. Left that
        // way it would promote every style-conditioned tensor back to float32
        // and undo the saving, so it follows the model's precision.
        return Runtime(
            tts: tts,
            voice: voice.dtype == dtype ? voice : voice.asType(dtype),
            language: language(forVoice: resources.voice)
        )
    }

    private static func dataType(for precision: KokoroPrecision) -> DType {
        switch precision {
        case .float32: .float32
        case .float16: .float16
        case .bfloat16: .bfloat16
        }
    }

    private static func language(forVoice voice: String) -> Language {
        voice.lowercased().hasPrefix("b") ? .enGB : .enUS
    }
}
#endif
