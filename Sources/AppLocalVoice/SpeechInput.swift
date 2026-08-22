import Foundation

protocol SpeechInput: Sendable {
    func capabilities(for locale: Locale) async -> SpeechCapabilities
    /// Reports whether this provider can ask the system to install a missing
    /// on-device recognition model for the locale. This remains side-effect
    /// free; installation occurs only through `prepareRecognition`.
    func modelInstallationAvailable(for locale: Locale) async -> Bool
    /// Reads the current recognition authorization without prompting.
    func authorizationStatus() async -> VoicePermissionStatus
    /// Reads the current microphone authorization without prompting.
    func microphonePermissionStatus() async -> VoicePermissionStatus
    func requestAuthorization() async -> VoicePermissionStatus
    func requestMicrophonePermission() async -> Bool
    /// Performs explicit permission/model preparation without opening capture,
    /// reporting optional content-free progress.
    func prepareRecognition(
        for locale: Locale,
        policy: SpeechModelPolicy,
        progress: RecognitionPreparationProgressHandler?
    ) async throws -> Bool
    /// Starts recognition from the selected input with the session's lifecycle
    /// policy. The provider owns decoding and analyzer feeding only; the
    /// coordinator retains session semantics.
    func start(
        configuration: RecognitionConfiguration,
        input: RecognitionInput,
        lifecyclePolicy: AudioLifecyclePolicy
    ) async throws -> AsyncThrowingStream<TranscriptUpdate, Error>
    func stop() async throws -> String
    func cancel() async
    /// Reports whether the provider has released every owned audio resource.
    /// The default keeps deterministic provider seams source-compatible.
    func resourcesAreReleased() async -> Bool
}

extension SpeechInput {
    func modelInstallationAvailable(for locale: Locale) async -> Bool { false }

    func authorizationStatus() async -> VoicePermissionStatus { .authorized }

    func microphonePermissionStatus() async -> VoicePermissionStatus { .authorized }

    /// Default preparation for providers without a model-installation path:
    /// check permissions and locale support, install nothing.
    func prepareRecognition(
        for locale: Locale,
        policy: SpeechModelPolicy,
        progress: RecognitionPreparationProgressHandler?
    ) async throws -> Bool {
        await progress?(.checkingReadiness)
        guard await requestMicrophonePermission() else {
            throw VoiceError.microphonePermissionDenied
        }
        guard await requestAuthorization() == .authorized else {
            throw VoiceError.speechPermissionDenied
        }
        let capabilities = await capabilities(for: locale)
        guard capabilities.isSupported else { throw VoiceError.unsupportedLocale(locale) }
        guard capabilities.supportsOnDevice else {
            throw VoiceError.onDeviceRecognitionUnavailable(capabilities.locale)
        }
        _ = policy
        return false
    }

    /// Convenience without progress reporting.
    func prepareRecognition(for locale: Locale, policy: SpeechModelPolicy) async throws -> Bool {
        try await prepareRecognition(for: locale, policy: policy, progress: nil)
    }

    /// Convenience for microphone capture with the default lifecycle policy.
    func start(configuration: RecognitionConfiguration) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        try await start(configuration: configuration, input: .microphone, lifecyclePolicy: .init())
    }

    func resourcesAreReleased() async -> Bool { true }
}
