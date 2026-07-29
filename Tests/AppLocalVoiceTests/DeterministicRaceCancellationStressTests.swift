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
            let events = await coordinator.events()

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
            if startsSucceeded {
                let observed = try await withBoundedTimeout(.seconds(1)) {
                    await collectVoiceEventsThroughIdle(events)
                }
                let listeningTerminals = observed.filter {
                    if case .listeningFinished = $0 { return true }
                    return false
                }
                XCTAssertEqual(listeningTerminals.count, 1, "listening terminal uniqueness for seed \(seed), round \(round)")
                XCTAssertEqual(observed.filter { $0 == .stateChanged(.idle) }.count, 1,
                               "idle transition uniqueness for seed \(seed), round \(round)")
            }
        }
    }

    func testSeededSpeechStopCloseRaceHasNoOrphanedSpeech() async throws {
        let seed = UInt64(ProcessInfo.processInfo.environment["APPLOCALVOICE_RACE_SEED"] ?? "424242") ?? 424242
        print("Deterministic speech race seed: \(seed)")

        for round in 0..<32 {
            let ledger = ResourceLedger()
            let output = ControlledSpeechOutput(ledger: ledger)
            let coordinator = VoiceCoordinator(input: ControlledSpeechInput(ledger: ledger), output: output)
            let events = await coordinator.events()
            let speech = Task { try await coordinator.speak("race-\(seed)-\(round)") }
            await output.waitUntilStarted()

            try await withBoundedTimeout {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await coordinator.stopSpeaking() }
                    group.addTask { await coordinator.close() }
                    group.addTask { await coordinator.pauseSpeaking() }
                    group.addTask { await coordinator.resumeSpeaking() }
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
            let observed = try await withBoundedTimeout(.seconds(1)) {
                await collectVoiceEventsThroughIdle(events)
            }
            let speechTerminals = observed.filter {
                switch $0 {
                case .speechFinished, .speechCancelled, .failure: return true
                default: return false
                }
            }
            XCTAssertEqual(speechTerminals, [.speechCancelled], "speech terminal uniqueness in round \(round)")
            let stopCount = await output.stops
            XCTAssertEqual(stopCount, 1, "provider stop uniqueness in round \(round)")
        }
    }

    private static func startResult(_ coordinator: VoiceCoordinator) async -> RaceCallerResult {
        do {
            try await coordinator.startListening()
            return .startSucceeded
        } catch let error as VoiceError {
            return .startFailed(error)
        } catch {
            return .startFailed(.underlying(String(describing: error)))
        }
    }

    private static func endResult(_ coordinator: VoiceCoordinator) async -> RaceCallerResult {
        do {
            _ = try await coordinator.endListening()
            return .endSucceeded
        } catch let error as VoiceError {
            return .endFailed(error)
        } catch {
            return .endFailed(.underlying(String(describing: error)))
        }
    }

    private static func cancelResult(_ coordinator: VoiceCoordinator) async -> RaceCallerResult {
        await coordinator.cancelListening()
        return .completed
    }

    private static func closeResult(_ coordinator: VoiceCoordinator) async -> RaceCallerResult {
        await coordinator.close()
        return .completed
    }
}

private enum RaceCallerResult: Sendable, Equatable {
    case startSucceeded
    case startFailed(VoiceError)
    case endSucceeded
    case endFailed(VoiceError)
    case completed
}
