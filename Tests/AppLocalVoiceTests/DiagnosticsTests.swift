import XCTest
@testable import AppLocalVoice

@MainActor
final class DiagnosticsTests: XCTestCase {
    func testCanonicalSessionDiagnosticsUseSessionIdentityAndCompleteAfterRelease() async throws {
        let collector = DiagnosticCollector()
        let input = ControlledSpeechInput()
        let voice = AppLocalVoice(
            input: input,
            output: ControlledSpeechOutput(),
            diagnostics: { collector.values.append($0) }
        )

        let acceptance = try await voice.startSession()
        await waitForVoiceState(.listening, voice: voice)
        await input.send(TranscriptUpdate(text: "private transcript", isFinal: false))
        let final = try await voice.finishSession(id: acceptance.sessionID)
        await waitForDiagnosticCount(2, collector: collector)

        XCTAssertEqual(final.sessionID, acceptance.sessionID)
        XCTAssertEqual(collector.values.map(\.phase), [.started, .completed])
        XCTAssertEqual(
            collector.values.map(\.operationID),
            [acceptance.sessionID.rawValue, acceptance.sessionID.rawValue]
        )
        XCTAssertEqual(collector.values.map(\.state), [.preparing, .idle])
        XCTAssertTrue(collector.values.allSatisfy { $0.operation == .listening })
        XCTAssertTrue(collector.values.allSatisfy { !containsForbiddenDiagnosticField($0) })
        XCTAssertGreaterThanOrEqual(
            collector.values[1].durationNanoseconds,
            collector.values[0].durationNanoseconds
        )
    }

    func testCanonicalSessionCancellationEmitsExactlyOneCorrelatedTerminal() async throws {
        let collector = DiagnosticCollector()
        let voice = AppLocalVoice(
            input: ControlledSpeechInput(),
            output: ControlledSpeechOutput(),
            diagnostics: { collector.values.append($0) }
        )

        let acceptance = try await voice.startSession()
        await waitForVoiceState(.listening, voice: voice)
        await voice.cancelSession(id: acceptance.sessionID)
        await waitForDiagnosticCount(2, collector: collector)
        await voice.cancelSession(id: acceptance.sessionID)
        await Task.yield()

        XCTAssertEqual(collector.values.map(\.phase), [.started, .cancelled])
        XCTAssertEqual(collector.values.map(\.operationID), [
            acceptance.sessionID.rawValue,
            acceptance.sessionID.rawValue
        ])
        XCTAssertEqual(collector.values.last?.errorCategory, .cancelled)
        XCTAssertEqual(collector.values.last?.state, .idle)
    }

    func testCanonicalStartupFailureTerminatesDiagnosticsWithoutAnotherFacadeCall() async throws {
        let collector = DiagnosticCollector()
        let input = ControlledSpeechInput()
        await input.setFailure(HarnessFailure(stage: .model, message: "must not escape"))
        let voice = AppLocalVoice(
            input: input,
            output: ControlledSpeechOutput(),
            diagnostics: { collector.values.append($0) }
        )

        let acceptance = try await voice.startSession()
        await waitForDiagnosticCount(2, collector: collector)

        XCTAssertEqual(collector.values.map(\.phase), [.started, .failed])
        XCTAssertEqual(collector.values.map(\.operationID), [
            acceptance.sessionID.rawValue,
            acceptance.sessionID.rawValue
        ])
        XCTAssertEqual(collector.values.last?.errorCategory, .underlying)
        XCTAssertEqual(collector.values.last?.state, .idle)
        XCTAssertTrue(collector.values.allSatisfy { !containsForbiddenDiagnosticField($0) })
    }

