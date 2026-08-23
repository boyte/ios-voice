import SwiftUI
import AppLocalVoice
import LocalEchoKokoro

@main
struct LocalEchoApp: App {
    // The app, not a transient view, owns the one voice service. Features are
    // given the same model/service instance and must never retire it merely
    // because one view leaves the hierarchy.
    @State private var model: LocalEchoModel

    init() {
        let selection = Self.makeVoice()
        _model = State(initialValue: LocalEchoModel(voice: selection.voice, engineLabel: selection.label))
    }

    var body: some Scene {
        WindowGroup { LocalEchoView(model: model) }
    }

    /// Speaks through Kokoro when `kokoro-v1_0.safetensors` and `voices.npz`
    /// have been copied into the app's Documents folder (Files app, AirDrop,
    /// or Finder file sharing); otherwise Apple's synthesizer. The engine is
    /// chosen at launch — relaunch after adding or removing the files.
    /// Kokoro runs on device only; the simulator always uses Apple.
    private static func makeVoice() -> (voice: AppLocalVoice, label: String) {
        #if targetEnvironment(simulator)
        return (AppLocalVoice(), "Apple")
        #else
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelFile = documents.appendingPathComponent("kokoro-v1_0.safetensors")
        let voicesFile = documents.appendingPathComponent("voices.npz")
        guard FileManager.default.fileExists(atPath: modelFile.path),
              FileManager.default.fileExists(atPath: voicesFile.path) else {
            return (AppLocalVoice(), "Apple")
        }
        let voiceName = UserDefaults.standard.string(forKey: "KokoroVoice") ?? "af_heart"
        let engine = KokoroSpeechEngine(resources: .init(
            modelFile: modelFile,
            voicesFile: voicesFile,
            voice: voiceName
        ))
        // Pay model loading before the first Speak; failures surface there.
        Task { try? await engine.prepare() }
        return (AppLocalVoice(synthesizer: engine), "Kokoro · \(voiceName)")
        #endif
    }
}
