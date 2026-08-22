import Foundation
import XCTest
@testable import AppLocalVoice

@MainActor
final class RecognitionFacadeContractTests: XCTestCase {
    func testFinishDuringPreparationLatchesTheAcceptedSessionAndFinalizesIt() async throws {
        let input = ControlledSpeechInput()
        await input.setStartBlocked(true)
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput())

        let acceptance = try await voice.startSession()
        await input.waitForStartEntry()
        let preparingState = await voice.state
        XCTAssertEqual(preparingState, .preparing)

        let finishTask = Task { try await voice.finishSession(id: acceptance.sessionID) }
        await Task.yield()
        await input.setStartBlocked(false)
        let final = try await finishTask.value
        XCTAssertEqual(final.sessionID, acceptance.sessionID)
        XCTAssertEqual(final.text, "")
        await waitForFacadeState(.idle, voice: voice)
        await voice.close()
    }

    func testStartSessionReturnsAcceptedOrdinalZeroBeforeProviderStartupCompletes() async throws {
        let input = ControlledSpeechInput()
        await input.setStartBlocked(true)
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput())
        let stream = await voice.voiceEvents()
        let eventsTask = Task { try await collectRecognitionEventsThroughOutcome(stream) }

        let acceptance = try await voice.startSession()
        XCTAssertEqual(acceptance.acceptedEventOrdinal, 0)
        await input.waitForStartEntry()
        let preparingState = await voice.state
        XCTAssertEqual(preparingState, .preparing)

        await input.setStartBlocked(false)
        await waitForFacadeState(.listening, voice: voice)
        await input.send(TranscriptUpdate(text: "typed preview", isFinal: false))
        let final = try await voice.finishSession(id: acceptance.sessionID)
        XCTAssertEqual(final.sessionID, acceptance.sessionID)
        XCTAssertEqual(final.text, "typed preview")

        let events = try await eventsTask.value
        XCTAssertEqual(events.first?.sessionID, acceptance.sessionID)
        XCTAssertEqual(events.first?.eventOrdinal, 0)
        XCTAssertEqual(events.first?.kind, .accepted)
        assertStrictlyIncreasingOrdinals(events)

        let finalIndex = try XCTUnwrap(events.firstIndex { event in
            if case .transcript(.finalTranscript(let transcript)) = event.kind {
                return transcript == final
            }
            return false
        })
        let terminalIndex = try XCTUnwrap(events.firstIndex { $0.kind == .outcome(.completed) })
        XCTAssertLessThan(finalIndex, terminalIndex)
        XCTAssertEqual(terminalIndex, events.index(before: events.endIndex))
        await voice.close()
    }

    func testStaleSessionIDCannotFinishOrCancelLaterGeneration() async throws {
        let input = ControlledSpeechInput()
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput())

        let first = try await voice.startSession()
        await waitForFacadeState(.listening, voice: voice)
        await voice.cancelSession(id: first.sessionID)
        await waitForFacadeState(.idle, voice: voice)

        let second = try await voice.startSession()
        await waitForFacadeState(.listening, voice: voice)
        await voice.cancelSession(id: first.sessionID)
        let stateAfterStaleCancel = await voice.state
        XCTAssertEqual(stateAfterStaleCancel, .listening)

        do {
            _ = try await voice.finishSession(id: first.sessionID)
            XCTFail("A completed identity must return its cached terminal result")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let stateAfterStaleFinish = await voice.state
        XCTAssertEqual(stateAfterStaleFinish, .listening)

        await input.send(TranscriptUpdate(text: "second", isFinal: false))
        let final = try await voice.finishSession(id: second.sessionID)
        XCTAssertEqual(final.text, "second")
        await voice.close()
    }

    func testAcceptedSessionReportsStartupFailureAsTypedTerminal() async throws {
        let input = ControlledSpeechInput()
        await input.setFailure(HarnessFailure(stage: .model, message: "fixture startup failure"))
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput())
        let stream = await voice.voiceEvents()
        let eventsTask = Task { try await collectRecognitionEventsThroughOutcome(stream) }

        let acceptance = try await voice.startSession()
        let events = try await eventsTask.value

        XCTAssertEqual(events.first?.kind, .accepted)
        XCTAssertTrue(events.allSatisfy { $0.sessionID == acceptance.sessionID })
        assertStrictlyIncreasingOrdinals(events)
        guard case .outcome(.failed(let failure)) = events.last?.kind else {
            XCTFail("Expected one typed startup-failure outcome")
            return
        }
        XCTAssertEqual(failure.category, .underlying)
        XCTAssertEqual(events.filter(\.kind.isTerminal).count, 1)
        await voice.close()
    }

    func testRecognitionSupersedesActiveQueuedSpeechAndSuspendsPendingWork() async throws {
        let output = ControlledSpeechOutput()
        let voice = AppLocalVoice(input: ControlledSpeechInput(), output: output)
        let first = try await voice.enqueueSpeech("first")
        let second = try await voice.enqueueSpeech("second")
        await output.waitUntilStarted()

        let acceptance = try await voice.startSession()
        await waitForFacadeState(.listening, voice: voice)

        let firstResult = try await voice.waitForSpeechPlayback(id: first.playbackID)
        XCTAssertEqual(firstResult.outcome, .cancelled(.supersededByRecognition))
        let snapshot = await voice.runtimeSnapshot()
        XCTAssertEqual(snapshot.queue.mode, .suspended)
        XCTAssertEqual(snapshot.queue.pending.map(\.playbackID), [second.playbackID])

        await voice.cancelSession(id: acceptance.sessionID)
        await waitForFacadeState(.idle, voice: voice)
        await voice.close()
    }

    func testDurationLimitStartsAfterListeningAndFinalizesWithCachedResult() async throws {
        let input = ControlledSpeechInput()
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput())
        let stream = await voice.voiceEvents()
        let eventsTask = Task { try await collectRecognitionEventsThroughOutcome(stream) }

        let acceptance = try await voice.startSession(configuration: .init(
            maximumRecognitionDuration: .seconds(1)
        ))
        await waitForFacadeState(.listening, voice: voice)
        await input.send(TranscriptUpdate(text: "bounded", isFinal: false))

        let events = try await eventsTask.value
        XCTAssertEqual(events.last?.kind, .outcome(.durationLimitReached))
        let final = try await voice.finishSession(id: acceptance.sessionID)
        XCTAssertEqual(final.text, "bounded")
        await waitForFacadeState(.idle, voice: voice)
        await voice.close()
    }

    func testInvalidRecognitionDurationIsRejectedBeforeSessionAcceptance() async throws {
        let voice = AppLocalVoice(input: ControlledSpeechInput(), output: ControlledSpeechOutput())

        do {
            _ = try await voice.startSession(configuration: .init(
                maximumRecognitionDuration: .milliseconds(999)
            ))
            XCTFail("Sub-second duration must be rejected")
        } catch let error as VoiceError {
            XCTAssertEqual(error.category, .invalidRecognitionConfiguration)
        }
        let state = await voice.state
        XCTAssertEqual(state, .idle)
        await voice.close()
    }

    func testCompletedAudioFileSessionBypassesMicrophonePermissionAndCaptureLease() async throws {
        let ledger = ResourceLedger()
        let input = ControlledSpeechInput(ledger: ledger)
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput(ledger: ledger))
        let configuration = RecognitionSessionConfiguration(
            input: .audioFile(.init(url: URL(fileURLWithPath: "/tmp/recording.m4a"))),
            maximumRecognitionDuration: .seconds(1)
        )

        let acceptance = try await voice.startSession(configuration: configuration)
        await waitForFacadeState(.listening, voice: voice)
        let permissionRequests = await input.microphonePermissionRequests
        let lastInput = await input.lastInput
        let microphoneCount = await ledger.count(.microphone)
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(lastInput, configuration.input)
        XCTAssertEqual(microphoneCount.acquired, 0)

        let final = try await voice.finishSession(id: acceptance.sessionID)
        XCTAssertEqual(final.text, "")
        let resourcesBalanced = await ledger.isBalanced()
        XCTAssertTrue(resourcesBalanced)
        await voice.close()
    }

    func testCompletedAudioFileRejectsNonLocalURLBeforeSessionAcceptance() async throws {
        let voice = AppLocalVoice(input: ControlledSpeechInput(), output: ControlledSpeechOutput())

        do {
            _ = try await voice.startSession(configuration: .init(
                input: .audioFile(.init(url: URL(string: "https://example.com/recording.m4a")!))
            ))
            XCTFail("A remote URL must be rejected before session acceptance")
        } catch let error as VoiceError {
            XCTAssertEqual(error.category, .invalidRecognitionConfiguration)
        }
        let state = await voice.state
        XCTAssertEqual(state, .idle)
        await voice.close()
    }

    func testPreparationIsSideEffectFreeForSessionAndAudioLifecycle() async throws {
        let input = ControlledSpeechInput()
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput())

        let result = try await voice.prepareRecognition(for: Locale(identifier: "en-US"))

        XCTAssertFalse(result.installedModel)
        XCTAssertEqual(result.capabilitySnapshot.recognition.modelReadiness, .installed)
        let starts = await input.starts
        XCTAssertEqual(starts, 0)
        let state = await voice.state
        XCTAssertEqual(state, .idle)
        await voice.close()
    }

    func testPreparationForwardsContentFreeModelProgressInOrder() async throws {
        let input = ControlledSpeechInput()
        await input.setPreparation(
            phases: [
                .checkingReadiness,
                .downloadingModel(.indeterminate),
                .downloadingModel(.fractionCompleted(0.5)),
                .modelInstalled
            ],
            installedModel: true
        )
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput())
        var phases: [RecognitionPreparationPhase] = []

        let result = try await voice.prepareRecognition(
            for: Locale(identifier: "en-US"),
            policy: .allowModelInstallation,
            progress: { phases.append($0) }
        )

        XCTAssertTrue(result.installedModel)
        XCTAssertEqual(phases, [
            .checkingReadiness,
            .downloadingModel(.indeterminate),
            .downloadingModel(.fractionCompleted(0.5)),
            .modelInstalled
        ])
        let state = await voice.state
        let starts = await input.starts
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(starts, 0)
        await voice.close()
    }

    func testPreparationOwnsAdmissionAcrossAwaits() async throws {
        let input = ControlledSpeechInput()
        await input.setPreparationBlocked(true)
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput())
        let preparation = Task {
            try await voice.prepareRecognition(
                for: Locale(identifier: "en-US"),
                policy: .allowModelInstallation
            )
        }
        await input.waitForPreparationEntry()

        do {
            _ = try await voice.prepareRecognition(policy: .allowModelInstallation)
            XCTFail("A second preparation must not race the in-flight preparation")
        } catch let error as VoiceError {
            XCTAssertEqual(error.category, .invalidState)
        }
        do {
            _ = try await voice.startSession()
            XCTFail("Recognition start must not race model preparation")
        } catch let error as VoiceError {
            XCTAssertEqual(error.category, .invalidState)
        }

        let closeResult = await voice.close()
        XCTAssertEqual(closeResult, .blocked(VoiceError.cleanupPending.failure))

        await input.setPreparationBlocked(false)
        _ = try await preparation.value
        let finalClose = await voice.close()
        XCTAssertEqual(finalClose, .released)
    }

    func testJoinedOrPreexistingDownloadDoesNotClaimThisCallInstalledTheModel() async throws {
        let input = ControlledSpeechInput()
        await input.setPreparation(
            phases: [.downloadingModel(.indeterminate), .modelInstalled],
            installedModel: false
        )
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput())

        let result = try await voice.prepareRecognition(policy: .allowModelInstallation)

        XCTAssertFalse(result.installedModel)
        await voice.close()
    }
}

private func waitForFacadeState(
    _ expected: VoiceState,
    voice: AppLocalVoice,
    timeout: Duration = .seconds(2)
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await voice.state != expected, clock.now < deadline {
        await Task.yield()
    }
}

/// Collects the recognition events of the canonical stream through the first
/// terminal outcome. Snapshot, speech, and recovery events are not recognition
/// events and are skipped.
private func collectRecognitionEventsThroughOutcome(
    _ stream: VoiceEventStream
) async throws -> [RecognitionEvent] {
    var events: [RecognitionEvent] = []
    for try await streamEvent in stream {
        guard case .recognition(let event) = streamEvent else { continue }
        events.append(event)
        if event.kind.isTerminal { return events }
    }
    return events
}

private func assertStrictlyIncreasingOrdinals(
    _ events: [RecognitionEvent],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for index in events.indices.dropFirst() {
        XCTAssertTrue(
            events[index].sessionID == events[events.index(before: index)].sessionID &&
            events[index].eventOrdinal > events[events.index(before: index)].eventOrdinal,
            file: file,
            line: line
        )
    }
}
