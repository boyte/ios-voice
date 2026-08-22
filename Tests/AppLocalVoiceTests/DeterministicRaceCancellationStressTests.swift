import XCTest
@testable import AppLocalVoice

/// Bounded scheduling stress. The operation itself is serialized by the
/// coordinator actor; this exercises callers arriving in different orders.
final class DeterministicRaceCancellationStressTests: XCTestCase {
    func testSeededConcurrentCallersAlwaysConvergeToIdle() async throws {
        let seed = UInt64(ProcessInfo.processInfo.environment["APPLOCALVOICE_RACE_SEED"] ?? "424242") ?? 424242
        let rounds = min(max(Int(ProcessInfo.processInfo.environment["APPLOCALVOICE_RACE_ROUNDS"] ?? "24") ?? 24, 1), 64)
        print("Deterministic race seed: \(seed), rounds: \(rounds)")

        for round in 0..<rounds {
            let ledger = ResourceLedger()
            let input = ControlledSpeechInput(ledger: ledger)
            let output = ControlledSpeechOutput(ledger: ledger)
            let coordinator = VoiceCoordinator(input: input, output: output)
            let stream = await coordinator.voiceEvents()

            let outcomes = try await withBoundedTimeout(.seconds(2)) {
                var random = DeterministicRandom(seed: seed &+ UInt64(round))
                return await withTaskGroup(of: RaceCallerResult.self, returning: [RaceCallerResult].self) { group in
                    for _ in 0..<8 {
                        switch random.nextInt(4) {
                            case 0:
                            group.addTask { await Self.startResult(coordinator) }
                            case 1:
                            group.addTask { await Self.endResult(coordinator) }
                            case 2:
                            group.addTask { await Self.cancelResult(coordinator) }
                            default:
                            group.addTask { await Self.closeResult(coordinator) }
                        }
                    }
                    var results: [RaceCallerResult] = []
                    for await result in group { results.append(result) }
                    return results
                }
            }

            await coordinator.close()
            let state = await coordinator.state
            let balanced = await ledger.isBalanced()
            XCTAssertEqual(state, .idle, "seed \(seed), round \(round)")
            XCTAssertTrue(balanced, "seed \(seed), round \(round)")
            for outcome in outcomes {
                if case .startFailed(let error) = outcome {
                    switch error {
                    case .invalidState, .cancelled:
                        break
                    default:
                        XCTFail("unexpected start race error \(error) for seed \(seed), round \(round)")
                    }
                }
                if case .endFailed(let error) = outcome {
                    switch error {
                    case .invalidState, .cancelled:
                        break
                    default:
                        XCTFail("unexpected race error \(error) for seed \(seed), round \(round)")
                    }
                }
            }
            let startsSucceeded = outcomes.contains {
                if case .startSucceeded = $0 { return true }
                return false
            }
            // Every session admitted during the round must reach exactly one
            // canonical `.outcome`. The final close above has already joined
            // all owned cleanup, so a probe session started afterwards bounds
            // the observation window: canonical delivery is ordered per
            // subscriber, so every round event precedes the probe's events.
            let observed = try await withBoundedTimeout(.seconds(1)) {
                try await collectRecognitionEventsThroughProbe(coordinator, stream: stream)
            }
            let acceptedSessions = observed.filter(\.kind.isAccepted).map(\.sessionID)
            XCTAssertEqual(Set(acceptedSessions).count, acceptedSessions.count,
                           "accepted uniqueness for seed \(seed), round \(round)")
            if startsSucceeded {
                XCTAssertFalse(acceptedSessions.isEmpty,
                               "a successful start must admit a session for seed \(seed), round \(round)")
            }
            for sessionID in acceptedSessions {
                let terminals = observed.filter { $0.sessionID == sessionID && $0.kind.isTerminal }
                XCTAssertEqual(terminals.count, 1,
                               "recognition terminal uniqueness for seed \(seed), round \(round)")
            }
            XCTAssertTrue(
                observed.allSatisfy { acceptedSessions.contains($0.sessionID) },
                "every recognition event belongs to an accepted session for seed \(seed), round \(round)"
            )
        }
    }

