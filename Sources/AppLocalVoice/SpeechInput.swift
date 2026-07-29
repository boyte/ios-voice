import Foundation

protocol SpeechInput: Sendable {
    func capabilities(for locale: Locale) async -> SpeechCapabilities
    /// Reports whether this provider can ask the system to install a missing
    /// on-device recognition model for the locale. This remains side-effect
    /// free; installation occurs only through `prepareRecognition`.
    func modelInstallationAvailable(for locale: Locale) async -> Bool
    /// Reads the current recognition authorization without prompting.
    func authorizationStatus() async -> SpeechAuthorization
    /// Reads the current microphone authorization without prompting.
    func microphonePermissionStatus() async -> VoicePermissionStatus
    func requestAuthorization() async -> SpeechAuthorization
    func requestMicrophonePermission() async -> Bool
    /// Performs explicit permission/model preparation without opening capture.
    func prepareRecognition(for locale: Locale, policy: SpeechModelPolicy) async throws -> Bool
    /// Performs explicit preparation with optional content-free progress.
    func prepareRecognition(
        for locale: Locale,
        policy: SpeechModelPolicy,
        progress: RecognitionPreparationProgressHandler?
    ) async throws -> Bool
    func start(configuration: RecognitionConfiguration) async throws -> AsyncThrowingStream<TranscriptUpdate, Error>
    /// Starts recognition with the session's lifecycle policy. Providers that
    /// have not opted into this additive seam reject non-default policies
    /// rather than silently running with behavior they cannot provide.
    func start(
        configuration: RecognitionConfiguration,
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

    func authorizationStatus() async -> SpeechAuthorization { .authorized }

    func microphonePermissionStatus() async -> VoicePermissionStatus { .authorized }

    func prepareRecognition(for locale: Locale, policy: SpeechModelPolicy) async throws -> Bool {
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

    func prepareRecognition(
        for locale: Locale,
        policy: SpeechModelPolicy,
        progress: RecognitionPreparationProgressHandler?
    ) async throws -> Bool {
        await progress?(.checkingReadiness)
        let installed = try await prepareRecognition(for: locale, policy: policy)
        if installed { await progress?(.modelInstalled) }
        return installed
    }

    func start(
        configuration: RecognitionConfiguration,
        lifecyclePolicy: AudioLifecyclePolicy
    ) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        guard lifecyclePolicy == .init() else {
            throw VoiceError.invalidRecognitionConfiguration(
                "This speech input provider does not support a non-default audio lifecycle policy."
            )
        }
        return try await start(configuration: configuration)
    }

    func resourcesAreReleased() async -> Bool { true }
}
