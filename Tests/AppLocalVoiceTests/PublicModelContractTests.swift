import Foundation
import XCTest
@testable import AppLocalVoice

final class PublicModelContractTests: XCTestCase {
    func testPublicationPolicyHasExactlyThreeSemanticsAndOneToThirtySecondBounds() throws {
        let configuration = RecognitionSessionConfiguration()
        XCTAssertEqual(configuration.publicationPolicy, .previewAndFinal)
        XCTAssertEqual(configuration.recognition.policy, .installedModelsOnly)

        let fiveSeconds = try StableChunkPolicy(intervalSeconds: 5)
        let tenSeconds = try StableChunkPolicy(intervalSeconds: 10)
        XCTAssertEqual(fiveSeconds, .recommended)
        XCTAssertEqual(tenSeconds.intervalSeconds, 10)

        let policies: [TranscriptPublicationPolicy] = [
            .previewAndFinal,
            .finalOnly,
            .stableChunks(fiveSeconds)
        ]
        XCTAssertEqual(policies.count, 3)
        XCTAssertEqual(
            try StableChunkPolicy(intervalSeconds: StableChunkPolicy.minimumIntervalSeconds)
                .intervalSeconds,
            1
        )
        XCTAssertEqual(
            try StableChunkPolicy(intervalSeconds: StableChunkPolicy.maximumIntervalSeconds)
                .intervalSeconds,
            30
        )
        assertVoiceError(
            .invalidRecognitionConfiguration,
            try StableChunkPolicy(intervalSeconds: 0)
        )
        assertVoiceError(
            .invalidRecognitionConfiguration,
            try StableChunkPolicy(intervalSeconds: 31)
        )
    }

    func testRecognitionEventsExposeAcceptanceAtOrdinalZeroAndStrictOrdering() {
        let sessionID = RecognitionSessionID()
        let preview = TranscriptPreview(sessionID: sessionID, revision: 0, text: "draft")
        let final = FinalTranscript(sessionID: sessionID, text: "final")
        let acceptance = RecognitionSessionAcceptance(sessionID: sessionID)
        let events = [
            RecognitionEvent(sessionID: sessionID, eventOrdinal: 0, kind: .accepted),
            RecognitionEvent(
                sessionID: sessionID,
                eventOrdinal: 1,
                kind: .stateChanged(.listening)
            ),
            RecognitionEvent(
                sessionID: sessionID,
                eventOrdinal: 2,
                kind: .transcript(.preview(preview))
            ),
            RecognitionEvent(
                sessionID: sessionID,
                eventOrdinal: 3,
                kind: .stateChanged(.finalizing)
            ),
            RecognitionEvent(
                sessionID: sessionID,
                eventOrdinal: 4,
                kind: .transcript(.finalTranscript(final))
            ),
            RecognitionEvent(
                sessionID: sessionID,
                eventOrdinal: 5,
                kind: .outcome(.completed)
            )
        ]

        XCTAssertEqual(RecognitionEvent.acceptedEventOrdinal, 0)
        XCTAssertEqual(acceptance.sessionID, sessionID)
        XCTAssertEqual(acceptance.acceptedEventOrdinal, 0)
        XCTAssertTrue(events[0].kind.isAccepted)
        XCTAssertTrue(events[5].kind.isTerminal)
        XCTAssertFalse(events[4].kind.isTerminal)
        for index in 1..<events.count {
            XCTAssertTrue(events[index].immediatelyFollows(events[index - 1]))
        }
        XCTAssertTrue(events[2].duplicates(events[2]))
        XCTAssertFalse(events[2].duplicates(events[3]))
    }