    func testCanonicalCleanupFailureEmitsFailedTerminalInsteadOfFalseRelease() async throws {
        let collector = DiagnosticCollector()
        let input = ControlledSpeechInput()
        let voice = AppLocalVoice(
            input: input,
            output: ControlledSpeechOutput(),
            diagnostics: { collector.values.append($0) }
        )

        let acceptance = try await voice.startSession()
        await waitForVoiceState(.listening, voice: voice)
        await input.setCleanupBlocked(true)
        await voice.cancelSession(id: acceptance.sessionID)
        await waitForDiagnosticCount(2, collector: collector)

        XCTAssertEqual(collector.values.map(\.phase), [.started, .failed])
        XCTAssertEqual(collector.values.last?.operationID, acceptance.sessionID.rawValue)
        XCTAssertEqual(collector.values.last?.errorCategory, .audioSessionUnavailable)
        XCTAssertEqual(collector.values.last?.state, .failed)

        await input.setCleanupBlocked(false)
        _ = await voice.close()
    }

    func testCloseTerminatesCanonicalSessionOnceAndKeepsCloseIdentitySeparate() async throws {
        let collector = DiagnosticCollector()
        let voice = AppLocalVoice(
            input: ControlledSpeechInput(),
            output: ControlledSpeechOutput(),
            diagnostics: { collector.values.append($0) }
        )

        let acceptance = try await voice.startSession()
        await waitForVoiceState(.listening, voice: voice)
        let closeResult = await voice.close()
        XCTAssertEqual(closeResult, .released)
        await waitForDiagnosticCount(4, collector: collector)

        let recognition = collector.values.filter { $0.operation == .listening }
        let close = collector.values.filter { $0.operation == .close }
        XCTAssertEqual(recognition.map(\.phase), [.started, .cancelled])
        XCTAssertEqual(recognition.map(\.operationID), [
            acceptance.sessionID.rawValue,
            acceptance.sessionID.rawValue
        ])
        XCTAssertEqual(close.map(\.phase), [.started, .completed])
        XCTAssertEqual(Set(close.map(\.operationID)).count, 1)
        XCTAssertNotEqual(close.first?.operationID, acceptance.sessionID.rawValue)
    }

    func testDiagnosticsWithoutSinkDoNotChangeThePublicLifecycle() async throws {
        let voice = AppLocalVoice(input: ControlledSpeechInput(), output: ControlledSpeechOutput())
        try await voice.startTurn()
        await voice.cancelTurn()
        let state = await voice.state
        XCTAssertEqual(state, .idle)
    }

    func testDiagnosticStreamDeliversContentFreeRecordsWithoutCallbackSink() async throws {
        let voice = AppLocalVoice(input: ControlledSpeechInput(), output: ControlledSpeechOutput())
        let stream = voice.diagnostics()
        let delivery = Task { () -> [VoiceDiagnostic] in
            var records: [VoiceDiagnostic] = []
            for await record in stream {
                records.append(record)
                if records.count == 2 { return records }
            }
            return records
        }

        let acceptance = try await voice.startSession()
        await waitForVoiceState(.listening, voice: voice)
        await voice.cancelSession(id: acceptance.sessionID)
        let records = try await withBoundedTimeout { await delivery.value }
        let started = records.first
        let cancelled = records.last

        XCTAssertEqual(started?.operation, .listening)
        XCTAssertEqual(started?.phase, .started)
        XCTAssertEqual(cancelled?.operationID, started?.operationID)
        XCTAssertEqual(cancelled?.phase, .cancelled)
        if let started { XCTAssertFalse(containsForbiddenDiagnosticField(started)) }
        if let cancelled { XCTAssertFalse(containsForbiddenDiagnosticField(cancelled)) }
    }

    func testCancellationDuringListeningStartupDoesNotLeaveAStaleDiagnostic() async throws {
        let collector = DiagnosticCollector()
        let input = ControlledSpeechInput()
        let voice = AppLocalVoice(
            input: input,
            output: ControlledSpeechOutput(),
            diagnostics: { collector.values.append($0) }
        )

        await input.setStartBlocked(true)
        let acceptance = try await voice.startSession()
        await input.waitForStartEntry()
        let cancelling = Task { @MainActor in
            await voice.cancelSession(id: acceptance.sessionID)
        }
        await input.setStartBlocked(false)
        await cancelling.value
        await voice.cancelSession(id: acceptance.sessionID)
        await waitForVoiceState(.idle, voice: voice)
        await waitForDiagnosticCount(2, collector: collector)

        // The admitted session owns exactly one started record and exactly
        // one correlated terminal; a cancellation that raced provider startup
        // must neither leave the started record dangling nor report a failure.
        XCTAssertEqual(collector.values.map(\.phase), [.started, .cancelled])
        XCTAssertTrue(collector.values.allSatisfy { $0.operationID == acceptance.sessionID.rawValue })
        XCTAssertFalse(collector.values.contains { $0.phase == .failed })
        XCTAssertEqual(collector.values.filter { $0.phase == .cancelled }.count, 1)
    }

