import Foundation

protocol SpeechOutput: Sendable {
    func availableVoices(for locale: Locale) async -> [SpeechVoice]
    func speak(
        _ text: String,
        configuration: SpeechConfiguration,
        lifecyclePolicy: AudioLifecyclePolicy
    ) async throws
    func pause() async
    func resume() async
    func stop() async
    /// Installs an advisory progress callback for the next active request.
    func setProgressHandler(_ handler: (@Sendable (Range<Int>) async -> Void)?) async
    /// Reports whether the provider has released its audio-session and
    /// synthesizer resources after a stop or completion boundary.
    func resourcesAreReleased() async -> Bool
}

extension SpeechOutput {
    func setProgressHandler(_ handler: (@Sendable (Range<Int>) async -> Void)?) async {
        _ = handler
    }
    /// Convenience with the default lifecycle policy.
    func speak(_ text: String, configuration: SpeechConfiguration = .init()) async throws {
        try await speak(text, configuration: configuration, lifecyclePolicy: .init())
    }

    func resourcesAreReleased() async -> Bool { true }
}
