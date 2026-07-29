import Foundation

protocol SpeechOutput: Sendable {
    func availableVoices(for locale: Locale) async -> [SpeechVoice]
    func speak(_ text: String, configuration: SpeechConfiguration) async throws
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
    /// A provider that has not implemented the lifecycle-aware seam must not
    /// silently ignore a caller's external-audio policy. The v1 lifecycle
    /// cases are deterministic, but only an opted-in provider can forward the
    /// selected policy to its audio session.
    func speak(
        _ text: String,
        configuration: SpeechConfiguration,
        lifecyclePolicy: AudioLifecyclePolicy
    ) async throws {
        guard lifecyclePolicy == .init() else {
            throw VoiceError.invalidSpeechConfiguration(
                "This speech output provider does not support a non-default audio lifecycle policy."
            )
        }
        try await speak(text, configuration: configuration)
    }

    func resourcesAreReleased() async -> Bool { true }
}