    func testTranscriptKindsAreDistinctAndStableChunksCarryContiguousUTF16Ranges() throws {
        let sessionID = RecognitionSessionID()
        let firstText = "hello"
        let secondText = " world"
        let firstRange = try TranscriptUTF16Range(
            location: 0,
            length: firstText.utf16.count
        )
        let secondRange = try TranscriptUTF16Range(
            location: firstRange.endLocation,
            length: secondText.utf16.count
        )
        let timing = try TranscriptTimeRange(startMilliseconds: 100, endMilliseconds: 900)
        let preview = TranscriptPreview(
            sessionID: sessionID,
            revision: 7,
            text: "replaceable",
            timeRange: timing
        )
        let first = try StableTranscriptChunk(
            sessionID: sessionID,
            sequence: 0,
            text: firstText,
            utf16Range: firstRange,
            timeRange: timing
        )
        let second = try StableTranscriptChunk(
            sessionID: sessionID,
            sequence: 1,
            text: secondText,
            utf16Range: secondRange
        )
        let final = FinalTranscript(sessionID: sessionID, text: firstText + secondText)
        let publications: [TranscriptPublication] = [
            .preview(preview),
            .stableChunk(first),
            .stableChunk(second),
            .finalTranscript(final)
        ]

        XCTAssertEqual(
            publications.map(\.kind),
            [.preview, .stableChunk, .stableChunk, .finalTranscript]
        )
        XCTAssertEqual(publications.map(\.sessionID), Array(repeating: sessionID, count: 4))
        XCTAssertEqual(preview.revision, 7)
        XCTAssertEqual(first.sequence, 0)
        XCTAssertEqual(second.sequence, 1)
        XCTAssertEqual(first.utf16Range.endLocation, second.utf16Range.location)
        XCTAssertEqual([first, second].map(\.text).joined(), final.text)
        XCTAssertEqual(timing.durationMilliseconds, 800)

        assertVoiceError(
            .transcriptConsistency,
            try StableTranscriptChunk(
                sessionID: sessionID,
                sequence: 2,
                text: "mismatch",
                utf16Range: TranscriptUTF16Range(location: secondRange.endLocation, length: 1)
            )
        )
        assertVoiceError(
            .transcriptConsistency,
            try TranscriptTimeRange(startMilliseconds: 10, endMilliseconds: 9)
        )
    }

    func testQueueDefaultsAndIndependentBoundsMatchTheFrozenContract() throws {
        let defaults = SpeechQueueConfiguration()
        XCTAssertEqual(defaults.maximumPendingItemCount, 32)
        XCTAssertEqual(defaults.maximumReplayHistoryItemCount, 64)
        XCTAssertEqual(defaults.overflowPolicy, .rejectNew)
        XCTAssertEqual(defaults.initialMode, .running)

        let lowerBounds = try SpeechQueueConfiguration(
            maximumPendingItemCount: 1,
            maximumReplayHistoryItemCount: 0,
            initialMode: .suspended
        )
        XCTAssertEqual(lowerBounds.maximumPendingItemCount, 1)
        XCTAssertEqual(lowerBounds.maximumReplayHistoryItemCount, 0)
        XCTAssertEqual(lowerBounds.initialMode, .suspended)

        let upperBounds = try SpeechQueueConfiguration(
            maximumPendingItemCount: 128,
            maximumReplayHistoryItemCount: 256,
            overflowPolicy: .dropOldestPending
        )
        XCTAssertEqual(upperBounds.maximumPendingItemCount, 128)
        XCTAssertEqual(upperBounds.maximumReplayHistoryItemCount, 256)

        assertVoiceError(
            .invalidSpeechQueueConfiguration,
            try SpeechQueueConfiguration(maximumPendingItemCount: 0)
        )
        assertVoiceError(
            .invalidSpeechQueueConfiguration,
            try SpeechQueueConfiguration(maximumPendingItemCount: 129)
        )
        assertVoiceError(
            .invalidSpeechQueueConfiguration,
            try SpeechQueueConfiguration(
                maximumPendingItemCount: 1,
                maximumReplayHistoryItemCount: -1
            )
        )
        assertVoiceError(
            .invalidSpeechQueueConfiguration,
            try SpeechQueueConfiguration(
                maximumPendingItemCount: 1,
                maximumReplayHistoryItemCount: 257
            )
        )
    }

    func testQueueVocabularyCoversPlacementOverflowAndControls() throws {
        let request = try SpeechItemRequest(text: "Speak this", priority: .userInitiated)
        XCTAssertLessThan(SpeechPriority.normal, .userInitiated)
        XCTAssertEqual(
            [
                SpeechEnqueuePolicy.append,
                .playNext,
                .replaceCurrent,
                .replaceAll
            ].count,
            4
        )
        XCTAssertEqual(
            [SpeechQueueOverflowPolicy.rejectNew, .dropOldestPending].count,
            2
        )

        let commands: [SpeechQueueCommand] = [
            .enqueue(request, policy: .append),
            .enqueue(request, policy: .playNext),
            .enqueue(request, policy: .replaceCurrent),
            .enqueue(request, policy: .replaceAll),
            .pause,
            .resume,
            .stop,
            .skip,
            .clearPending,
            .stopAndClear,
            .replay(SpeechItemID(), policy: .playNext)
        ]
        XCTAssertEqual(commands.count, 11)
        XCTAssertEqual(
            [
                SpeechControlResult.applied,
                .alreadyApplied,
                .noActivePlayback,
                .providerRejected
            ].count,
            4
        )

        assertVoiceError(.invalidSpeechItem, try SpeechItemRequest(text: " \n\t "))
        assertVoiceError(
            .textTooLong,
            try SpeechItemRequest(
                text: String(
                    repeating: "x",
                    count: SpeechItemRequest.maximumUTF16Length + 1
                )
            )
        )
    }