    func testConcurrentListeningStartupCannotStealFacadeReservation() async throws {
        let collector = DiagnosticCollector()
        let input = ControlledSpeechInput()
        let voice = AppLocalVoice(
            input: input,
            output: ControlledSpeechOutput(),
            diagnostics: { collector.values.append($0) }
        )

        await input.setStartBlocked(true)
        let acceptance = try await voice.startSession()
        await input.waitForStartEntry()

        do {
            _ = try await voice.startSession()
            XCTFail("a second startup must be rejected before it can own diagnostics")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .invalidState("A voice operation is already active."))
        }

        await input.setStartBlocked(false)
        await waitForVoiceState(.listening, voice: voice)
        await voice.cancelSession(id: acceptance.sessionID)
        await waitForDiagnosticCount(2, collector: collector)

        // Only the admitted session owns diagnostics; the rejected startup
        // never creates a started record or an identity of its own.
        XCTAssertEqual(collector.values.map(\.phase), [.started, .cancelled])
        XCTAssertTrue(collector.values.allSatisfy { $0.operationID == acceptance.sessionID.rawValue })
    }

    func testConcurrentSpeechCannotStealFacadeReservation() async throws {
        let collector = DiagnosticCollector()
        let output = ControlledSpeechOutput()
        let voice = AppLocalVoice(
            input: ControlledSpeechInput(),
            output: output,
            diagnostics: { collector.values.append($0) }
        )
        let first = Task { @MainActor in try await voice.speakNow("first") }
        await output.waitUntilStarted()

        do {
            try await voice.speakNow("second")
            XCTFail("a concurrent speech request must be rejected before it can own diagnostics")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .invalidState("A voice operation is already active."))
        }

        await voice.stopSpeaking()
        do {
            try await first.value
            XCTFail("the first speech request should be cancelled")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertTrue(collector.values.isEmpty)
    }

    func testRejectedSpeechDoesNotCreateAStartedDiagnostic() async throws {
        let collector = DiagnosticCollector()
        let voice = AppLocalVoice(
            input: ControlledSpeechInput(),
            output: ControlledSpeechOutput(),
            diagnostics: { collector.values.append($0) }
        )
        try await voice.startTurn()

        do {
            try await voice.speakNow("blocked")
            XCTFail("expected invalid-state rejection")
        } catch let error as VoiceError {
            XCTAssertEqual(error.category, .invalidState)
        }

        XCTAssertFalse(collector.values.contains { $0.operation == .speaking })
        await voice.cancelTurn()
    }

    private func containsForbiddenDiagnosticField(_ diagnostic: VoiceDiagnostic) -> Bool {
        Mirror(reflecting: diagnostic).children.contains { child in
            ["text", "audio", "speech", "transcript", "voiceName", "deviceName", "routeIdentifier", "message"]
                .contains(child.label ?? "")
        }
    }

    private func waitForDiagnosticCount(
        _ expected: Int,
        collector: DiagnosticCollector,
        timeout: Duration = .seconds(2)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while collector.values.count < expected, clock.now < deadline {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(collector.values.count, expected)
    }

    private func waitForVoiceState(
        _ expected: VoiceState,
        voice: AppLocalVoice,
        timeout: Duration = .seconds(2)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await voice.state != expected, clock.now < deadline {
            await Task.yield()
        }
        let finalState = await voice.state
        XCTAssertEqual(finalState, expected)
    }
}

@MainActor
private final class DiagnosticCollector {
    var values: [VoiceDiagnostic] = []
}