    func testSeededSpeechStopCloseRaceHasNoOrphanedSpeech() async throws {
        let seed = UInt64(ProcessInfo.processInfo.environment["APPLOCALVOICE_RACE_SEED"] ?? "424242") ?? 424242
        print("Deterministic speech race seed: \(seed)")

        for round in 0..<32 {
            let ledger = ResourceLedger()
            let output = ControlledSpeechOutput(ledger: ledger)
            let coordinator = VoiceCoordinator(input: ControlledSpeechInput(ledger: ledger), output: output)
            let acceptance = try await coordinator.speakImmediately("race-\(seed)-\(round)")
            let speech = Task { try await coordinator.awaitPlayback(acceptance.playbackID) }
            await output.waitUntilStarted()

            // Hosts have no pause/resume for immediate playback; the queue
            // controls are the canonical concurrent control callers here.
            try await withBoundedTimeout {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await coordinator.stopSpeaking() }
                    group.addTask { await coordinator.close() }
                    group.addTask { _ = await coordinator.pauseSpeechQueue() }
                    group.addTask { _ = await coordinator.resumeSpeechQueue() }
                }
            }
            do {
                try await speech.value
                XCTFail("speech race unexpectedly completed successfully in round \(round)")
            } catch let error as VoiceError {
                XCTAssertEqual(error, .cancelled, "speech race error in round \(round)")
            } catch {
                XCTFail("unexpected speech race error \(error) in round \(round)")
            }
            let state = await coordinator.state
            let balanced = await ledger.isBalanced()
            XCTAssertEqual(state, .idle, "round \(round)")
            XCTAssertTrue(balanced, "round \(round)")
            // The playback result is the exactly-once terminal truth for the
            // accepted playback ID: one cancelled outcome, never a failure.
            let result = try await withBoundedTimeout(.seconds(1)) {
                try await coordinator.waitForSpeechPlayback(acceptance.playbackID)
            }
            XCTAssertEqual(result.playbackID, acceptance.playbackID, "round \(round)")
            XCTAssertEqual(result.outcome, .cancelled(.stopped), "speech terminal uniqueness in round \(round)")
            let stopCount = await output.stops
            XCTAssertEqual(stopCount, 1, "provider stop uniqueness in round \(round)")
        }
    }

    private static func startResult(_ coordinator: VoiceCoordinator) async -> RaceCallerResult {
        do {
            try await coordinator.startTurn()
            return .startSucceeded
        } catch let error as VoiceError {
            return .startFailed(error)
        } catch {
            return .startFailed(.underlying(String(describing: error)))
        }
    }

    private static func endResult(_ coordinator: VoiceCoordinator) async -> RaceCallerResult {
        do {
            _ = try await coordinator.finishTurn()
            return .endSucceeded
        } catch let error as VoiceError {
            return .endFailed(error)
        } catch {
            return .endFailed(.underlying(String(describing: error)))
        }
    }

    private static func cancelResult(_ coordinator: VoiceCoordinator) async -> RaceCallerResult {
        await coordinator.cancelTurn()
        return .completed
    }

    private static func closeResult(_ coordinator: VoiceCoordinator) async -> RaceCallerResult {
        await coordinator.close()
        return .completed
    }
}

/// Starts a probe session on the already-closed coordinator, cancels it, and
/// drains the stream through the probe's terminal outcome. Recognition events
/// belonging to the probe are excluded from the returned list.
private func collectRecognitionEventsThroughProbe(
    _ coordinator: VoiceCoordinator,
    stream: VoiceEventStream
) async throws -> [RecognitionEvent] {
    let probeID = try await coordinator.startTurn()
    await coordinator.cancelSession(id: probeID)
    let events = try await collectEvents(stream) { event in
        guard case .recognition(let recognition) = event else { return false }
        return recognition.sessionID == probeID && recognition.kind.isTerminal
    }
    return events.compactMap { event -> RecognitionEvent? in
        guard case .recognition(let recognition) = event,
              recognition.sessionID != probeID else { return nil }
        return recognition
    }
}

private enum RaceCallerResult: Sendable, Equatable {
    case startSucceeded
    case startFailed(VoiceError)
    case endSucceeded
    case endFailed(VoiceError)
    case completed
}