    func testLibraryIdentityAppearsOnlyAfterAcceptanceAndReplayGetsANewPlaybackID() throws {
        let request = try SpeechItemRequest(text: "immutable")
        XCTAssertFalse(Mirror(reflecting: request).children.contains { $0.label == "id" })

        let itemID = SpeechItemID()
        let firstPlaybackID = SpeechPlaybackID()
        let replayPlaybackID = SpeechPlaybackID()
        let item = SpeechItem(id: itemID, request: request)
        let firstAcceptance = SpeechPlaybackAcceptance(
            itemID: itemID,
            playbackID: firstPlaybackID,
            acceptedEventOrdinal: 12
        )
        let replayAcceptance = SpeechPlaybackAcceptance(
            itemID: itemID,
            playbackID: replayPlaybackID,
            acceptedEventOrdinal: 18
        )

        XCTAssertEqual(item.id, itemID)
        XCTAssertEqual(firstAcceptance.itemID, replayAcceptance.itemID)
        XCTAssertNotEqual(firstAcceptance.playbackID, replayAcceptance.playbackID)

        let accepted = SpeechQueueEvent(
            itemID: itemID,
            playbackID: firstPlaybackID,
            eventOrdinal: 12,
            kind: .accepted
        )
        let finished = SpeechQueueEvent(
            itemID: itemID,
            playbackID: firstPlaybackID,
            eventOrdinal: 13,
            kind: .outcome(.finished)
        )
        let result = SpeechPlaybackResult(
            itemID: itemID,
            playbackID: firstPlaybackID,
            terminalEventOrdinal: 13,
            outcome: .finished
        )

        XCTAssertEqual(result.itemID, itemID)
        XCTAssertEqual(result.playbackID, firstPlaybackID)
        XCTAssertTrue(finished.immediatelyFollows(accepted))
        XCTAssertTrue(finished.kind.isTerminal)
        XCTAssertFalse(accepted.kind.isTerminal)
    }

    func testLifecyclePolicyRecoveryAndCleanupRemainSeparateFromOperationOutcome() {
        let policy = AudioLifecyclePolicy()
        XCTAssertEqual(policy.externalAudio, .duck)
        XCTAssertEqual(policy.background, .stop)
        XCTAssertEqual(policy.interruption, .stop)
        XCTAssertEqual(policy.routeChange, .stopAndRequireRestart)
        XCTAssertEqual(policy.cleanupFailure, .requireExplicitRetry)

        let externalAudioPolicies: [ExternalAudioPolicy] = [.mix, .duck, .interrupt, .reject]
        XCTAssertEqual(
            externalAudioPolicies.map { AudioLifecyclePolicy(externalAudio: $0).externalAudio },
            externalAudioPolicies
        )

        let cleanupFailure = VoiceError.cleanupPending.failure
        XCTAssertEqual(VoiceRecoveryState.ready, .ready)
        XCTAssertEqual(VoiceRecoveryState.reconciling, .reconciling)
        XCTAssertEqual(VoiceRecoveryState.blocked(cleanupFailure), .blocked(cleanupFailure))
        XCTAssertEqual(CleanupResult.released, .released)
        XCTAssertEqual(CleanupResult.blocked(cleanupFailure), .blocked(cleanupFailure))
        XCTAssertEqual(
            RecognitionOutcome.interrupted(.appBackground),
            .interrupted(.appBackground)
        )
    }

