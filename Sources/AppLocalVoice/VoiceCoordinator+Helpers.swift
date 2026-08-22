import Foundation

// Pure mapping, validation, and bounded-wait helpers used by the coordinator.
// They hold no state and touch no actor-isolated members.
extension VoiceCoordinator {
    static func recognitionState(from state: VoiceState) -> RecognitionSessionState? {
        switch state {
        case .preparing: .preparing
        case .listening: .listening
        case .finalizing: .finalizing
        case .idle, .speaking, .failed: nil
        }
    }

    static func recognitionOutcome(
        from reason: VoiceTerminationReason
    ) -> RecognitionOutcome {
        switch reason {
        case .completed:
            .completed
        case .durationLimitReached:
            .durationLimitReached
        case .cancelled:
            .cancelled
        case .interrupted(let reason):
            .interrupted(reason)
        case .failed(let error):
            .failed(failure(from: error))
        }
    }

    static func validateRecognitionDuration(_ duration: Duration?) throws {
        guard let duration else { return }
        guard duration >= RecognitionSessionConfiguration.minimumMaximumRecognitionDuration,
              duration <= RecognitionSessionConfiguration.maximumMaximumRecognitionDuration else {
            throw VoiceError.invalidRecognitionConfiguration(
                "Maximum recognition duration must be between 1 and 600 seconds, or nil."
            )
        }
    }

    static func validateRecognitionInput(_ input: RecognitionInput) throws {
        guard case .audioFile(let file) = input else { return }
        guard file.url.isFileURL else {
            throw VoiceError.invalidRecognitionConfiguration(
                "Completed audio input must use a local file URL."
            )
        }
        guard file.maximumDuration >= RecognitionAudioFile.minimumMaximumDuration,
              file.maximumDuration <= RecognitionAudioFile.maximumMaximumDuration else {
            throw VoiceError.invalidRecognitionConfiguration(
                "Completed audio duration must be between 1 and 7200 seconds."
            )
        }
    }

    static func failure(from error: VoiceError) -> VoiceFailure {
        VoiceFailure(
            category: error.category,
            recommendedAction: error.recommendedRecoveryAction
        )
    }


    static func boundedValue<Value: Sendable>(
        _ task: Task<Value, Never>,
        timeout: Duration
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            BoundedTaskRace(task: task, timeout: timeout).start(continuation)
        }
    }

    static func awaitProviderStartup(
        _ task: Task<Void, Error>,
        cancellation: CancellationSignal
    ) async throws {
        try Task.checkCancellation()
        try await ProviderStartupRace(provider: task, cancellation: cancellation).wait()
    }
}