    func testCapabilitySnapshotSeparatesPermissionsLocaleModelVoiceAndFeatures() {
        let requested = Locale(identifier: "en-CA")
        let resolved = Locale(identifier: "en-US")
        let unavailable = VoiceError.onDeviceRecognitionUnavailable(requested).failure
        let recognition = RecognitionCapability(
            requestedLocale: requested,
            resolvedLocale: resolved,
            modelReadiness: .notInstalled(installationAvailable: true),
            availability: .unavailable(unavailable)
        )
        let voice = SpeechVoice(
            id: "com.example.enhanced",
            name: "Example",
            languageIdentifier: "en-US",
            quality: .enhanced
        )
        let snapshot = VoiceCapabilitySnapshot(
            microphonePermission: .restricted,
            speechRecognitionPermission: .authorized,
            recognition: recognition,
            installedVoices: [voice],
            features: [
                .speechRecognition: .unavailable(unavailable),
                .speechSynthesis: .available,
                .speechQueue: .available
            ]
        )

        XCTAssertEqual(snapshot.microphonePermission, .restricted)
        XCTAssertEqual(snapshot.recognition.requestedLocale, requested)
        XCTAssertEqual(snapshot.recognition.resolvedLocale, resolved)
        XCTAssertEqual(
            snapshot.recognition.modelReadiness,
            .notInstalled(installationAvailable: true)
        )
        XCTAssertEqual(snapshot.installedVoices.first?.quality, .enhanced)
        XCTAssertEqual(snapshot.availability(for: .speechSynthesis), .available)
        XCTAssertEqual(
            snapshot.availability(for: .speechRecognition),
            .unavailable(unavailable)
        )
        XCTAssertNil(snapshot.availability(for: .stableTranscriptChunks))
    }

    func testFrozenErrorsExposeTypedContentFreeCategoriesAndActions() {
        let itemID = SpeechItemID()
        let overflowCursor = EventDeliveryCursor.processRuntime(eventOrdinal: 41)
        let cases: [(VoiceError, VoiceErrorCategory, VoiceRecoveryAction)] = [
            (.serviceInUse, .serviceInUse, .useOwningService),
            (
                .eventSubscriberLimitReached(maximum: 8, active: 8),
                .eventSubscriberLimitReached,
                .reconcileEventState
            ),
            (
                .eventDeliveryOverflow(capacity: 32, firstUndelivered: overflowCursor),
                .eventDeliveryOverflow,
                .reconcileEventState
            ),
            (.transcriptConsistency, .transcriptConsistency, .discardPartialTranscript),
            (.queueFull(maximumPendingItemCount: 32), .queueFull, .makeQueueSpace),
            (.itemUnavailable(itemID), .itemUnavailable, .reenqueueItem),
            (.cleanupPending, .cleanupPending, .retryCleanup),
            (.microphonePermissionRestricted, .microphonePermissionRestricted, .showPermissionHelp),
            (.speechPermissionRestricted, .speechPermissionRestricted, .showPermissionHelp),
            (.unsupportedLocale(Locale(identifier: "vi-VN")), .unsupportedLocale, .chooseSupportedLocale),
            (.audioRouteUnavailable, .audioRouteUnavailable, .retryAfterInterruption),
            (.operationTimedOut, .operationTimedOut, .retry)
        ]

        for (error, category, action) in cases {
            XCTAssertEqual(error.category, category)
            XCTAssertEqual(error.recommendedRecoveryAction, action)
            XCTAssertEqual(
                error.failure,
                VoiceFailure(category: category, recommendedAction: action)
            )
            XCTAssertNotNil(error.errorDescription)
        }
    }

    func testModelInstallationErrorCodeRemainsContentFree() {
        let error = VoiceError.recognitionModelInstallationFailed(
            Locale(identifier: "vi-VN"),
            providerError: VoiceProviderErrorCode(domain: "com.apple.Speech", code: 9)
        )

        XCTAssertEqual(error.category, .recognitionModelInstallationFailed)
        XCTAssertEqual(error.recommendedRecoveryAction, .retry)
        XCTAssertEqual(
            error.failure,
            VoiceFailure(
                category: .recognitionModelInstallationFailed,
                recommendedAction: .retry
            )
        )
        XCTAssertFalse(error.localizedDescription.contains("com.apple.Speech"))
        XCTAssertFalse(error.localizedDescription.contains("9"))
    }

    private func assertVoiceError<T>(
        _ expectedCategory: VoiceErrorCategory,
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(
                (error as? VoiceError)?.category,
                expectedCategory,
                file: file,
                line: line
            )
        }
    }
}
